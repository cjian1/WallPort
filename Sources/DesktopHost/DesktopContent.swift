import AppKit

/// 挂在桌面窗口里的内容。M0 是静态测试图案，之后的视频、网页和场景渲染都实现这个协议。
@MainActor
public protocol DesktopContent: AnyObject {
    var view: NSView { get }

    /// 所在显示器的分辨率、缩放或排列位置变了。窗口尺寸已经调整好，内容只需要跟着重排或重绘
    func displayDidChange(_ display: DisplaySnapshot)

    /// 窗口被完全遮挡（全屏应用、窗口铺满等）或重新露出来。内容可以据此暂停渲染
    func visibilityDidChange(isVisible: Bool)

    /// 内容被换掉或显示器被移除之前调用，用来停止播放、释放解码器
    func tearDown()

    /// 已经能画出画面时调用一次 `handler`（可能立刻调用）。换壁纸时控制器用它把旧画面留到
    /// 新内容能画为止——先把旧内容拆掉的话，露出来的是新视图的黑底，看起来就是"黑一下"
    func whenReady(_ handler: @escaping @MainActor () -> Void)

    /// 当前画面的一帧静态图，用来同步成系统壁纸。取不到时返回 nil
    func snapshot() async -> CGImage?

    /// 只是在等真正的内容（例如项目还在读，读取可能在等用户回应系统的访问授权）。
    /// 控制器不会拿它换掉屏幕上已有的画面，也不会因为它把刚建的窗口显示出来——
    /// 用户看到的一直是原来的画面，直到真正的内容画出第一帧
    var isPlaceholder: Bool { get }

    /// 这块屏幕不放动态壁纸、显示用户原来的系统壁纸（见 `SystemWallpaperContent`）：
    /// 控制器让窗口保持全透明，系统壁纸同步不截图、换回原来的那张
    var showsSystemWallpaper: Bool { get }
}

extension DesktopContent {
    public func tearDown() {}

    /// 默认当成立刻就能画（测试图案，以及不需要等第一帧的内容）
    public func whenReady(_ handler: @escaping @MainActor () -> Void) { handler() }

    public func snapshot() async -> CGImage? { nil }

    public var isPlaceholder: Bool { false }

    public var showsSystemWallpaper: Bool { false }
}

/// "不放动态壁纸"：这块屏幕显示用户原来的系统壁纸（壁纸库还是空的、或者用户选了不放）。
/// 视图是透明的、什么也不画；窗口也保持全透明，桌面上露出来的就是系统自己的壁纸
public final class SystemWallpaperContent: DesktopContent {
    public let view = NSView()

    public init() {}

    public var showsSystemWallpaper: Bool { true }
    public func displayDidChange(_ display: DisplaySnapshot) {}
    public func visibilityDidChange(isVisible: Bool) {}
}
