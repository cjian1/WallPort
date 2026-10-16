import AppKit
import DesktopHost
import ScreenSaver

/// 壁坞的屏幕保护程序（WallPort.saver）：显示动态壁纸当前的画面，也就是系统壁纸同步写下的截图
/// （`SystemWallpaperSync.latestFrame`）。
///
/// 为什么要有它：电脑空闲一段时间后系统启动的是**屏幕保护程序**，它和桌面壁纸分开设置，默认是系统自带壁纸的动画；
/// 锁屏是叠在屏保上面的，所以唤醒时看到的也是它。系统壁纸同步只能换桌面壁纸，换不了屏保，
/// 用户在系统设置里选中这个屏保以后，空闲、锁屏、唤醒时看到的才是自己的壁纸。
///
/// 跑在系统的 legacyScreenSaver 进程里：有沙盒，能读整个磁盘，但主目录是它自己的容器，
/// 所以截图的位置按真正的用户主目录拼（`AppFolder.userHome`）。每秒看一眼有没有更新的截图
/// （屏保一启动壁坞就会按此刻的画面重截一张），有就淡入换上。这块屏幕没有截图（壁坞没在运行、
/// 没放动态壁纸、关了同步）时显示它现在的系统壁纸。
@objc(WallPortSaverView)
final class WallPortSaverView: ScreenSaverView {
    /// 截图在哪（测试里换成临时文件夹）
    var framesDirectory = SystemWallpaperSync.defaultDirectory
    /// 测试里直接指定显示器，不必有真的屏幕；nil 时按视图所在的屏幕
    var displayKeyOverride: String?
    /// 现在显示的那张；同一张不重复读
    private(set) var shownFile: URL?
    let imageLayer = CALayer()
    /// 系统说屏保要停了。legacyScreenSaver 停下以后不一定调 `stopAnimation`，进程也常常留着、接着发动画回调，
    /// 不自己停的话会一直每秒读一次文件夹
    private var stopped = false
    private var stopObserver: (any NSObjectProtocol)?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.frame = bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // 和同步时设的系统壁纸一样：等比铺满、裁掉多出来的
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override func startAnimation() {
        super.startAnimation()
        stopped = false
        observeStop()
        refresh(animated: false)
    }

    override func stopAnimation() {
        super.stopAnimation()
        stopped = true
    }

    override func animateOneFrame() {
        refresh(animated: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 换到了另一块屏幕的窗口里（或者第一次放进窗口）：按那块屏幕重新找图
        refresh(animated: false)
    }

    private func observeStop() {
        guard stopObserver == nil else { return }
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopped = true
                if let observer = self.stopObserver { DistributedNotificationCenter.default().removeObserver(observer) }
                self.stopObserver = nil
            }
        }
    }

    // MARK: - 找图、换图

    /// 有更新的截图就换上；读不出来就留着现在这张
    func refresh(animated: Bool) {
        guard !stopped, let file = currentFile(), file != shownFile else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2
        let longest = Int((max(bounds.width, bounds.height) * scale).rounded(.up))
        guard let image = SystemWallpaperSync.loadImage(file, maxPixelSize: longest) else { return }
        shownFile = file
        CATransaction.begin()
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.6
            imageLayer.add(fade, forKey: "contents")
        } else {
            CATransaction.setDisableActions(true)
        }
        imageLayer.contents = image
        CATransaction.commit()
    }

    /// 这块屏幕最近同步的截图；没有就用它现在的系统壁纸
    private func currentFile() -> URL? {
        if let key = displayKeyOverride {
            return SystemWallpaperSync.latestFrame(forDisplayKey: key, in: framesDirectory)
        }
        guard let screen, let display = DisplaySnapshot(screen: screen) else { return nil }
        return SystemWallpaperSync.latestFrame(forDisplayKey: display.stableKey, in: framesDirectory)
            ?? NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// 视图在哪块屏幕上。legacyScreenSaver 里视图是远程显示的，`window.screen` 不一定靠得住：
    /// 它和视图一样大才信；否则按尺寸找唯一对得上的屏幕；对不上（系统设置里的预览、几块屏一样大）就当主屏
    private var screen: NSScreen? {
        if let screen = window?.screen, screen.frame.size == bounds.size { return screen }
        let primary = NSScreen.screens.first
        if isPreview { return primary }
        let matches = NSScreen.screens.filter { $0.frame.size == bounds.size }
        return matches.count == 1 ? matches[0] : primary
    }
}
