import AppKit
import ImageIO

/// 静态图片壁纸：PNG / JPEG 在后台按屏幕尺寸采样解码，铺满时可按比例裁切并调整露出位置。
@MainActor
public final class ImageContent: DesktopContent {
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

    public func setDisplay(fitsWhole: Bool, position: Float) {
        imageView.fitsWhole = fitsWhole
        imageView.position = CGFloat(min(max(position, 0), 1))
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
        guard imageView.fitsWhole || imageView.position != 0.5,
              targetPixelSize.width > 0, targetPixelSize.height > 0
        else { return image }
        let bounds = CGRect(origin: .zero, size: targetPixelSize)
        let place = Self.imageFrame(
            in: bounds, imageSize: CGSize(width: image.width, height: image.height),
            fitsWhole: imageView.fitsWhole, position: imageView.position)
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

    private nonisolated static func decode(_ url: URL, targetPixelSize: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let longest = Int(max(targetPixelSize.width, targetPixelSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(longest > 0 ? longest : 8192, 8192)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 图片层在视图坐标里的位置。铺满时按大的比例缩放，`position` 从左上到右下；
    /// 完整显示时按小的比例缩放并居中。
    nonisolated static func imageFrame(
        in bounds: CGRect, imageSize: CGSize, fitsWhole: Bool, position: CGFloat
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = fitsWhole
            ? min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            : max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(
            width: (imageSize.width * scale).rounded(),
            height: (imageSize.height * scale).rounded())
        let spare = CGSize(width: bounds.width - size.width, height: bounds.height - size.height)
        let along = min(max(position, 0), 1)
        let x = spare.width <= 0 ? spare.width * along : spare.width / 2
        // AppKit 的 y 轴向上：0 表示露出图片顶部，因此纵向反向平移。
        let y = spare.height <= 0 ? spare.height * (1 - along) : spare.height / 2
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
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
            in: bounds, imageSize: size, fitsWhole: fitsWhole, position: position)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
