import AppKit
import Metal
import Testing
@testable import DesktopHost

/// 换壁纸（以及改设置重建场景）时，旧画面要留到新内容画出第一帧为止——先把旧内容拆掉的话，
/// 窗口露出来的是新视图的黑色背景，看起来就是"黑一下"（场景现建渲染器要 0.1–3.7 秒）。
@MainActor
@Suite struct ContentHandoffTests {
    /// 想什么时候算"能画了"由测试决定；`whenReady` 的回调也按内容的实现走
    final class FakeContent: DesktopContent {
        let view = NSView()
        var isReady = false
        var isPlaceholder = false
        private var readyHandler: (@MainActor () -> Void)?
        private(set) var tearDownCount = 0

        func whenReady(_ handler: @escaping @MainActor () -> Void) {
            if isReady { handler() } else { readyHandler = handler }
        }

        func becomeReady() {
            isReady = true
            readyHandler?()
            readyHandler = nil
        }

        func displayDidChange(_ display: DisplaySnapshot) {}
        func visibilityDidChange(isVisible: Bool) {}
        func tearDown() { tearDownCount += 1 }
    }

    /// 离屏的假显示器：窗口建出来但不会出现在屏幕上
    private func fakeDisplay() -> DisplaySnapshot {
        DisplaySnapshot(
            id: 999_001, name: "测试屏",
            frame: CGRect(x: -30_000, y: -30_000, width: 320, height: 200), scale: 2)
    }

    private func makeController(_ contents: [FakeContent]) -> WallpaperController {
        var remaining = contents
        let log = EventLog(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("handoff-test.log"))
        let controller = WallpaperController(level: .desktop, log: log) { _ in
            remaining.isEmpty ? FakeContent() : remaining.removeFirst()
        }
        controller.displaySource = { [self.fakeDisplay()] }
        return controller
    }

    /// 新的还没画出第一帧时：旧内容不许拆、旧画面还盖在上面
    @Test func oldContentStaysUntilNewContentIsReady() {
        let first = FakeContent()
        first.isReady = true
        let second = FakeContent()
        let controller = makeController([first, second])
        controller.start()
        defer { controller.stop() }
        let id = fakeDisplay().id
        #expect(controller.content(for: id) === first)

        controller.reloadContent(for: id)

        #expect(controller.content(for: id) === first, "新内容还没画出来，当前内容不能先换掉")
        #expect(first.tearDownCount == 0, "旧内容要等新画面出来再拆，否则就是黑一下")
        #expect(first.view.superview != nil, "旧画面要留在屏幕上")
        #expect(second.view.superview === first.view.superview, "新旧视图在同一个容器里")
        #expect(first.view.superview?.subviews.first === second.view, "新视图在下面，旧画面盖着它")

        second.becomeReady()

        #expect(controller.content(for: id) === second)
        #expect(first.tearDownCount == 1, "换完要把旧内容拆掉")
        #expect(first.view.superview == nil)
        #expect(second.view.superview != nil, "新画面接着显示")
    }

    /// 不放动态壁纸（壁纸库还是空的）：窗口一直全透明，桌面上是系统壁纸；换上真正的壁纸、画出第一帧才显示；
    /// 再换回"不放"又变回全透明
    @Test func systemWallpaperKeepsTheWindowTransparent() {
        let real = FakeContent()
        var queue: [any DesktopContent] = [SystemWallpaperContent(), real, SystemWallpaperContent()]
        let log = EventLog(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("handoff-test.log"))
        let controller = WallpaperController(level: .desktop, log: log) { _ in queue.removeFirst() }
        controller.displaySource = { [self.fakeDisplay()] }
        controller.start()
        defer { controller.stop() }
        let id = fakeDisplay().id
        #expect(controller.content(for: id)?.showsSystemWallpaper == true)
        #expect(!controller.isRevealed(id), "不放动态壁纸时窗口不显示，露出系统壁纸")

        controller.reloadContent(for: id)
        #expect(!controller.isRevealed(id), "新壁纸还没画出第一帧：继续露着系统壁纸")
        real.becomeReady()
        #expect(controller.content(for: id) === real)
        #expect(controller.isRevealed(id), "画出来了，显示窗口")

        controller.reloadContent(for: id)
        #expect(controller.content(for: id)?.showsSystemWallpaper == true)
        #expect(!controller.isRevealed(id), "换回不放动态壁纸：窗口又变全透明")
        #expect(real.tearDownCount == 1)
    }

    /// 新内容一直画不出来（例如坏掉的视频）：到点也要换，不能一直留着旧画面
    @Test func handoffGivesUpAfterTimeout() async throws {
        let first = FakeContent()
        first.isReady = true
        let second = FakeContent()
        let controller = makeController([first, second])
        controller.handoffTimeout = .milliseconds(100)
        controller.start()
        defer { controller.stop() }
        let id = fakeDisplay().id

        controller.reloadContent(for: id)
        try await Task.sleep(for: .milliseconds(400))

        #expect(controller.content(for: id) === second)
        #expect(first.tearDownCount == 1)
        #expect(first.view.superview == nil)
        #expect(second.view.superview != nil)
    }

    /// 连着换好几张：中间那些还没画出来的要拆掉、视图也要撤掉，只留最后一张
    @Test func rapidSwitchingKeepsOnlyTheLast() {
        let first = FakeContent()
        first.isReady = true
        let second = FakeContent()
        let third = FakeContent()
        let controller = makeController([first, second, third])
        controller.start()
        defer { controller.stop() }
        let id = fakeDisplay().id

        controller.reloadContent(for: id)
        controller.reloadContent(for: id)

        #expect(second.tearDownCount == 1, "被顶掉的那一张要拆掉")
        #expect(second.view.superview == nil)
        #expect(third.view.superview != nil)
        #expect(first.tearDownCount == 0, "最新的还没画出来，第一张继续显示")

        third.becomeReady()

        #expect(controller.content(for: id) === third)
        #expect(first.tearDownCount == 1)
        #expect(first.view.superview == nil)
        #expect(third.view.superview != nil)
    }

    /// 新窗口在第一份内容画出来之前全透明：用户看到的还是原来的系统壁纸，而不是黑底
    @Test func newWindowStaysTransparentUntilContentIsReady() {
        let first = FakeContent()
        let controller = makeController([first])
        controller.start()
        defer { controller.stop() }
        let id = fakeDisplay().id
        #expect(!controller.isRevealed(id), "内容还没画出来，窗口不能先盖住原来的壁纸")
        first.becomeReady()
        #expect(controller.isRevealed(id))
    }

    /// 启动时项目还在读（读取可能在等用户回应系统授权）：占位内容不显示窗口，
    /// 读完换上真正的内容、画出第一帧才显示——用户点"允许"之前桌面保持原样
    @Test func placeholderNeverRevealsTheWindow() async throws {
        let loading = FakeContent()
        loading.isPlaceholder = true
        loading.isReady = true
        let scene = FakeContent()
        let controller = makeController([loading, scene])
        controller.handoffTimeout = .milliseconds(50)
        controller.start()
        defer { controller.stop() }
        let id = fakeDisplay().id
        try await Task.sleep(for: .milliseconds(200))
        #expect(!controller.isRevealed(id), "占位内容等多久都不该把窗口显示出来")

        controller.reloadContent(for: id)
        #expect(!controller.isRevealed(id))
        scene.becomeReady()
        #expect(controller.content(for: id) === scene)
        #expect(controller.isRevealed(id))
        #expect(loading.tearDownCount == 1)
    }

    /// 换壁纸时新项目还在读：屏幕上的旧壁纸一直留着（超时也不换成占位图案），读完再换
    @Test func reloadingToAPlaceholderKeepsTheCurrentWallpaper() async throws {
        let first = FakeContent()
        first.isReady = true
        let loading = FakeContent()
        loading.isPlaceholder = true
        loading.isReady = true
        let next = FakeContent()
        let controller = makeController([first, loading, next])
        controller.handoffTimeout = .milliseconds(50)
        controller.start()
        defer { controller.stop() }
        let id = fakeDisplay().id

        controller.reloadContent(for: id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.content(for: id) === first, "占位内容不能换掉正在显示的壁纸")
        #expect(first.tearDownCount == 0)

        controller.reloadContent(for: id)
        #expect(loading.tearDownCount == 1, "被真正的内容顶掉的占位要拆掉")
        next.becomeReady()
        #expect(controller.content(for: id) === next)
        #expect(first.tearDownCount == 1)
    }

    /// 交接靠的是"新视图插在旧视图下面、被旧画面挡着也能画出第一帧"。
    /// 这里确认被挡住的 CAMetalLayer 照样拿得到 drawable——拿不到的话新场景永远画不出第一帧
    @Test func obscuredMetalLayerStillGetsADrawable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = NSWindow(
            contentRect: CGRect(x: -30_000, y: -30_000, width: 200, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        container.wantsLayer = true
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let below = MetalProbeView(device: device, frame: container.bounds)
        let above = NSView(frame: container.bounds)
        above.wantsLayer = true
        above.layer?.backgroundColor = NSColor.red.cgColor
        container.addSubview(below)
        container.addSubview(above, positioned: .above, relativeTo: below)
        window.layoutIfNeeded()

        #expect(
            below.metalLayer.nextDrawable() != nil,
            "被旧画面挡住的新场景拿不到 drawable，那就画不出第一帧，旧画面只能等到超时")
    }
}

private final class MetalProbeView: NSView {
    let metalLayer = CAMetalLayer()

    init(device: any MTLDevice, frame: CGRect) {
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.drawableSize = frame.size
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer { metalLayer }
}
