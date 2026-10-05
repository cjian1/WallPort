import AppKit
import CoreGraphics

/// 桌面被普通窗口挡住了多少。
///
/// 系统的遮挡通知（`occlusionState`）只在桌面**完全**看不见时才报"被遮挡"：把窗口放大到铺满屏幕，
/// 菜单栏和程序坞后面还透着一条桌面，系统照样当它"可见"，壁纸就在几乎看不见的情况下照常每秒画 30 帧。
/// 这里按屏幕上窗口的位置自己算：显示器的可用区域（去掉菜单栏和程序坞）几乎都被不透明的普通窗口盖住，
/// 就当桌面看不见。只读窗口的位置和层级，不读窗口内容和标题，不需要"屏幕录制"授权。
public enum DesktopCoverage {
    /// 可用区域里露出来的部分少于这个比例，就当桌面看不见（窗口之间的缝、没盖满的一小条不算）
    public static let visibleThreshold = 0.1

    /// `region` 里没被 `windows` 盖住的比例（0…1）。按网格取点估算，几十个窗口也只要几十微秒
    public static func uncoveredFraction(
        of region: CGRect, windows: [CGRect], columns: Int = 40, rows: Int = 24
    ) -> Double {
        guard region.width > 0, region.height > 0, columns > 0, rows > 0 else { return 1 }
        let relevant = windows.filter { $0.intersects(region) }
        guard !relevant.isEmpty else { return 1 }
        var uncovered = 0
        for row in 0..<rows {
            let y = region.minY + (CGFloat(row) + 0.5) * region.height / CGFloat(rows)
            for column in 0..<columns {
                let x = region.minX + (CGFloat(column) + 0.5) * region.width / CGFloat(columns)
                let point = CGPoint(x: x, y: y)
                if !relevant.contains(where: { $0.contains(point) }) { uncovered += 1 }
            }
        }
        return Double(uncovered) / Double(columns * rows)
    }

    /// 屏幕上的普通窗口（第 0 层、不透明）在全局坐标里的位置（原点在主显示器左上角，y 向下，和
    /// `CGDisplayBounds` 一样）。半透明的窗口后面还看得见桌面，不算
    @MainActor
    public static func onScreenWindowFrames() -> [CGRect] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 >= 0.95,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 1, frame.height > 1
            else { return nil }
            return frame
        }
    }

    /// 显示器上去掉菜单栏和程序坞以后的区域，全局坐标（原点在主显示器左上角，y 向下）
    @MainActor
    public static func usableRegion(of display: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }), let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return nil }
        // NSScreen 的坐标原点在主显示器左下角、y 向上；窗口列表的在左上角、y 向下
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: main.frame.height - visible.maxY, width: visible.width, height: visible.height)
    }
}
