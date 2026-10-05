import AppKit

/// 鼠标事件（画布之外的原始信息）：位置是 AppKit 全局坐标（点，原点左下），和 `NSEvent.mouseLocation` 一致
public struct GlobalMouseEvent: Sendable {
    public enum Kind: Sendable {
        case down
        case up
        case dragged
        /// 只是移动（没有按键）：用来驱动悬停
        case moved
    }

    public let kind: Kind
    public let location: CGPoint
    /// 按下到抬起之间的间隔（秒）；不是抬起事件时为 nil
    public let clickDuration: TimeInterval?
}

/// 全局鼠标监听：桌面窗口不接收鼠标事件（点按要能透到桌面），所以用 `NSEvent` 的全局监听拿点击和拖动。
///
/// 注意：全局监听只是"旁听"，点击照样会传给桌面（拖拽壁纸元素的同时，桌面上也会框选）。
/// 需要"壁纸独占鼠标"时得让窗口自己接收事件（`DesktopWindow.ignoresMouseEvents = false`），
/// 那会挡住桌面图标，所以没做成默认。
///
/// 全局监听收得到**所有**App 里的点击；只有按在桌面本身（按下的位置上面没有别的窗口）时才转给壁纸，
/// 否则在编辑器、浏览器里点一下也会触发壁纸脚本。移动不受限制（悬停和视差本来就跟着全局指针走）。
@MainActor
public final class GlobalMouseMonitor {
    private var monitors: [Any] = []
    private var lastDown: (time: TimeInterval, location: CGPoint)?
    /// 这次按下是不是按在桌面上；不是的话后面的拖动和抬起都不转发
    private var pressIsOnDesktop = false
    private let handler: @MainActor (GlobalMouseEvent) -> Void

    /// 按下后多久之内抬起算一次"点击"
    private static let clickWindow: TimeInterval = 0.4
    /// 按下到抬起之间允许的移动距离（点），超过就当拖拽
    private static let clickSlop: CGFloat = 4

    public init(handler: @escaping @MainActor (GlobalMouseEvent) -> Void) {
        self.handler = handler
    }

    public var isRunning: Bool { !monitors.isEmpty }

    public func start() {
        guard monitors.isEmpty else { return }
        // 移动也要监听：静止的场景靠它驱动悬停（有 display link 的场景每帧自己读指针）
        let masks: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: masks, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(monitor)
        }
    }

    public func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        lastDown = nil
    }

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            pressIsOnDesktop = Self.isDesktop(at: location)
            guard pressIsOnDesktop else { return }
            lastDown = (event.timestamp, location)
            handler(GlobalMouseEvent(kind: .down, location: location, clickDuration: nil))
        case .leftMouseUp:
            guard pressIsOnDesktop else { return }
            pressIsOnDesktop = false
            let duration = lastDown.map { event.timestamp - $0.time } ?? nil
            handler(GlobalMouseEvent(kind: .up, location: location, clickDuration: duration))
            lastDown = nil
        case .leftMouseDragged:
            guard pressIsOnDesktop else { return }
            handler(GlobalMouseEvent(kind: .dragged, location: location, clickDuration: nil))
        case .mouseMoved:
            handler(GlobalMouseEvent(kind: .moved, location: location, clickDuration: nil))
        default:
            break
        }
    }

    /// 这个位置（AppKit 全局坐标）最上面的是不是桌面：没有窗口，或者最上面的窗口在桌面图标那一层
    /// 或更低（Finder 的桌面图标窗口、壁纸窗口自己）。只读窗口的层级，不需要屏幕录制权限
    static func isDesktop(at location: CGPoint) -> Bool {
        let number = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let layer = (info.first?[kCGWindowLayer as String] as? NSNumber)?.intValue
        else { return true }
        return layer <= Int(CGWindowLevelForKey(.desktopIconWindow))
    }

    /// 这次抬起算不算一次点击（时间够短、也没怎么移动）
    public static func isClick(_ event: GlobalMouseEvent, from down: CGPoint?) -> Bool {
        guard event.kind == .up, let duration = event.clickDuration, duration <= clickWindow else { return false }
        guard let down else { return true }
        return hypot(event.location.x - down.x, event.location.y - down.y) <= clickSlop
    }
}
