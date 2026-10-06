import AppKit
import DesktopHost
import Metal
import QuartzCore
import ShaderCompiler
import WallpaperFormats

/// 挂到桌面窗口上的场景壁纸。
///
/// 场景在后台线程构建（翻译着色器、解码和上传纹理可能要一秒左右），完成前显示黑色。
/// 没有特效的场景是静态的，只在尺寸变化或重新露出时重画一次；有特效的场景按每秒 30 帧持续渲染，
/// 什么时候暂停由 PlaybackGate 决定（被遮挡 1 秒后、手动暂停），暂停期间场景时间也停住，恢复后接着走。
/// 场景里的声音对象由 SceneAudio 播放，默认静音，跟着同一个暂停状态走。
@MainActor
public final class SceneContent: DesktopContent, UserPausable, AudioPlaying, FrameRateAdjustable {
    /// 场景怎么放到屏幕上（壁纸设置里的"显示方式""画面位置"）
    public struct Display: Sendable, Equatable {
        /// 完整显示：画布比例和屏幕不同时整张放进屏幕、两边留黑（只对写了宽高的正交场景）
        public var fitsWhole: Bool
        /// 铺满时看哪一部分：被裁的方向上 0 是最左 / 最上，1 是最右 / 最下
        public var position: Float

        public init(fitsWhole: Bool = false, position: Float = 0.5) {
            self.fitsWhole = fitsWhole
            self.position = position
        }
    }

    public var view: NSView { container }
    public var isPausedByUser: Bool { gate.isPausedByUser }

    private let sceneView = SceneView()
    private lazy var container = SceneContainerView(sceneView: sceneView)
    private let display: Display
    private let label: String
    private let log: EventLog
    private var renderer: SceneRenderer?
    private var buildTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var audio: SceneAudio?
    /// 这个场景正占用着系统音频采集（场景用到音频律动、且正在播放时才占用）
    private var holdsSystemAudio = false
    /// 采集失败的原因只记一次日志
    private var reportedAudioProblem = false
    /// 新的内容画出第一帧之前，控制器靠它把旧画面留在屏幕上
    private var readyHandler: (@MainActor () -> Void)?
    /// 桌面这块现在看得见吗（被全屏窗口挡住时鼠标事件不用处理）
    private var isVisible = true
    private var isAudioEnabled = false
    /// 壁纸设置里的音量（重建场景时交给新的 SceneAudio）
    private var volume: Float = 1
    /// 帧率上限（0 表示不限制）
    private var maximumFrameRate = 30
    /// 自动帧率（见 `AdaptiveFrameRate`）：按画面变得多快在上限之下降帧
    private var adaptsFrameRate = true
    private var governor: FrameRateGovernor?
    private var probeState = ProbeState.idle
    /// 最近一次鼠标在这块屏幕上挪动时的场景时间：跟着鼠标动的场景之后 1 秒内按上限画
    private var lastPointerMove = -Double.infinity
    /// 显示链路现在用的帧率
    private var appliedFrameRate: Int?

    /// 量画面变化的两帧：先取一帧，隔 0.1 秒以上再取一帧
    private enum ProbeState {
        case idle
        case capturingFirst(since: Double)
        case haveFirst(LumaFrame, time: Double)
        case measuring(since: Double)
    }

    /// 显示链路现在用的帧率、量过几次（测试用）
    var frameRateInUse: Int? { appliedFrameRate }
    /// 画面没变、没画的帧数（测试用）
    private(set) var skippedFrames = 0
    var motionSamples: Int { governor?.history.count ?? 0 }
    /// 全局鼠标监听：桌面窗口收不到点击，用它拿点击和拖动
    private var mouseMonitor: GlobalMouseMonitor?
    private var lastPointerDown: CGPoint?
    /// 静止场景的悬停重画已经排上了 / 上次画的时刻（见 `scheduleHoverRedraw`）
    private var hoverRedrawPending = false
    private var lastHoverRedraw: CFTimeInterval = 0
    /// 重建场景要用的入参
    private let projectFolder: URL
    private let assets: URL?
    private let userProperties: Data?
    private let hiddenElements: Set<String>
    private let onFailure: @MainActor (String) -> Void
    /// 当前场景是按多大的屏幕尺寸建的；显示尺寸变了要重建
    private var builtTargetSize: CGSize?

    /// 场景时间：只在播放时前进
    private var sceneTime: Double = 0
    private var lastTick: CFTimeInterval?

    private lazy var gate = PlaybackGate { [weak self] playing, reason in
        self?.playbackDidChange(playing, reason: reason)
    }

    /// - Parameters:
    ///   - assets: WE 自带素材目录；nil 时只用场景包里的文件，多数场景会缺自带的着色器和贴图
    ///   - onFailure: 场景读不了时调用，参数是原因
    ///   - targetSize: 显示器的像素尺寸，用来限制特效缓冲的大小
    ///   - userProperties: 用户属性的当前值（名字 → 值的 JSON 对象），代入场景里绑定到属性的字段
    ///   - hiddenElements: 用户在设置里关掉的粒子、文字、特效（见 `SceneElements`）
    public init(
        projectFolder: URL, assets: URL?, targetSize: CGSize?, userProperties: Data? = nil,
        hiddenElements: Set<String> = [], display: Display = Display(), label: String,
        log: EventLog, onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.display = display
        self.label = label
        self.log = log
        self.projectFolder = projectFolder
        self.assets = assets
        self.userProperties = userProperties
        self.hiddenElements = hiddenElements
        self.onFailure = onFailure
        builtTargetSize = targetSize
        sceneView.onFirstFrame = { [weak self] in self?.firstFrameDidDraw() }
        log.write("\(label) 场景：载入 \(projectFolder.path)，自带素材 \(assets?.path ?? "未设置")")
        startBuild()
    }

    /// 第一帧已经画到屏幕上（换壁纸时控制器靠它决定什么时候撤掉旧画面）
    public func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if sceneView.hasDrawnFrame { handler(); return }
        readyHandler = handler
    }

    private func firstFrameDidDraw() {
        readyHandler?()
        readyHandler = nil
    }

    /// 构建场景。显示器像素尺寸变了会用它重新构建（贴图、特效缓冲都是按屏幕尺寸定的，
    /// 尺寸变了不重建，文字和特效就会被重新采样，糊成一片）
    private func startBuild() {
        let package = projectFolder.appendingPathComponent("scene.pkg")
        buildTask = Task { [weak self] in
            guard let self else { return }
            let displaySize = builtTargetSize
            let assets = self.assets
            let userProperties = self.userProperties
            let hiddenElements = self.hiddenElements
            let display = self.display
            let started = Date()
            let result = await Task.detached { () -> Result<(SceneRenderer, MotionProbe?, Float?), any Error> in
                let result = Result {
                    guard let device = MTLCreateSystemDefaultDevice() else { throw FormatError("没有可用的 Metal 设备") }
                    let scenePackage = try ScenePackage(contentsOf: package)
                    // 显示方式：完整显示时按缩小后的那块构建；铺满时把"画面位置"放到被裁的那个方向上
                    let canvas = SceneRenderer.fixedCanvasSize(of: scenePackage)
                    let screen = displaySize.map { SIMD2(Float($0.width), Float($0.height)) }
                    var target = screen
                    var focus = SIMD2<Float>(0.5, 0.5)
                    if let canvas, let screen, screen.x > 0, screen.y > 0 {
                        let wider = canvas.x / canvas.y > screen.x / screen.y
                        if display.fitsWhole {
                            target = wider
                                ? SIMD2(screen.x, (screen.x * canvas.y / canvas.x).rounded())
                                : SIMD2((screen.y * canvas.x / canvas.y).rounded(), screen.y)
                        } else if wider {
                            focus.x = display.position
                        } else {
                            focus.y = display.position
                        }
                    }
                    let renderer = try SceneRenderer(
                        device: device, package: scenePackage, assets: assets, targetSize: target,
                        shaderCache: AppFolder.isActive ? AppFolder.shaderCache : nil, userProperties: userProperties,
                        hiddenElements: hiddenElements, focus: focus)
                    // 自动帧率量画面用的缩图着色器（运行时编译，放在后台做）
                    let aspect = display.fitsWhole ? canvas.map { $0.x / $0.y } : nil
                    return (renderer, renderer.needsAnimation ? try? MotionProbe(device: device) : nil, aspect)
                }
                // 构建时解码、解压贴图用过的大块内存已经释放，但分配器会先留着；壁纸常驻后台，
                // 这里还给系统（Lucy 场景约 60 MB）
                malloc_zone_pressure_relief(nil, 0)
                return result
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let (renderer, probe, fitAspect)):
                self.container.contentAspect = fitAspect.map { CGFloat($0) }
                self.install(renderer, probe: probe, seconds: Date().timeIntervalSince(started))
            case .failure(let error):
                self.log.write("\(self.label) 场景：无法载入 \(error.localizedDescription)")
                self.onFailure(error.localizedDescription)
            }
        }
    }

    private func install(_ renderer: SceneRenderer, probe: MotionProbe?, seconds: Double) {
        self.renderer = renderer
        // 视频贴图在后台解码，渲染只取解好的帧，主线程不等解码器
        renderer.waitsForVideoFrames = false
        sceneView.renderer = renderer
        // 自动帧率：跟着音乐律动的不降（节奏要跟上）。视频贴图照样按画面动得多快定：
        // 动得慢时隔几帧显示一张看不出来，和别的画面一样
        if let probe, !renderer.usesAudio {
            sceneView.motionProbe = probe
            governor = FrameRateGovernor(startingAt: sceneTime)
        } else {
            sceneView.motionProbe = nil
            governor = nil
        }
        probeState = .idle
        appliedFrameRate = nil
        // 系统音频频谱：只有跟着音乐律动的场景才要（第一次用会弹一次授权；拿不到授权时按静音处理，
        // 界面照常）。采集只在播放时开着，暂停、换壁纸就停
        if renderer.usesAudio { renderer.audioSpectrum = SystemAudioSpectrum.shared }
        let skipped = renderer.unsupported.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        log.write("\(label) 场景：画了 \(renderer.drawnLayerCount) 层、\(renderer.renderedEffectCount) 个特效，"
            + "构建用时 \(String(format: "%.2f", seconds)) 秒"
            + (skipped.isEmpty ? "" : "；暂不支持：\(skipped.joined(separator: "、"))"))
        // 排查"没有铺满屏幕"这类问题要用到的尺寸关系：窗口点尺寸、缩放、drawable 像素尺寸、画布尺寸
        //（铺满裁切就是拿画布按 max(目标/画布) 缩放到目标上；画布留得比内容大时还有"有内容的框"，见 SceneRenderer.framing）。每次构建记一行
        let pixels = sceneView.pixelSize
        let scale = sceneView.window?.backingScaleFactor ?? 0
        let ratio = pixels.width > 0 && pixels.height > 0
            ? renderer.canvasScale(target: SIMD2(Float(pixels.width), Float(pixels.height)))
            : 0
        let windowSize = "\(Int(sceneView.bounds.width))×\(Int(sceneView.bounds.height)) 点 @\(scale)x"
        let drawableSize = "\(pixels.width)×\(pixels.height) 像素"
        var canvas = "\(Int(renderer.canvasSize.x))×\(Int(renderer.canvasSize.y))"
        if let fill = renderer.fillBox {
            canvas += "（有内容的框 \(Int(fill.min.x)),\(Int(fill.min.y))–\(Int(fill.max.x)),\(Int(fill.max.y))）"
        }
        log.write("\(label) 场景：尺寸——窗口 \(windowSize)，drawable \(drawableSize)，画布 \(canvas)，"
            + (ratio > 0 ? String(format: "铺满裁切比例 %.3f", ratio) : "还没进窗口"))
        renderer.problems.prefix(10).forEach { log.write("\(label) 场景：\($0)") }

        // 按新尺寸重建时旧的声音还在放
        audio?.stop()
        audio = nil
        if !renderer.sounds.isEmpty {
            let audio = SceneAudio(sounds: renderer.sounds)
            audio.problems.forEach { log.write("\(label) 场景：\($0)") }
            if !audio.isEmpty {
                audio.setMasterVolume(volume)
                audio.setEnabled(isAudioEnabled)
                self.audio = audio
                let names = renderer.sounds.map { "\($0.name)（\($0.content.playbackMode)）" }.joined(separator: "、")
                log.write("\(label) 场景：声音对象 \(renderer.sounds.count) 个：\(names)；\(isAudioEnabled ? "播放" : "静音")")
            }
        }
        // 按新尺寸重建时旧的显示链路还在跑：不停掉的话两条链路各画一遍，每帧画两次
        displayLink?.invalidate()
        displayLink = nil
        if renderer.needsAnimation {
            let link = sceneView.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            applyFrameRate()
            if renderer.redrawsOnlyWhenStateChanges {
                log.write("\(label) 场景：只有脚本 / 文字会改画面，状态变了才重画")
            }
        }
        if renderer.needsPointerEvents { startMouseMonitor() }
        // 静态场景也可能有声音，同样要跟着播放状态走
        if renderer.needsAnimation || audio != nil {
            gate.start(reason: "载入")
            // 场景在后台构建期间，窗口的可见性可能已经通知过，暂停控制器早就进入了播放状态，
            // 不会再回调一次；所以定时器建好后直接按控制器当前的状态设置
            displayLink?.isPaused = !gate.isPlaying
            audio?.setPlaying(gate.isPlaying)
        }
        updateSystemAudio()
    }

    /// 按"场景用不用音频律动、在不在播放"占用或归还系统音频采集
    private func updateSystemAudio() {
        let wanted = renderer?.usesAudio == true && gate.isPlaying
        guard wanted != holdsSystemAudio else { return }
        holdsSystemAudio = wanted
        guard wanted else {
            SystemAudioSpectrum.shared.release()
            return
        }
        if !SystemAudioSpectrum.shared.acquire(), !reportedAudioProblem {
            reportedAudioProblem = true
            log.write("\(label) 场景：系统音频采集不可用——\(SystemAudioSpectrum.shared.problem ?? "未知原因")")
        }
    }

    public func setAudioEnabled(_ enabled: Bool) {
        guard enabled != isAudioEnabled else { return }
        isAudioEnabled = enabled
        audio?.setEnabled(enabled)
        if audio != nil { log.write("\(label) 场景：声音\(enabled ? "播放" : "静音")") }
    }

    public func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        audio?.setMasterVolume(self.volume)
    }

    /// 帧率上限；0 表示不限制（交给系统按显示器刷新率跑）
    public func setMaximumFrameRate(_ fps: Int) {
        maximumFrameRate = max(0, fps)
        applyFrameRate()
    }

    public func setAdaptiveFrameRate(_ enabled: Bool) {
        guard enabled != adaptsFrameRate else { return }
        adaptsFrameRate = enabled
        log.write("\(label) 场景：自动帧率\(enabled ? "开" : "关")")
        applyFrameRate()
    }

    /// 显示链路该用的帧率：上限之下，自动帧率量出来的那一档；跟着鼠标动的场景在鼠标挪动时按上限
    private func applyFrameRate() {
        let cap = maximumFrameRate
        let pointerActive = renderer?.followsPointer == true && sceneTime - lastPointerMove < 1
        let rate = adaptsFrameRate && !pointerActive ? governor?.rate(cap: cap) ?? cap : cap
        guard rate != appliedFrameRate, let displayLink else { return }
        appliedFrameRate = rate
        displayLink.preferredFrameRateRange = Self.frameRateRange(rate)
    }

    /// 自动帧率的测量：到时间了先取一帧，隔 0.1 秒以上再取一帧，在后台比两帧，结果交给 `governor`
    private func driveMotionProbe() {
        guard adaptsFrameRate, var governor else { return }
        let now = sceneTime
        // 鼠标在带动画面时量出来的不算数
        let pointerActive = renderer?.followsPointer == true && now - lastPointerMove < 1
        switch probeState {
        case .idle:
            guard governor.isDue(at: now), !pointerActive else { return }
            probeState = .capturingFirst(since: now)
            sceneView.captureNextFrame { [weak self] frame in
                guard let self, case .capturingFirst = self.probeState else { return }
                self.probeState = .haveFirst(frame, time: now)
            }
        case .haveFirst(let first, let time):
            // 中途暂停过、鼠标动了：这次不算，过一会儿再量
            if pointerActive || now - time > 0.5 {
                probeState = .idle
                governor.postpone(from: now)
                self.governor = governor
                return
            }
            guard now - time >= 0.1 else { return }
            probeState = .measuring(since: now)
            let scale = Double(sceneView.window?.backingScaleFactor ?? 2)
            sceneView.captureNextFrame { [weak self] second in
                Task.detached(priority: .utility) {
                    let result = MotionEstimator.measure(from: first, to: second, interval: now - time)
                    await self?.motionMeasured(result, backingScale: scale)
                }
            }
        case .capturingFirst(let since), .measuring(let since):
            // 取帧或测量一直没回来（画面没画出来之类）：放弃这次，过一会儿再量，免得自动帧率从此卡住
            guard now - since > 2 else { return }
            probeState = .idle
            governor.postpone(from: now)
            self.governor = governor
        }
    }

    private func motionMeasured(_ result: MotionEstimator.Result?, backingScale: Double) {
        guard case .measuring = probeState, var governor else { return }
        probeState = .idle
        guard let result else {
            governor.postpone(from: sceneTime)
            self.governor = governor
            return
        }
        let before = governor.rate(cap: maximumFrameRate)
        governor.record(AdaptiveFrameRate.frameRate(for: result, backingScale: backingScale, cap: 0), at: sceneTime)
        self.governor = governor
        let after = governor.rate(cap: maximumFrameRate)
        if after != before {
            log.write(String(
                format: "%@ 场景：自动帧率 %@ → %@（画面最快约 %.0f 点/秒、明暗 %.0f 级/秒）", label,
                Self.rateTitle(before), Self.rateTitle(after), result.speed / backingScale, result.fadeRate))
        }
        applyFrameRate()
    }

    private static func rateTitle(_ fps: Int) -> String { fps == 0 ? "不限" : "\(fps) 帧" }

    private static func frameRateRange(_ fps: Int) -> CAFrameRateRange {
        guard fps > 0 else { return CAFrameRateRange(minimum: 0, maximum: 0, preferred: 0) }
        return CAFrameRateRange(minimum: Float(min(15, fps)), maximum: Float(fps), preferred: Float(fps))
    }

    @objc private func tick(_ link: CADisplayLink) {
        advance(to: link.timestamp)
    }

    /// 走到时刻 `now`（秒）画一帧（显示链路每帧调一次；测试里直接调）
    func advance(to now: CFTimeInterval) {
        // 时间只能前进：显示链路重建（换屏幕、接外接屏）时 timestamp 可能倒退，
        // 一倒退粒子系统就会从头预模拟，画面上就是"雪花突然闪一下"
        if let lastTick { sceneTime += max(0, min(now - lastTick, 0.25)) }
        lastTick = now
        sceneView.time = Float(sceneTime.truncatingRemainder(dividingBy: 3600))
        updatePointer()
        driveMotionProbe()
        applyFrameRate()
        // 只有脚本 / 文字会改画面的场景：先跑脚本，图层状态和上次画的一样就不画（不编码、不提交，系统也不用重新合成）
        if let renderer, renderer.redrawsOnlyWhenStateChanges, sceneView.hasDrawnFrame,
           !renderer.prepareFrame(at: sceneView.time) {
            skippedFrames += 1
            return
        }
        sceneView.redraw()
    }

    /// 鼠标相对这块屏幕的位置，0–1，原点在左上角。鼠标在别的屏幕上时保持最后的位置
    private func updatePointer() {
        guard let frame = pointerFrame else { return }
        let location = NSEvent.mouseLocation
        guard frame.contains(location) else { return }
        let pointer = SIMD2(
            Float((location.x - frame.minX) / frame.width),
            Float(1 - (location.y - frame.minY) / frame.height))
        if pointer != sceneView.pointer { lastPointerMove = sceneTime }
        sceneView.pointer = pointer
    }

    /// 场景画面在屏幕上的位置（屏幕坐标）：平常就是整块屏幕，完整显示时是中间那块（两边是黑边）
    private var pointerFrame: CGRect? {
        guard let window = sceneView.window else { return nil }
        return window.convertToScreen(sceneView.convert(sceneView.bounds, to: nil))
    }

    /// 全局鼠标监听：点按本来要透给桌面，所以窗口收不到事件；这里旁听按下 / 抬起 / 拖动，
    /// 换算成这块屏幕上的位置后交给渲染器（脚本的 cursorDown / cursorUp / cursorClick / cursorMove）
    private func startMouseMonitor() {
        guard mouseMonitor == nil else { return }
        let monitor = GlobalMouseMonitor { [weak self] event in
            self?.handleMouse(event)
        }
        monitor.start()
        mouseMonitor = monitor
    }

    private func handleMouse(_ event: GlobalMouseEvent) {
        // 桌面被挡住、或手动暂停时不处理：静止的场景每来一个事件就要重画一帧
        guard isVisible, !gate.isPausedByUser else { return }
        guard let frame = pointerFrame, renderer != nil else { return }
        guard frame.width > 0, frame.height > 0 else { return }
        let position = SIMD2<Float>(
            Float((event.location.x - frame.minX) / frame.width),
            Float(1 - (event.location.y - frame.minY) / frame.height))
        switch event.kind {
        case .down:
            lastPointerDown = event.location
            sceneView.pointerEvents.append(.init(kind: .down, position: position))
        case .up:
            sceneView.pointerEvents.append(.init(kind: .up, position: position))
            if GlobalMouseMonitor.isClick(event, from: lastPointerDown) {
                sceneView.pointerEvents.append(.init(kind: .click, position: position))
            }
            lastPointerDown = nil
        case .dragged:
            sceneView.pointerEvents.append(.init(kind: .dragged, position: position))
            sceneView.pointer = position
        case .moved:
            // 移动只更新指针位置，悬停在渲染时统一处理；静止的场景靠重绘来响应。鼠标一秒能来上百个移动事件
            //（在别的 App 窗口上移动也算），每个都整屏重画一次太费电：按帧率上限合并
            sceneView.pointer = position
            if displayLink?.isPaused ?? true { scheduleHoverRedraw() }
            return
        }
        // 事件是异步来的，处理完立刻画一帧（静止场景也能及时响应点击）
        if displayLink?.isPaused ?? true { sceneView.redraw() }
    }

    /// 静止场景的悬停重画：距上次不到一帧（按帧率上限，不限制时按 60）就排到那时候，期间再来的移动合并进去
    private func scheduleHoverRedraw() {
        guard !hoverRedrawPending else { return }
        let interval = 1 / Double(maximumFrameRate > 0 ? maximumFrameRate : 60)
        let wait = max(0, lastHoverRedraw + interval - CACurrentMediaTime())
        hoverRedrawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverRedrawPending = false
                self.lastHoverRedraw = CACurrentMediaTime()
                if self.displayLink?.isPaused ?? true { self.sceneView.redraw() }
            }
        }
    }

    private func playbackDidChange(_ playing: Bool, reason: String) {
        lastTick = nil
        displayLink?.isPaused = !playing
        audio?.setPlaying(playing)
        updateSystemAudio()
        log.write("\(label) 场景：\(playing ? "播放" : "暂停")（\(reason)）")
    }

    public func setPausedByUser(_ paused: Bool) {
        gate.setPausedByUser(paused)
    }

    public func displayDidChange(_ display: DisplaySnapshot) {
        // 显示器的像素尺寸变了（改缩放、换分辨率）时按新尺寸重建：特效缓冲和文字贴图都是按它定的
        if let built = builtTargetSize, built != display.pixelSize, renderer != nil {
            log.write("\(label) 场景：显示尺寸 \(Int(built.width))×\(Int(built.height)) → "
                + "\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height))，按新尺寸重建")
            builtTargetSize = display.pixelSize
            buildTask?.cancel()
            governor = nil
            probeState = .idle
            renderer = nil
            sceneView.renderer = nil
            updateSystemAudio()
            startBuild()
            return
        }
        sceneView.redraw()
    }

    public func visibilityDidChange(isVisible: Bool) {
        self.isVisible = isVisible
        gate.setVisible(isVisible)
        if isVisible { sceneView.redraw() }
    }

    public func snapshot() async -> CGImage? {
        guard let renderer else { return nil }
        let size = sceneView.pixelSize
        guard size.width > 0, size.height > 0,
              let image = try? renderer.renderImage(
                width: size.width, height: size.height, time: sceneView.time, pointer: sceneView.pointer)
        else { return nil }
        // 完整显示：系统壁纸也要带上两边的黑边（系统按铺满放，只给中间那块会被放大裁掉）
        let scale = sceneView.window?.backingScaleFactor ?? 2
        let whole = container.bounds.size
        let frame = sceneView.frame
        guard frame.size != whole, whole.width > 0, whole.height > 0,
              let context = CGContext(
                data: nil, width: Int(whole.width * scale), height: Int(whole.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.draw(image, in: CGRect(
            x: frame.minX * scale, y: frame.minY * scale, width: CGFloat(size.width), height: CGFloat(size.height)))
        return context.makeImage() ?? image
    }

    public func tearDown() {
        buildTask?.cancel()
        governor = nil
        probeState = .idle
        gate.invalidate()
        displayLink?.invalidate()
        displayLink = nil
        audio?.stop()
        audio = nil
        mouseMonitor?.stop()
        mouseMonitor = nil
        sceneView.pointerEvents = []
        sceneView.renderer = nil
        renderer = nil
        updateSystemAudio()
    }
}

/// 场景视图外面套的一层黑底：完整显示时场景视图按画布比例缩在中间，两边是黑边；平常场景视图铺满它
final class SceneContainerView: NSView {
    let sceneView: SceneView
    /// 完整显示时的画布宽高比；nil 表示铺满
    var contentAspect: CGFloat? {
        didSet { if contentAspect != oldValue { placeScene() } }
    }

    init(sceneView: SceneView) {
        self.sceneView = sceneView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(sceneView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        placeScene()
    }

    /// 尺寸一变就摆（不在窗口里时没有 layout 这一步，测试和刚建好还没挂上窗口时都是这样）
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeScene()
    }

    private func placeScene() {
        let frame = Self.contentFrame(in: bounds, aspect: contentAspect)
        if sceneView.frame != frame { sceneView.frame = frame }
    }

    /// 按宽高比放进 bounds 正中（取整到点，免得边上有半个像素的缝）；没给比例就是整块
    static func contentFrame(in bounds: CGRect, aspect: CGFloat?) -> CGRect {
        guard let aspect, aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        if aspect > bounds.width / bounds.height {
            let height = (bounds.width / aspect).rounded()
            return CGRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
        }
        let width = (bounds.height * aspect).rounded()
        return CGRect(x: ((bounds.width - width) / 2).rounded(), y: 0, width: width, height: bounds.height)
    }
}

/// 背后是一个 CAMetalLayer 的视图，按需重画
final class SceneView: NSView {
    var renderer: SceneRenderer? {
        didSet {
            metalLayer.device = renderer?.device
            redraw()
        }
    }

    /// 场景时间（秒），驱动特效动画
    var time: Float = 0
    /// 鼠标在屏幕上的位置，0–1，原点在左上角
    var pointer = SIMD2<Float>(0.5, 0.5)
    /// 还没送给渲染器的鼠标事件（点击、拖动）
    var pointerEvents: [SceneRenderer.PointerEvent] = []
    /// 已经画出过至少一帧（换壁纸时用它判断新画面什么时候能接上）
    private(set) var hasDrawnFrame = false
    /// 第一帧画出来时的回调
    var onFirstFrame: (() -> Void)?
    /// 自动帧率量画面变化用：下一帧画完后缩一张亮度图交出去
    var motionProbe: MotionProbe?
    private var pendingCapture: (@MainActor @Sendable (LumaFrame) -> Void)?
    private var retryScheduled = false
    private var retryAttempts = 0

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var pixelSize: (width: Int, height: Int) {
        let scale = window?.backingScaleFactor ?? 2
        return (Int(bounds.width * scale), Int(bounds.height * scale))
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = SceneRenderer.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = NSColor.black.cgColor
        // 画面整块覆盖、下面是黑底：按预乘 alpha 叠到黑色上的结果就是原来的 RGB，标成不透明画出来一模一样，
        // 系统合成时却不用每帧再把整屏和下面混合一遍
        layer.isOpaque = true
        // 图层混合模式要在着色器里读帧缓冲
        layer.framebufferOnly = false
        // 按 30 帧画，两张轮换就够；默认的三张每张都是整屏大小（3024×1964 约 24 MB）
        layer.maximumDrawableCount = 2
        return layer
    }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    func redraw() {
        let size = pixelSize
        guard let renderer, size.width > 0, size.height > 0 else { return }
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        let drawableSize = CGSize(width: size.width, height: size.height)
        if metalLayer.drawableSize != drawableSize { metalLayer.drawableSize = drawableSize }
        guard let drawable = metalLayer.nextDrawable(), let commands = renderer.makeCommandBuffer() else {
            // 图层刚进窗口时可能还拿不到 drawable。静止的场景没有显示链路，不重试的话第一帧
            // 永远画不出来（换壁纸时就会一直停在旧画面上，直到控制器超时）
            retryFirstFrame()
            return
        }
        let events = pointerEvents
        pointerEvents = []
        renderer.encode(
            into: drawable.texture, commandBuffer: commands, time: time, pointer: pointer, pointerEvents: events)
        if let capture = pendingCapture, let motionProbe {
            pendingCapture = nil
            motionProbe.capture(drawable.texture, into: commands) { frame in
                Task { @MainActor in capture(frame) }
            }
        }
        commands.present(drawable)
        commands.commit()
        if !hasDrawnFrame {
            hasDrawnFrame = true
            onFirstFrame?()
        }
    }

    /// 下一帧画完后把缩小的亮度图交给 `handler`（在主线程上）
    func captureNextFrame(_ handler: @escaping @MainActor @Sendable (LumaFrame) -> Void) {
        pendingCapture = handler
    }

    /// 还没画过第一帧就再试几次（每次隔 50 毫秒，最多 2 秒）
    private func retryFirstFrame() {
        guard !hasDrawnFrame, !retryScheduled, retryAttempts < 40 else { return }
        retryScheduled = true
        retryAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.retryScheduled = false
            self?.redraw()
        }
    }
}
