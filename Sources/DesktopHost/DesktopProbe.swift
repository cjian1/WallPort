import CoreGraphics
import Foundation

/// 读系统的窗口列表，检查桌面窗口的真实状态：是否在屏幕上、有没有被同层的系统壁纸盖住。
///
/// 只用到窗口编号、层级、所属进程和位置，这几项不需要屏幕录制权限。
public enum DesktopProbe {
    public struct WindowEntry: Equatable, Sendable {
        public let number: Int
        public let ownerName: String
        public let ownerPID: pid_t
        public let layer: Int
        /// CoreGraphics 全局坐标（原点在主屏左上角），与 AppKit 的坐标系不同
        public let bounds: CGRect
        public let alpha: Double

        public init(
            number: Int, ownerName: String, ownerPID: pid_t, layer: Int, bounds: CGRect, alpha: Double = 1
        ) {
            self.number = number
            self.ownerName = ownerName
            self.ownerPID = ownerPID
            self.layer = layer
            self.bounds = bounds
            self.alpha = alpha
        }
    }

    public enum Status: Equatable, Sendable {
        case onScreen
        /// 不在当前屏幕的窗口列表里
        case missing
        /// 同一层里别的进程的窗口排在前面，并且盖住了它的大半
        case covered(by: WindowEntry)
    }

    /// 当前屏幕上位于桌面图标层及以下的窗口，按从前到后排列
    public static func desktopWindows() -> [WindowEntry] {
        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap(WindowEntry.init(info:)).filter { $0.layer <= iconLayer }
    }

    /// 只把同层的窗口算作遮挡：更高层的窗口（例如桌面图标）本来就该在上面，
    /// 而且重新排序也改变不了跨层的前后关系。
    public static func status(of number: Int, in windows: [WindowEntry]) -> Status {
        guard let index = windows.firstIndex(where: { $0.number == number }) else { return .missing }
        let ours = windows[index]
        let blocker = windows[..<index].first { other in
            other.layer == ours.layer
                && other.ownerPID != ours.ownerPID
                && coverage(of: ours.bounds, by: other.bounds) > 0.5
        }
        return blocker.map { .covered(by: $0) } ?? .onScreen
    }

    /// 排在前面、层级比我们高但低于桌面图标、并且与我们有重叠的其他进程窗口。
    /// 它们如果不透明，就会把壁纸挡住，而且重新排序没用，只能换更高的层级，所以只记录、不修复。
    public static func overlays(above number: Int, in windows: [WindowEntry]) -> [WindowEntry] {
        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        guard let index = windows.firstIndex(where: { $0.number == number }) else { return [] }
        let ours = windows[index]
        return windows[..<index].filter { other in
            other.layer > ours.layer
                && other.layer < iconLayer
                && other.ownerPID != ours.ownerPID
                && coverage(of: ours.bounds, by: other.bounds) > 0
        }
    }

    /// target 被 other 覆盖的面积比例
    static func coverage(of target: CGRect, by other: CGRect) -> CGFloat {
        let overlap = target.intersection(other)
        guard !overlap.isNull, target.width > 0, target.height > 0 else { return 0 }
        return (overlap.width * overlap.height) / (target.width * target.height)
    }

    /// 日志用：把窗口列表写成一行，★ 标出我们自己的窗口
    public static func describe(_ windows: [WindowEntry], ours: Set<Int>) -> String {
        windows.map { entry in
            let mark = ours.contains(entry.number) ? "★" : ""
            return "\(mark)\(entry.ownerName)#\(entry.number)[\(layerName(entry.layer))]"
        }
        .joined(separator: " → ")
    }

    static func layerName(_ layer: Int) -> String {
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        switch layer {
        case desktop: return "桌面层"
        case icons: return "图标层"
        case let value where value > desktop && value < icons:
            return value - desktop <= icons - value ? "桌面层+\(value - desktop)" : "图标层-\(icons - value)"
        // macOS 27 上系统壁纸由 WindowManager 画在桌面层下面一层
        case let value where value < desktop && desktop - value < 100:
            return "桌面层-\(desktop - value)"
        default: return "L\(layer)"
        }
    }
}

extension DesktopProbe.WindowEntry {
    init?(info: [String: Any]) {
        guard let number = info[kCGWindowNumber as String] as? Int,
              let layer = info[kCGWindowLayer as String] as? Int,
              let pid = info[kCGWindowOwnerPID as String] as? Int,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo)
        else { return nil }
        self.init(
            number: number,
            ownerName: info[kCGWindowOwnerName as String] as? String ?? "?",
            ownerPID: pid_t(truncatingIfNeeded: pid),
            layer: layer,
            bounds: bounds,
            alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
    }
}
