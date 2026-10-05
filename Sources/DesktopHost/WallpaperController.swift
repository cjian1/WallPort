import AppKit

/// 为每块显示器维护一个桌面窗口，并在显示器插拔、分辨率变化、空间切换、睡眠唤醒之后保持同步。
///
/// 除了摆放窗口，它还负责回答 M0 要问清楚的问题：窗口在各种系统交互之后是否还在屏幕上、
/// 有没有被同层的系统壁纸盖住。每次相关事件之后、以及每 30 秒，都会跑一次自检并写日志；
/// 发现异常时把窗口重新排到本层最前面，并累计修复次数。
@MainActor
public final class WallpaperController: NSObject {
    public typealias ContentFactory = @MainActor (DisplaySnapshot) -> any DesktopContent

    public private(set) var level: DesktopLevel
    public private(set) var isShown = true
    public private(set) var displays: [DisplaySnapshot] = []
    /// 显示器接上、拔掉或者参数变了（`displays` 已经更新）之后调用：界面上的显示器列表跟着刷新
    public var onDisplaysChanged: (@MainActor () -> Void)?
    /// 桌面几乎被窗口盖满时当作看不见、让动态壁纸暂停（见 `DesktopCoverage`）。关掉就只按系统的遮挡通知
    public var pausesWhenCovered = true {
        didSet { if pausesWhenCovered != oldValue { updateCoverage() } }
    }
    /// 几乎被窗口盖满的显示器
    private var coveredDisplays: Set<CGDirectDisplayID> = []
    /// 屏幕睡了
    private var screensAsleep = false
    /// 切到了别的用户（快速用户切换）
    private var sessionInactive = false
    /// 整个桌面都看不见。两个原因分开记：切走以后屏幕睡了又醒，不能当成切回来了
    private var isAsleep: Bool { screensAsleep || sessionInactive }
    private var coverageTimer: Timer?
    /// 自检发现异常、把窗口重新排到前面的累计次数。长时间运行后应当是 0
    public private(set) var repairCount = 0

    /// 设置后，内容换上去几秒会截一帧同步成系统壁纸；设为 nil 不会自动恢复原壁纸，由调用方决定
    public var systemWallpaperSync: SystemWallpaperSync? {
        didSet {
            guard systemWallpaperSync != nil else {
                snapshotTasks.values.forEach { $0.cancel() }
                snapshotTasks = [:]
                return
            }
            for (id, slot) in slots { scheduleSnapshot(for: id, content: slot.content) }
        }
    }

    private let log: EventLog
    private let makeContent: ContentFactory
    private var slots: [CGDirectDisplayID: Slot] = [:]
    private var pendingProbeReasons: [String] = []
    private var watchdog: Timer?
    private var snapshotTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]

    /// 显示器快照的来源。默认读 NSScreen；测试里换成假的，就不必在真实屏幕上建窗口
    var displaySource: @MainActor () -> [DisplaySnapshot] = {
        NSScreen.screens.compactMap(DisplaySnapshot.init(screen:))
    }
    /// 换上新的内容后，等它画出第一帧最多等多久（兜底，正常路径用不到）
    var handoffTimeout: Duration = .seconds(5)

    /// 内容换上去后等这么久再截图，让视频和网页先画出第一帧
    private static let snapshotDelay: Duration = .seconds(3)

    private struct Slot {
        let window: DesktopWindow
        /// 内容视图的容器：换内容时新旧两个视图会同时在里面（新的在下、旧的在上），
        /// 新的画出第一帧再撤掉旧的
        let container: NSView
        /// 现在屏幕上显示的内容
        var content: any DesktopContent
        /// 正在准备、还没画出第一帧的新内容
        var pending: Pending?

        struct Pending {
            let content: any DesktopContent
            /// 占位内容没有超时：它本来就画不出东西，等的是下一次 `reloadContent` 换上真正的内容
            let timeout: Task<Void, Never>?
        }
        /// 刚建的窗口在第一份真正的内容画出来之前是全透明的（见 `createSlot`）；这是兜底显示它的计时
        var revealTimeout: Task<Void, Never>?
    }

    public init(level: DesktopLevel, log: EventLog, makeContent: @escaping ContentFactory) {
        self.level = level
        self.log = log
        self.makeContent = makeContent
        super.init()
    }

    public func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        // 切换应用时窗口多半跟着变了：马上重算一次桌面露出来多少，不用等下一次定时检查
        workspace.addObserver(
            self, selector: #selector(applicationDidActivate),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // 每秒看一眼桌面被窗口挡住了多少（只读窗口位置，一次一两毫秒）
        let coverage = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(coverageTimerFired),
            userInfo: nil, repeats: true)
        coverage.tolerance = 0.3
        coverageTimer = coverage

        let timer = Timer.scheduledTimer(
            timeInterval: 30, target: self, selector: #selector(watchdogFired),
            userInfo: nil, repeats: true)
        timer.tolerance = 5
        watchdog = timer

        log.write("启动：层级 \(level.rawValue)（\(level.windowLevel.rawValue)）")
        syncDisplays(reason: "启动")
    }

    public func stop() {
        watchdog?.invalidate()
        watchdog = nil
        coverageTimer?.invalidate()
        coverageTimer = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for id in Array(slots.keys) { removeSlot(for: id) }
        displays = []
    }

    public func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        for slot in slots.values {
            if shown { slot.window.orderFrontRegardless() } else { slot.window.orderOut(nil) }
        }
        log.write(shown ? "显示壁纸" : "隐藏壁纸")
        if shown { scheduleProbe("重新显示") }
    }

    public func setLevel(_ newLevel: DesktopLevel) {
        guard newLevel != level else { return }
        level = newLevel
        for slot in slots.values {
            slot.window.level = newLevel.windowLevel
            if isShown { slot.window.orderFrontRegardless() }
        }
        log.write("切换层级：\(newLevel.rawValue)（\(newLevel.windowLevel.rawValue)）")
        scheduleProbe("切换层级")
    }

    /// 立即自检，并把完整的桌面层窗口列表写进日志
    public func probeNow(reason: String) {
        probe(reasons: [reason], verbose: true)
    }

    public func content(for id: CGDirectDisplayID) -> (any DesktopContent)? {
        slots[id]?.content
    }

    /// 重新向工厂要一份内容，替换这块显示器上现有的内容（例如换了一个视频）。窗口本身保留不动
    ///
    /// 新的内容画出第一帧之前，旧画面一直留在屏幕上（见 `finishHandoff`）：场景要现建渲染器
    /// （实测 0.1–3.7 秒），视频要等解码出第一帧，这段时间新视图只有一层黑底，
    /// 先把旧内容拆掉的话就是切换壁纸时看到的"黑一下"。
    public func reloadContent(for id: CGDirectDisplayID) {
        guard slots[id] != nil, let display = displays.first(where: { $0.id == id }) else { return }
        // 上一张还没交接完就又被换掉了（用户连着换了几张）：直接丢掉，只认最后一张
        discardPending(for: id)
        guard let slot = slots[id] else { return }

        let content = makeContent(display)
        // 新视图插在旧视图**下面**：旧画面继续盖在上面显示，新内容照样在窗口里，
        // 能拿到 drawable 画出第一帧（离了窗口的 CAMetalLayer / AVPlayerLayer 画不出东西）
        Self.add(content.view, to: slot.container, below: slot.content.view)
        // 占位内容（项目还在读）不接上去：旧画面一直留着，等读完再次 reloadContent 换上真正的内容。
        // 读取可能在等用户回应系统的访问授权，这期间换成占位图案的话，用户点"允许"之前壁纸就变了
        guard !content.isPlaceholder else {
            slots[id]?.pending = Slot.Pending(content: content, timeout: nil)
            return
        }
        // 窗口的遮挡状态没变，不会再收到通知，所以要主动告诉新内容
        content.visibilityDidChange(isVisible: isContentVisible(id, window: slot.window))
        let timeout = handoffTimeout
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finishHandoff(for: id, content: content, timedOut: true)
        }
        slots[id]?.pending = Slot.Pending(content: content, timeout: deadline)
        content.whenReady { [weak self] in self?.finishHandoff(for: id, content: content, timedOut: false) }
    }

    /// 新的内容画出第一帧了（或者等到超时兜底）：撤掉旧画面，把新的接上
    private func finishHandoff(for id: CGDirectDisplayID, content: any DesktopContent, timedOut: Bool) {
        guard let slot = slots[id], let pending = slot.pending, pending.content === content else { return }
        pending.timeout?.cancel()
        slots[id]?.pending = nil
        slot.content.view.removeFromSuperview()
        slot.content.tearDown()
        slots[id]?.content = pending.content
        log.write("显示器 \(id) 换内容完成（\(timedOut ? "等新画面超时 \(handoffTimeout)，先换上" : "新画面已就绪")）")
        reveal(id)
        // 截图同步系统壁纸要在交接完成之后排队：早排队的话拍到的还是被换掉的旧内容
        scheduleSnapshot(for: id, content: pending.content)
    }

    /// 丢掉还没交接完的新内容：它被新的替换掉了，或者窗口整个要拆了
    private func discardPending(for id: CGDirectDisplayID) {
        guard let pending = slots[id]?.pending else { return }
        slots[id]?.pending = nil
        pending.timeout?.cancel()
        pending.content.view.removeFromSuperview()
        pending.content.tearDown()
    }

    /// 把刚建时全透明的窗口显示出来（第一份真正的内容已经画出来了，或者等它超时了）。
    /// 现在的内容是"不放动态壁纸"时反过来：窗口保持（或者变回）全透明，露出系统壁纸
    private func reveal(_ id: CGDirectDisplayID) {
        guard let slot = slots[id] else { return }
        slot.revealTimeout?.cancel()
        slots[id]?.revealTimeout = nil
        let alpha: CGFloat = slot.content.showsSystemWallpaper ? 0 : 1
        guard slot.window.alphaValue != alpha else { return }
        slot.window.alphaValue = alpha
        log.write(alpha == 1 ? "显示器 \(id) 壁纸就绪，显示窗口" : "显示器 \(id) 不放动态壁纸，露出系统壁纸")
    }

    /// 窗口还是全透明的（第一份真正的内容还没画出来）。测试用
    func isRevealed(_ id: CGDirectDisplayID) -> Bool { (slots[id]?.window.alphaValue ?? 0) >= 1 }

    /// 把内容视图铺满容器；给了 `sibling` 就插在它的**下面**
    private static func add(_ view: NSView, to container: NSView, below sibling: NSView?) {
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: sibling == nil ? .above : .below, relativeTo: sibling)
    }

    // MARK: - 显示器同步

    private func syncDisplays(reason: String) {
        let current = displaySource()
        let changes = DisplayReconciler.changes(from: displays, to: current)
        displays = current
        guard !changes.isEmpty else {
            log.write("\(reason)：显示器配置无变化")
            scheduleProbe(reason)
            return
        }

        for id in changes.removed {
            removeSlot(for: id)
            log.write("\(reason)：移除显示器 \(id)")
        }
        for display in changes.updated {
            guard let slot = slots[display.id] else {
                createSlot(for: display)
                continue
            }
            slot.window.setFrame(display.frame, display: true)
            slot.content.displayDidChange(display)
            // 还在准备的那一份也要知道：场景按显示尺寸建渲染器，漏了的话接上以后是按旧尺寸画的
            slot.pending?.content.displayDidChange(display)
            scheduleSnapshot(for: display.id, content: slot.content)
            log.write("\(reason)：更新显示器 \(display.summary)")
        }
        for display in changes.added {
            createSlot(for: display)
            log.write("\(reason)：新增显示器 \(display.summary) UUID \(display.stableKey)")
        }
        scheduleProbe(reason)
        onDisplaysChanged?()
    }

    /// 新窗口先是**全透明**的：用户看到的还是原来的系统壁纸，等第一份真正的内容画出第一帧才显示。
    /// 原来一建好就显示，场景还在建（0.1–3.7 秒）、项目还在读的时候露出来的是黑底或占位图案；
    /// 读取在等用户回应系统授权的话，弹窗还没答，壁纸就先变成了占位图案。
    /// 窗口照样排在最前、只是透明，内容在里面照常建、照常画出第一帧（离了窗口的图层画不出东西）
    private func createSlot(for display: DisplaySnapshot) {
        let window = DesktopWindow(frame: display.frame, level: level)
        window.alphaValue = 0
        let container = NSView(frame: CGRect(origin: .zero, size: display.frame.size))
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        let content = makeContent(display)
        Self.add(content.view, to: container, below: nil)
        window.setFrame(display.frame, display: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        slots[display.id] = Slot(window: window, container: container, content: content)
        if isShown { window.orderFrontRegardless() }
        // 占位内容（项目还在读）不显示窗口，等读完 reloadContent 换上真正的内容、交接完成时再显示
        guard !content.isPlaceholder else { return }
        let id = display.id
        let timeout = handoffTimeout
        slots[id]?.revealTimeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.reveal(id)
        }
        content.whenReady { [weak self] in
            guard let self, self.slots[id]?.content === content else { return }
            self.reveal(id)
        }
        scheduleSnapshot(for: id, content: content)
    }

    private func removeSlot(for id: CGDirectDisplayID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        snapshotTasks.removeValue(forKey: id)?.cancel()
        slot.revealTimeout?.cancel()
        // 还没交接完的新内容也要拆掉（它的视图还在容器里）
        slot.pending?.timeout?.cancel()
        slot.pending?.content.view.removeFromSuperview()
        slot.pending?.content.tearDown()
        slot.content.tearDown()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: slot.window)
        slot.window.orderOut(nil)
        slot.window.close()
    }

    // MARK: - 系统事件

    @objc private func screenParametersDidChange() {
        syncDisplays(reason: "显示器参数变化")
    }

    @objc private func activeSpaceDidChange() {
        log.write("空间切换")
        systemWallpaperSync?.reapply()
        scheduleProbe("空间切换")
        updateCoverage()
    }

    @objc private func systemDidWake() {
        syncDisplays(reason: "系统唤醒")
    }

    @objc private func screensDidWake() {
        updateAsleep(reason: "屏幕唤醒") { screensAsleep = false }
        syncDisplays(reason: "屏幕唤醒")
    }

    @objc private func sessionDidBecomeActive() {
        updateAsleep(reason: "切回当前用户") { sessionInactive = false }
        syncDisplays(reason: "切回当前用户")
    }

    /// 屏幕关了（睡眠、锁屏后熄屏）：什么都看不见，动态壁纸全停
    @objc private func screensDidSleep() {
        updateAsleep(reason: "屏幕睡眠") { screensAsleep = true }
    }

    /// 切到了别的用户（快速用户切换）：这个用户的桌面看不见
    @objc private func sessionDidResignActive() {
        updateAsleep(reason: "切到别的用户") { sessionInactive = true }
    }

    @objc private func applicationDidActivate() {
        updateCoverage()
    }

    @objc private func coverageTimerFired() {
        updateCoverage()
    }

    @objc private func windowOcclusionDidChange(_ notification: Notification) {
        guard let window = notification.object as? DesktopWindow,
              let entry = slots.first(where: { $0.value.window === window })
        else { return }
        let visible = isContentVisible(entry.key, window: window)
        entry.value.content.visibilityDidChange(isVisible: visible)
        // 还在准备的那一份也要知道（它已经建好、也许已经开始渲染了）
        entry.value.pending?.content.visibilityDidChange(isVisible: visible)
        log.write("显示器 \(entry.key) 遮挡状态：\(window.occlusionState.contains(.visible) ? "可见" : "被完全遮挡")")
    }

    // MARK: - 桌面看不看得见

    /// 内容该不该当作"看得见"：窗口没被系统判为遮挡、桌面没被窗口盖满、屏幕没睡
    private func isContentVisible(_ id: CGDirectDisplayID, window: NSWindow) -> Bool {
        !isAsleep && window.occlusionState.contains(.visible) && !coveredDisplays.contains(id)
    }

    private func updateAsleep(reason: String, _ change: () -> Void) {
        let wasAsleep = isAsleep
        change()
        guard isAsleep != wasAsleep else { return }
        log.write("\(reason)：动态壁纸\(isAsleep ? "全部暂停" : "按是否看得见恢复")")
        notifyVisibility(of: Array(slots.keys))
    }

    /// 重算每块显示器被窗口挡住了多少，有变化的告诉它的内容
    private func updateCoverage() {
        var covered: Set<CGDirectDisplayID> = []
        if pausesWhenCovered, isShown, !isAsleep, !slots.isEmpty {
            let windows = DesktopCoverage.onScreenWindowFrames()
            for id in slots.keys {
                guard let region = DesktopCoverage.usableRegion(of: id) else { continue }
                if DesktopCoverage.uncoveredFraction(of: region, windows: windows) < DesktopCoverage.visibleThreshold {
                    covered.insert(id)
                }
            }
        }
        guard covered != coveredDisplays else { return }
        let changed = covered.symmetricDifference(coveredDisplays)
        coveredDisplays = covered
        for id in changed {
            log.write("显示器 \(id) \(covered.contains(id) ? "几乎被窗口盖满，按看不见处理（动态壁纸暂停）" : "桌面露出来了")")
        }
        notifyVisibility(of: Array(changed))
    }

    private func notifyVisibility(of ids: [CGDirectDisplayID]) {
        for id in ids {
            guard let slot = slots[id] else { continue }
            let visible = isContentVisible(id, window: slot.window)
            slot.content.visibilityDidChange(isVisible: visible)
            slot.pending?.content.visibilityDidChange(isVisible: visible)
        }
    }

    @objc private func watchdogFired() {
        probe(reasons: ["定时巡检"], verbose: false)
    }

    // MARK: - 同步系统壁纸

    /// 同步的设置变了（例如换了锁屏壁纸）：马上按新设置重新设一遍系统壁纸
    public func resyncSystemWallpaper() {
        for (id, slot) in slots { scheduleSnapshot(for: id, content: slot.content, delay: .zero) }
    }

    /// 给这块显示器**现在显示**的那份内容排一次截图；内容换掉之后要重新排（见 `finishHandoff`）
    private func scheduleSnapshot(
        for id: CGDirectDisplayID, content: any DesktopContent, delay: Duration = snapshotDelay, attempt: Int = 1
    ) {
        snapshotTasks[id]?.cancel()
        // 占位内容不同步成系统壁纸（它不是用户选的壁纸）
        guard let sync = systemWallpaperSync, !content.isPlaceholder else { return }
        // 不放动态壁纸：系统壁纸就是桌面上看到的那张，不截图；之前同步过当前画面的，换回用户原来的
        if content.showsSystemWallpaper {
            if let display = displays.first(where: { $0.id == id }) { sync.restore(displays: [display]) }
            return
        }
        snapshotTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.captureSnapshot(for: id, of: content, attempt: attempt)
        }
    }

    private func captureSnapshot(for id: CGDirectDisplayID, of content: any DesktopContent, attempt: Int) async {
        guard systemWallpaperSync != nil, let slot = slots[id], slot.content === content else { return }
        // 窗口被藏起来或挡住时，网页可能停止渲染，截到的是旧画面或空白；过一会儿再试
        guard isShown, slot.window.occlusionState.contains(.visible) else {
            if attempt < 10 { scheduleSnapshot(for: id, content: content, delay: .seconds(10), attempt: attempt + 1) }
            return
        }
        guard let image = await content.snapshot() else {
            log.write("系统壁纸：显示器 \(id) 的内容没有提供截图")
            return
        }
        // 截图期间内容可能已经换了，或者同步被关掉了
        guard let sync = systemWallpaperSync, slots[id]?.content === content,
              let display = displays.first(where: { $0.id == id })
        else { return }
        sync.apply(image, to: display)
    }

    // MARK: - 自检

    /// 事件往往成串到来（热插拔会连发好几次参数变化），等 1 秒安静下来再检查
    private func scheduleProbe(_ reason: String) {
        if !pendingProbeReasons.contains(reason) { pendingProbeReasons.append(reason) }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(runScheduledProbe), object: nil)
        perform(#selector(runScheduledProbe), with: nil, afterDelay: 1.0)
    }

    @objc private func runScheduledProbe() {
        let reasons = pendingProbeReasons
        pendingProbeReasons = []
        probe(reasons: reasons, verbose: true)
    }

    private func probe(reasons: [String], verbose: Bool) {
        let label = reasons.joined(separator: "、")
        guard isShown, !slots.isEmpty else { return }
        // 锁屏或屏幕睡眠时窗口本来就不在屏幕列表里，这时检查只会得到误报
        if Self.isScreenLocked {
            if verbose { log.write("[自检·\(label)] 锁屏中，跳过") }
            return
        }

        let windows = DesktopProbe.desktopWindows()
        var anomalies: [String] = []
        for (id, slot) in slots.sorted(by: { $0.key < $1.key }) where CGDisplayIsAsleep(id) == 0 {
            switch DesktopProbe.status(of: slot.window.windowNumber, in: windows) {
            case .onScreen:
                continue
            case .missing where slot.window.isVisible && !slot.window.occlusionState.contains(.visible):
                // 窗口没被关掉，只是系统暂时把它藏了起来（例如编辑桌面小组件时）。
                // 这时把它排回前面是在和系统对着干，只记录，不处理
                if verbose { log.write("[自检·\(label)] 显示器 \(id) 的窗口被系统暂时隐藏，不处理") }
                continue
            case .missing:
                anomalies.append("显示器 \(id) 的窗口不在屏幕上")
            case .covered(let other):
                anomalies.append("显示器 \(id) 的窗口被 \(other.ownerName)#\(other.number) 盖住")
            }
            slot.window.orderFrontRegardless()
            repairCount += 1
        }

        guard verbose || !anomalies.isEmpty else { return }
        let verdict = anomalies.isEmpty ? "正常" : anomalies.joined(separator: "；") + "，已重新排序"
        log.write("[自检·\(label)] \(verdict)（累计修复 \(repairCount) 次）")
        if verbose {
            let ours = Set(slots.values.map(\.window.windowNumber))
            log.write("  桌面层窗口（前 → 后）：\(DesktopProbe.describe(windows, ours: ours))")
            logOverlays(in: windows)
        }
    }

    /// 记下挡在我们上面的非图标窗口，连同我们窗口此刻的遮挡状态，用来判断它们是否真的挡住了壁纸
    private func logOverlays(in windows: [DesktopProbe.WindowEntry]) {
        for (id, slot) in slots.sorted(by: { $0.key < $1.key }) {
            guard let ours = windows.first(where: { $0.number == slot.window.windowNumber }) else { continue }
            let overlays = DesktopProbe.overlays(above: ours.number, in: windows)
            guard !overlays.isEmpty else { continue }
            let details = overlays.map { other in
                let percent = Int((DesktopProbe.coverage(of: ours.bounds, by: other.bounds) * 100).rounded())
                return "\(other.ownerName)#\(other.number) \(Int(other.bounds.width))×\(Int(other.bounds.height))"
                    + " 覆盖 \(percent)% 不透明度 \(String(format: "%.2f", other.alpha))"
            }
            let visible = slot.window.occlusionState.contains(.visible) ? "可见" : "被完全遮挡"
            log.write("  显示器 \(id) 上方的非图标窗口（本窗口此刻\(visible)）：\(details.joined(separator: "；"))")
        }
    }

    private static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
