import AppKit
import DesktopHost

/// M0 的静态测试图案。只在显示器变化时重绘，不跑任何定时器，用来单独观察窗口本身的稳定性和 CPU 占用。
///
/// - 四角的黄色直角标记：检查窗口是否盖满整块屏幕，包括菜单栏和刘海区域；
/// - 每 100 点一条的网格：发现缩放和偏移错误；
/// - "第 N 代窗口"和创建时间：判断窗口有没有被意外重建；
/// - 可选的提示行：视频放不了时，说明原因。
final class TestPatternView: NSView, DesktopContent {
    private var display: DisplaySnapshot
    private let generation: Int
    private let notice: String?
    private let createdAt = Date()
    /// 只是在等项目读完（见 DesktopContent.isPlaceholder）：控制器不会拿它换掉屏幕上的画面
    let isPlaceholder: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(display: DisplaySnapshot, generation: Int, notice: String? = nil, isPlaceholder: Bool = false) {
        self.display = display
        self.generation = generation
        self.notice = notice
        self.isPlaceholder = isPlaceholder
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var view: NSView { self }

    func displayDidChange(_ display: DisplaySnapshot) {
        self.display = display
        needsDisplay = true
    }

    func visibilityDidChange(isVisible: Bool) {}

    func snapshot() async -> CGImage? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap.cgImage
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.24, green: 0.12, blue: 0.30, alpha: 1),
            ending: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.22, alpha: 1))
        gradient?.draw(in: bounds, angle: 90)
        drawGrid()
        drawCornerMarkers()
        drawCaption()
    }

    private func drawGrid() {
        let path = NSBezierPath()
        for x in stride(from: CGFloat(0), through: bounds.width, by: 100) {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
        }
        for y in stride(from: CGFloat(0), through: bounds.height, by: 100) {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
        }
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.07).setStroke()
        path.stroke()
    }

    private func drawCornerMarkers() {
        let length: CGFloat = 60
        let thickness: CGFloat = 6
        let width = bounds.width
        let height = bounds.height
        let bars = [
            // 左下
            CGRect(x: 0, y: 0, width: length, height: thickness),
            CGRect(x: 0, y: 0, width: thickness, height: length),
            // 右下
            CGRect(x: width - length, y: 0, width: length, height: thickness),
            CGRect(x: width - thickness, y: 0, width: thickness, height: length),
            // 左上
            CGRect(x: 0, y: height - thickness, width: length, height: thickness),
            CGRect(x: 0, y: height - length, width: thickness, height: length),
            // 右上
            CGRect(x: width - length, y: height - thickness, width: length, height: thickness),
            CGRect(x: width - thickness, y: height - length, width: thickness, height: length),
        ]
        NSColor.systemYellow.setFill()
        bars.forEach { NSBezierPath.fill($0) }
    }

    private func drawCaption() {
        let pixels = display.pixelSize
        let scale = String(format: "%g", display.scale)
        let created = Self.timeFormatter.string(from: createdAt)
        let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        let detailColor = NSColor.white.withAlphaComponent(0.85)

        var lines: [(String, NSFont, NSColor)] = [
            (display.name, .systemFont(ofSize: 44, weight: .bold), .white),
            (String(localized: "\(Int(display.frame.width)) × \(Int(display.frame.height)) 点 · \(Int(pixels.width)) × \(Int(pixels.height)) 像素 · @\(scale)x"),
             detailFont, detailColor),
            (String(localized: "显示器 \(display.id) · 第 \(generation) 代窗口 · 创建于 \(created)"), detailFont, detailColor),
        ]
        if let notice {
            lines.append((notice, .systemFont(ofSize: 20, weight: .medium), .systemOrange))
        }
        lines.append((String(localized: "壁坞 WallPort · 桌面层测试图案"), .systemFont(ofSize: 15), .white.withAlphaComponent(0.5)))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 10
        let text = NSMutableAttributedString()
        for (index, (string, font, color)) in lines.enumerated() {
            let suffix = index == lines.count - 1 ? "" : "\n"
            text.append(NSAttributedString(
                string: string + suffix,
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }

        let size = text.boundingRect(
            with: CGSize(width: bounds.width - 80, height: bounds.height),
            options: [.usesLineFragmentOrigin]).size
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(with: CGRect(origin: origin, size: size), options: [.usesLineFragmentOrigin])
    }
}
