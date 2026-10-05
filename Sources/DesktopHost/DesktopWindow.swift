import AppKit

/// 桌面窗口所在的层级。
///
/// 哪一档在点按墙纸、显示桌面、台前调度、调度中心这些交互下最稳，只能实测，
/// 所以 M0 把它做成可以在菜单里切换的选项。
public enum DesktopLevel: String, CaseIterable, Sendable {
    /// 与系统壁纸同层，靠排序压在壁纸上面
    case desktop
    /// 比系统壁纸高一层
    case aboveDesktop
    /// 紧贴在桌面图标下面
    case belowIcons

    public var windowLevel: NSWindow.Level {
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        switch self {
        case .desktop: return NSWindow.Level(rawValue: desktop)
        case .aboveDesktop: return NSWindow.Level(rawValue: desktop + 1)
        case .belowIcons: return NSWindow.Level(rawValue: icons - 1)
        }
    }

    public var title: String {
        switch self {
        case .desktop: return String(localized: "桌面层（与系统壁纸同层）")
        case .aboveDesktop: return String(localized: "桌面层 + 1")
        case .belowIcons: return String(localized: "桌面图标层 − 1")
        }
    }
}

/// 贴在桌面层的无边框窗口：在系统壁纸之上、桌面图标之下，出现在所有空间里，不接收任何鼠标事件。
final class DesktopWindow: NSWindow {
    init(frame: CGRect, level: DesktopLevel) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = level.windowLevel
        // stationary：调度中心和显示桌面时不跟着别的窗口移走
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        isRestorable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 不让 AppKit 把窗口挤出菜单栏区域，必须盖满整块屏幕
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
