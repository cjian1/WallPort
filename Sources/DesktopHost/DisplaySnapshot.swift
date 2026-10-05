import AppKit

/// 某一时刻一块显示器的状态。与 NSScreen 解耦，便于脱离真实硬件做单元测试。
public struct DisplaySnapshot: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    /// AppKit 全局坐标系下的屏幕矩形，单位是点
    public let frame: CGRect
    public let scale: CGFloat

    public init(id: CGDirectDisplayID, name: String, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
    }

    public var pixelSize: CGSize {
        CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    /// 跨重启稳定的显示器标识，用来保存逐屏设置。
    /// CGDirectDisplayID 对外接屏来说重启或换接口后可能变化，UUID 不会。取不到时退回 ID
    public var stableKey: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid)
        else { return "display-\(id)" }
        return text as String
    }

    /// 写日志和菜单用的一行描述
    public var summary: String {
        let scaleText = String(format: "%g", scale)
        return "\(name)[\(id)] \(Int(frame.width))×\(Int(frame.height))点 @\(scaleText)x"
            + " 原点(\(Int(frame.minX)),\(Int(frame.minY)))"
    }
}

extension DisplaySnapshot {
    @MainActor
    init?(screen: NSScreen) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        self.init(
            id: CGDirectDisplayID(number.uint32Value),
            name: screen.localizedName,
            frame: screen.frame,
            scale: screen.backingScaleFactor)
    }
}
