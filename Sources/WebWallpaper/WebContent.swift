import AppKit
import DesktopHost
import WebKit

/// 网页壁纸：在 WKWebView 里加载项目文件夹中的页面，并注入与 Wallpaper Engine 网页壁纸接口兼容的脚本。
///
/// - 页面加载完后调用 applyGeneralProperties，再用 project.json 里的全部用户属性调用 applyUserProperties；
/// - 暂停和恢复时调用 setPaused，同时暂停页面里的音视频。何时暂停由 PlaybackGate 决定；
/// - 页面的 console 输出和脚本错误写进诊断日志；
/// - 数据存储不落盘，不允许弹新窗口，也不允许主页面跳转到项目之外；可以整体禁止联网。
@MainActor
public final class WebContent: NSObject, DesktopContent, UserPausable, AudioPlaying, FrameRateAdjustable {
    public var view: NSView { webView }
    public var isPausedByUser: Bool { gate.isPausedByUser }

    private let webView: WKWebView
    private let entryPath: String
    private let userProperties: String
    private let allowNetwork: Bool
    private let label: String
    private let log: EventLog
    private let debugCapture: URL?
    private var isLoaded = false
    /// 页面里音视频元素的音量（见 `setVolume`）
    private var pageVolume: Float = 1
    /// 页面能显示之前，控制器靠它把旧画面留在屏幕上
    private var readyHandler: (@MainActor () -> Void)?
    private var consoleLines = 0
    private var processRestarts = 0

    private lazy var gate = PlaybackGate { [weak self] playing, reason in
        self?.playbackDidChange(playing, reason: reason)
    }

    /// 页面动画的帧率上限。兼容脚本按它节流 requestAnimationFrame，也通过 applyGeneralProperties 告诉页面
    private static let frameRate = 30
    /// 页面动画的帧率上限；性能设置可以调整
    private var currentFrameRate = WebContent.frameRate
    private static let maxConsoleLines = 200
    private static let maxProcessRestarts = 3

    /// - Parameters:
    ///   - folder: 项目文件夹，页面只能读取其中的文件
    ///   - entry: 入口页面，必须位于 folder 之内
    ///   - userProperties: project.json 里 general.properties 的 JSON
    ///   - debugCapture: 开发用。设置后，页面加载完会测一次动画帧率，并把页面截图存到这个文件
    public init(
        folder: URL, entry: URL, userProperties: Data?, allowNetwork: Bool, label: String, log: EventLog,
        debugCapture: URL? = nil
    ) {
        let base = folder.standardizedFileURL.path + "/"
        entryPath = String(entry.standardizedFileURL.path.dropFirst(base.count))
        self.userProperties = userProperties.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.allowNetwork = allowNetwork
        self.label = label
        self.log = log
        self.debugCapture = debugCapture

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(ProjectSchemeHandler(folder: folder), forURLScheme: ProjectSchemeHandler.scheme)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BridgeScript.source(frameRate: currentFrameRate),
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        configuration.userContentController.add(WeakMessageHandler(self), name: BridgeScript.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 页面没设背景时透出窗口的黑底，而不是 WebKit 默认的白底
        if webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        setPageMuted(true)

        log.write("\(label) 网页：载入 \(folder.path)/\(entryPath)（\(allowNetwork ? "允许联网" : "禁止联网")）")
        gate.start(reason: "载入")
        Task { await prepareAndLoad() }
    }

    public func setPausedByUser(_ paused: Bool) {
        gate.setPausedByUser(paused)
    }

    /// 帧率上限：页面里的兼容脚本按它节流 requestAnimationFrame，同时告诉页面（applyGeneralProperties）。
    /// 0 表示不限制：节流放到 120 帧，实际就跟着显示器的刷新率走
    public func setMaximumFrameRate(_ fps: Int) {
        currentFrameRate = fps > 0 ? fps : 120
        guard isLoaded else { return }
        var script = "window.__wallpaperSetFrameRate(\(currentFrameRate));"
            + "window.__wallpaperApply('applyGeneralProperties', {\"fps\": \(currentFrameRate)});"
        if !gate.isPlaying { script += Self.pauseScript(paused: true) }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// 用户在设置面板里改了属性：和 WE 一样只把改了的那几项传给页面的 applyUserProperties。
    /// 页面还没加载完时不用管，加载完会用构造时给的（已经含用户改动的）全部属性
    public func applyUserProperties(_ changed: Data) {
        guard isLoaded, let json = String(data: changed, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__wallpaperApply('applyUserProperties', \(json));", completionHandler: nil)
    }

    /// 暂停时页面的媒体本来就被挂起（setAllMediaPlaybackSuspended），这里只管静不静音
    public func setAudioEnabled(_ enabled: Bool) {
        setPageMuted(!enabled)
    }

    /// 网页没有整页的音量接口：兼容脚本把页面里的 <audio> / <video> 都调到这个音量（之后新放的也一样）。
    /// 页面自己用 Web Audio 出的声音管不到，只能整页静音
    public func setVolume(_ volume: Float) {
        pageVolume = min(max(volume, 0), 1)
        guard isLoaded else { return }
        webView.evaluateJavaScript("window.__wallpaperSetVolume(\(pageVolume));", completionHandler: nil)
    }

    // MARK: - DesktopContent

    /// WKWebView 跟着窗口自动改变视口大小，页面自己处理 resize
    public func displayDidChange(_ display: DisplaySnapshot) {}

    public func visibilityDidChange(isVisible: Bool) {
        gate.setVisible(isVisible)
    }

    public func snapshot() async -> CGImage? {
        guard isLoaded else { return nil }
        do {
            let image = try await webView.takeSnapshot(configuration: nil)
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } catch {
            log.write("\(label) 网页：截取当前画面失败 \(error.localizedDescription)")
            return nil
        }
    }

    public func tearDown() {
        gate.invalidate()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: - 加载

    private func prepareAndLoad() async {
        if !allowNetwork {
            do {
                let rules = try await Self.networkBlockRules()
                webView.configuration.userContentController.add(rules)
            } catch {
                // 规则编译失败时宁可不加载，也不要在用户关掉联网的情况下放行
                log.write("\(label) 网页：禁止联网的规则编译失败，不加载页面：\(error.localizedDescription)")
                return
            }
        }
        load()
    }

    private func load() {
        guard let url = ProjectSchemeHandler.url(for: entryPath) else {
            log.write("\(label) 网页：入口路径无效 \(entryPath)")
            return
        }
        isLoaded = false
        webView.load(URLRequest(url: url))
    }

    /// WebKit 内容规则的正则不支持 |，所以每种协议各写一条
    private static func networkBlockRules() async throws -> WKContentRuleList {
        let rules = #"""
        [{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
         {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}}]
        """#
        guard let store = WKContentRuleListStore.default(),
              let list = try await store.compileContentRuleList(
                forIdentifier: "local.macwallpaper.block-network", encodedContentRuleList: rules)
        else { throw CocoaError(.featureUnsupported) }
        return list
    }

    /// 壁纸默认静音，和视频壁纸一致。WebKit 没有公开的静音接口，这里用 WKWebView 的私有方法 _setPageMuted:
    /// （参数 1 表示静音音频，0 表示不静音）；方法不存在时不静音，只记一条日志
    private func setPageMuted(_ muted: Bool) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else {
            if muted { log.write("\(label) 网页：当前系统没有静音接口，页面的声音不会被静音") }
            return
        }
        typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        let setPageMuted = unsafeBitCast(webView.method(for: selector), to: SetPageMuted.self)
        setPageMuted(webView, selector, muted ? 1 : 0)
    }

    /// 开发用：测 5 秒内派发的动画回调次数，再把页面截图存下来
    private func captureForDebugging(to file: URL) async {
        let before = await deliveredFrames()
        try? await Task.sleep(for: .seconds(5))
        let after = await deliveredFrames()
        let rate = (after ?? 0) - (before ?? 0)
        do {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = 1000
            let image = try await webView.takeSnapshot(configuration: configuration)
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: file)
            log.write("\(label) 网页调试：动画回调 \(Double(rate) / 5) 次/秒，截图 \(file.path)")
        } catch {
            log.write("\(label) 网页调试：动画回调 \(Double(rate) / 5) 次/秒，截图失败 \(error.localizedDescription)")
        }
    }

    private func deliveredFrames() async -> Int? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.__wallpaperDeliveredFrames()") { result, _ in
                continuation.resume(returning: (result as? NSNumber)?.intValue)
            }
        }
    }

    // MARK: - 状态与消息

    /// 页面能显示时回调一次。换壁纸时控制器靠它把旧画面留到这时候
    public func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if isLoaded { handler(); return }
        readyHandler = handler
    }

    private func firstFrameDidDraw() {
        readyHandler?()
        readyHandler = nil
    }

    private func playbackDidChange(_ playing: Bool, reason: String) {
        log.write("\(label) 网页：\(playing ? "运行" : "暂停")（\(reason)）")
        webView.setAllMediaPlaybackSuspended(!playing)
        guard isLoaded else { return }
        webView.evaluateJavaScript(Self.pauseScript(paused: !playing), completionHandler: nil)
    }

    /// 通知页面暂停或恢复，同时冻结或恢复动画回调
    private static func pauseScript(paused: Bool) -> String {
        "window.__wallpaperSetFrozen(\(paused)); window.__wallpaperApply('setPaused', \(paused));"
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "console":
            guard consoleLines < Self.maxConsoleLines else { return }
            consoleLines += 1
            let text = (body["payload"] as? String ?? "").prefix(500)
            log.write("\(label) 网页控制台：\(text)")
            if consoleLines == Self.maxConsoleLines {
                log.write("\(label) 网页控制台：已记录 \(consoleLines) 条，之后的输出不再记录")
            }
        case "audioListener":
            log.write("\(label) 网页：页面注册了音频监听（音频数据尚未接入）")
        default:
            break
        }
    }
}

extension WebContent: WKNavigationDelegate, WKUIDelegate {
    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if ["wallpaper", "about", "data", "blob"].contains(url.scheme ?? "") { return .allow }
        // iframe 里的外部页面（例如嵌入的视频）放行，是否能联网由内容规则决定；主页面不许跳走
        if navigationAction.targetFrame?.isMainFrame == false { return .allow }
        log.write("\(label) 网页：拦截了主页面跳转 \(url.absoluteString)")
        return .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        log.write("\(label) 网页：加载完成")
        // 页面开头注入的兼容脚本是按默认帧率建的，加载完按当前设置改过来（加载前改的设置也要在这里补上）
        var script = "window.__wallpaperSetFrameRate(\(currentFrameRate));"
            + "window.__wallpaperApply('applyGeneralProperties', {\"fps\": \(currentFrameRate)});"
            + "window.__wallpaperApply('applyUserProperties', \(userProperties));"
            + "window.__wallpaperSetVolume(\(pageVolume));"
        if !gate.isPlaying { script += Self.pauseScript(paused: true) }
        webView.evaluateJavaScript(script, completionHandler: nil)
        if let debugCapture {
            Task { await captureForDebugging(to: debugCapture) }
        }
        // WKWebView 没有"第一帧画出来了"的回调：加载完成后再等一次屏幕刷新（150 毫秒）就当能显示了。
        // 页面一直画不出来时还有控制器的超时兜底，所以这里给的是一个近似值
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.firstFrameDidDraw()
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        log.write("\(label) 网页：加载失败 \(error.localizedDescription)")
        // 加载不出来就没有可等的东西了，别让旧画面一直占着
        firstFrameDidDraw()
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        log.write("\(label) 网页：打开失败 \(error.localizedDescription)")
        firstFrameDidDraw()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        guard processRestarts < Self.maxProcessRestarts else {
            log.write("\(label) 网页：页面进程已退出 \(processRestarts + 1) 次，不再重启")
            return
        }
        processRestarts += 1
        log.write("\(label) 网页：页面进程退出，第 \(processRestarts) 次重新加载")
        load()
    }

    /// 不允许 window.open 之类的新窗口
    public func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

/// WKUserContentController 会强引用消息处理者，经这一层转发避免 WebContent 和 WKWebView 互相持有
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebContent?

    init(_ target: WebContent) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}
