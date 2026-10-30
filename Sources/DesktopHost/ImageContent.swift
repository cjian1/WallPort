import AppKit
import ImageIO

/// 静态图片壁纸：PNG / JPEG 在后台按屏幕尺寸采样解码，铺满时可按比例裁切并调整露出位置。
@MainActor
public final class ImageContent: DesktopContent, FramingAdjustable {
    public let view: NSView
    public let url: URL
    /// 图片不受可见性影响，离开屏幕也能返回已解码的画面给锁屏 / 屏保同步。
    public var snapshotsWhileHidden: Bool { true }

    private let imageView = ImageWallpaperView()
    private let label: String
    private let log: EventLog
    private let onFailure: @MainActor (String) -> Void
    private var image: CGImage?
    private var targetPixelSize: CGSize
    private var readyHandler: (@MainActor () -> Void)?
    private var loadTask: Task<Void, Never>?
    private var hasFailed = false

    public init(
        url: URL, label: String, log: EventLog, targetPixelSize: CGSize = .zero,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.url = url
        self.label = label
        self.log = log
        self.targetPixelSize = targetPixelSize
        self.onFailure = onFailure
        view = imageView
        log.write("\(label) 图片：载入 \(url.path)")

        loadTask = Task { [weak self] in
            let decoded = await Task.detached { Self.decode(url, targetPixelSize: targetPixelSize) }.value
            guard let self, !Task.isCancelled else { return }
            guard let decoded else {
                fail(String(localized: "无法解码这个图片文件"))
                return
            }
            image = decoded
            imageView.image = decoded
            log.write("\(label) 图片：就绪 \(decoded.width)×\(decoded.height)")
            readyHandler?()
            readyHandler = nil
        }
    }

    public func setDisplay(fitsWhole: Bool, position: Float, scale: Float) {
        imageView.fitsWhole = fitsWhole
        imageView.position = CGFloat(min(max(position, 0), 1))
        imageView.scale = CGFloat(scale)
    }

    public func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if image != nil { handler() } else { readyHandler = handler }
    }

    public func displayDidChange(_ display: DisplaySnapshot) {
        targetPixelSize = display.pixelSize
    }

    public func visibilityDidChange(isVisible: Bool) {}

    public func snapshot() async -> CGImage? {
        guard let image else { return nil }
        return Self.render(
            image, size: targetPixelSize, fitsWhole: imageView.fitsWhole, position: imageView.position,
            scale: imageView.scale)
    }

    /// 按显示方式把图片画成屏幕大小的一帧（同步成系统壁纸用）。铺满、居中、不缩放时系统自己铺满就一样，原样返回
    nonisolated static func render(
        _ image: CGImage, size: CGSize, fitsWhole: Bool, position: CGFloat, scale: CGFloat
    ) -> CGImage {
        guard fitsWhole || position != 0.5 || scale != 1, size.width > 0, size.height > 0 else { return image }
        let bounds = CGRect(origin: .zero, size: size)
        let place = Framing.frame(
            in: bounds, content: CGSize(width: image.width, height: image.height),
            fitsWhole: fitsWhole, position: position, scale: scale)
        guard let context = CGContext(
            data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: place)
        return context.makeImage() ?? image
    }

    public func tearDown() {
        loadTask?.cancel()
        loadTask = nil
        readyHandler = nil
        image = nil
        imageView.image = nil
    }

    private func fail(_ reason: String) {
        guard !hasFailed else { return }
        hasFailed = true
        log.write("\(label) 图片：载入失败 \(url.lastPathComponent)：\(reason)")
        onFailure(reason)
    }

    /// 按屏幕尺寸采样解码（几千万像素的原图不整张解出来）；幻灯片也用它
    nonisolated static func decode(_ url: URL, targetPixelSize: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let longest = Int(max(targetPixelSize.width, targetPixelSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(longest > 0 ? longest : 8192, 8192)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 图片层在视图坐标里的位置（见 `Framing`）
    nonisolated static func imageFrame(
        in bounds: CGRect, imageSize: CGSize, fitsWhole: Bool, position: CGFloat, scale: CGFloat = 1
    ) -> CGRect {
        Framing.frame(in: bounds, content: imageSize, fitsWhole: fitsWhole, position: position, scale: scale)
    }
}

@MainActor
private final class ImageWallpaperView: NSView {
    private let imageLayer = CALayer()
    var image: CGImage? {
        didSet {
            imageLayer.contents = image
            needsLayout = true
        }
    }
    var fitsWhole = false {
        didSet { if fitsWhole != oldValue { needsLayout = true } }
    }
    var position: CGFloat = 0.5 {
        didSet { if position != oldValue { needsLayout = true } }
    }
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = image.map { CGSize(width: $0.width, height: $0.height) } ?? bounds.size
        imageLayer.frame = ImageContent.imageFrame(
            in: bounds, imageSize: size, fitsWhole: fitsWhole, position: position, scale: scale)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
