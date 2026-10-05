import AppKit
import SwiftUI
import DesktopHost
import UniformTypeIdentifiers
import VideoWallpaper
import WallpaperLibrary
import SceneRenderer
import WebWallpaper

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = EventLog()
    private let assignments = AssignmentStore()
    private var controller: WallpaperController?
    private var statusItem: NSStatusItem?
    private var windowGeneration = 0

    private var isGloballyPaused = false
    private var pausedDisplays: Set<CGDirectDisplayID> = []
    /// 运行中播放失败的视频和原因。重新选择这个文件时清除
    private var failedVideos: [URL: String] = [:]
    /// 运行中载入失败的场景（按项目文件夹）和原因。重新选择这个项目或换素材目录时清除
    private var failedScenes: [String: String] = [:]
    /// 载入场景前记一笔、平稳跑过一阵再擦掉：壁坞在这期间崩了的话，下次启动先不载入那张（见 CrashGuard）
    private lazy var crashGuard = CrashGuard(file: AppFolder.data.appendingPathComponent("loading-scenes.json"))
    /// 场景载入后多久算"平稳"（构建加上头几秒的渲染；坏文件引起的崩溃几乎都在这段时间里）
    private static let crashGuardSeconds: TimeInterval = 60

    /// 读过的项目。project.json 放在"文稿""下载"或外置盘里时，第一次读取会一直等到用户回应系统的
    /// 隐私授权弹窗，所以一律在后台读，读完再换上真正的内容，期间菜单栏保持可用
    private var projects: [String: Result<WallpaperProject, any Error>] = [:]
    /// 正在后台读取的项目，以及读完后要刷新的显示器
    private var projectReloads: [String: Set<CGDirectDisplayID>] = [:]
    /// 用户在设置面板里改过的属性值
    private let propertyStore = UserPropertyStore()
    /// 用户在设置面板里关掉的场景内容（粒子、文字、特效）
    private let hiddenElementStore = HiddenElementStore()
    /// 每个壁纸自己的播放选项：静音、音量、显示方式
    private let optionsStore = WallpaperOptionsStore()
    /// 场景属性改动后等用户停手再重建（拖滑块时不要每一步都重建）
    private var pendingSceneRebuilds: [String: Task<Void, Never>] = [:]
    private let libraryFolders = LibraryFolderStore()
    private let playlistStore = PlaylistStore()
    private var playlistTimer: Timer?
    /// 每 24 小时检查一次更新（见 `checkForUpdates`）
    private var updateTimer: Timer?
    /// 这次运行已经提示过的新版本（"以后再说"之后这次运行不再提示）
    private var announcedUpdateVersion: String?
    private var lastRotation = Date()
    private var playlistRandom = SystemRandomNumberGenerator()
    private let performanceStore = PerformanceStore()
    /// 电源、低电量模式、机器温度一变就重新决定帧率和要不要暂停
    private lazy var powerMonitor = PowerMonitor { [weak self] in self?.applyPerformance() }
    /// 上次用的帧率上限和省电条件（有变化才写日志）
    private var lastEffectiveFrameRate: Int?
    private var lastPowerSummary: String?
    /// 用电池且设置成"暂停壁纸"时为 true
    private var isPausedByPower = false
    private var libraryWindow: LibraryWindowController?
    /// 已经在监听关闭的壁坞自己的窗口（关完了就退回菜单栏应用）
    private var observedAppWindows: Set<ObjectIdentifier> = []
    private var welcomeWindow: WelcomeWindowController?
    /// 欢迎页上的状态（选完素材、加完文件夹马上刷新）
    private var welcomeModel: WelcomeModel?
    /// Steam 创意工坊（嵌在壁纸库里；启动时就建好，好在后台用存着的会话连上 Steam）
    private lazy var workshop = WorkshopModel(
        libraryFolders: { [weak self] in self?.libraryFolders.folders ?? [] },
        onDownloaded: { [weak self] folder in self?.workshopDidDownload(into: folder) },
        onUnsubscribed: { [weak self] folders in self?.offerToTrashUnsubscribed(folders) },
        log: { [weak self] text in self?.log.write(text) })
    private lazy var permissionPrimer = PermissionPrimer(log: log)
    private static let welcomeShownKey = "didShowWelcome"

    /// 项目缓存的键。打开面板给的 URL 和从设置里还原的 URL 可能差一个结尾斜杠，统一成标准路径
    private static func key(_ folder: URL) -> String {
        folder.standardizedFileURL.path
    }

    private static let levelDefaultsKey = "desktopLevel"
    private static let webNetworkDefaultsKey = "allowWebNetwork"
    private static let syncDefaultsKey = "syncSystemWallpaper"
    private static let audioDefaultsKey = "playWallpaperAudio"
    private static let assetsDefaultsKey = "weAssetsDirectory"

    /// WE 自带素材目录（Windows 上 wallpaper_engine/assets 的副本）。没设置过时用统一文件夹里的 Assets（存在的话）
    private var assetsDirectory: URL? {
        get {
            if let path = AppFolder.settings.string(forKey: Self.assetsDefaultsKey) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let fallback = AppFolder.assets
            return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
        }
        set { AppFolder.settings.set(newValue?.path, forKey: Self.assetsDefaultsKey) }
    }

    /// 网页壁纸能否联网。默认允许：不少网页壁纸要联网取天气、字体或脚本库
    private var allowWebNetwork: Bool {
        get { AppFolder.settings.object(forKey: Self.webNetworkDefaultsKey) as? Bool ?? true }
        set { AppFolder.settings.set(newValue, forKey: Self.webNetworkDefaultsKey) }
    }

    /// 是否播放壁纸里的声音（视频的音轨、网页的声音、场景里的声音对象）。默认关闭：桌面背景突然出声会吓人一跳
    private var playAudio: Bool {
        get { AppFolder.settings.object(forKey: Self.audioDefaultsKey) as? Bool ?? false }
        set { AppFolder.settings.set(newValue, forKey: Self.audioDefaultsKey) }
    }

    /// 是否把系统壁纸同步成当前画面。默认开启：否则编辑桌面小组件等时候会露出原来的系统壁纸
    private var syncSystemWallpaper: Bool {
        get { AppFolder.settings.object(forKey: Self.syncDefaultsKey) as? Bool ?? true }
        set { AppFolder.settings.set(newValue, forKey: Self.syncDefaultsKey) }
    }

    private lazy var systemWallpaper = SystemWallpaperSync(
        store: WorkspaceDesktopPictures(), directory: SystemWallpaperSync.defaultDirectory,
        formerDirectories: SystemWallpaperSync.formerDirectories, defaults: AppFolder.settings, log: log)

    private static let lockScreenDefaultsKey = "lockScreenWallpaper"

    /// 锁屏（以及调度中心、编辑桌面小组件这些系统露出系统壁纸的时候）用哪张图。
    /// nil = 跟随动态壁纸当前的画面（默认）
    private var lockScreenWallpaperPath: String? {
        get { AppFolder.settings.string(forKey: Self.lockScreenDefaultsKey) }
        set {
            AppFolder.settings.set(newValue, forKey: Self.lockScreenDefaultsKey)
            applyLockScreenWallpaper()
        }
    }

    /// 把选好的图片交给系统壁纸同步（只给路径，设置时才按屏幕尺寸读）；读不到就当没设过（跟随当前画面）
    private func applyLockScreenWallpaper() {
        guard let path = lockScreenWallpaperPath else {
            systemWallpaper.lockScreenImageURL = nil
            controller?.resyncSystemWallpaper()
            return
        }
        if !FileManager.default.isReadableFile(atPath: path) {
            log.write("锁屏壁纸：读不到 \(path)，先按跟随当前画面处理")
        }
        systemWallpaper.lockScreenImageURL = URL(fileURLWithPath: path)
        controller?.resyncSystemWallpaper()
    }

    /// 收到 SIGTERM（kill、部分系统关机流程）时走正常退出，保证原来的系统壁纸会被恢复
    private var terminationSignal: (any DispatchSourceSignal)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        libraryFolders.onChange = { [log] change in log.write("壁纸库：文件夹\(change)") }
        if let reason = LoginItem.restore() { log.write("开机自动启动：重新登记失败（\(reason)）") }
        warnIfNotInstalled()
        for key in crashGuard.suspects {
            failedScenes[key] = String(localized: "上次载入这张壁纸时壁坞意外退出了，这次先不载入。在壁纸库里重新选它可以再试一次")
            log.write("上次载入场景时意外退出，这次跳过：\(key)")
        }
        let savedLevel = AppFolder.settings.string(forKey: Self.levelDefaultsKey)
            .flatMap(DesktopLevel.init(rawValue:))
        let controller = WallpaperController(level: savedLevel ?? .desktop, log: log) { [unowned self] display in
            makeContent(for: display)
        }
        self.controller = controller
        // 壁纸库开着的时候接上 / 拔掉显示器，"设到"和右键菜单里的显示器列表马上跟着变
        controller.onDisplaysChanged = { [weak self] in self?.refreshLibraryDisplays() }
        if syncSystemWallpaper { controller.systemWallpaperSync = systemWallpaper }
        applyLockScreenWallpaper()
        setUpStatusItem()
        MainMenu.install(.init(
            target: self, openLibrary: #selector(menuOpenLibrary), addLibraryFolder: #selector(menuAddLibraryFolder),
            showLocal: #selector(menuShowLocal), showWorkshop: #selector(openWorkshop),
            showSubscriptions: #selector(menuShowSubscriptions), signIn: #selector(menuSignIn),
            showHelp: #selector(showWelcomeAgain), openLogs: #selector(menuOpenLogs),
            exportDiagnostics: #selector(exportDiagnostics), showPrivacy: #selector(menuShowPrivacy),
            showTerms: #selector(menuShowTerms), openWebsite: #selector(menuOpenWebsite),
            contactSupport: #selector(menuContactSupport)))
        handleTerminationSignal()
        configurePlaylistTimer()
        configurePowerTimer()
        configureUpdateChecks()
        applyPerformance()
        if !AppFolder.settings.bool(forKey: Self.welcomeShownKey) {
            AppFolder.settings.set(true, forKey: Self.welcomeShownKey)
            showWelcome()
        }
        // 文件访问的授权在进软件时就问完，问完再把壁纸放上桌面（壁纸要读这些文件；弹窗期间桌面保持原样）。
        // 系统音频录制的授权只有音乐可视化壁纸用得到，在后台接着问，不挡着壁纸
        Task {
            await permissionPrimer.prime(locations: permissionLocations)
            controller.start()
            // 已经下到本机的（包括 M7 时 SteamCMD 下到 ~/Library/Application Support/Steam 的、改名前留在原处的）并进壁纸库。
            // 以前的下载目录里只剩统一文件夹里已经有的编号（迁移时留在原处的重复）就不加，免得壁纸库里出现两份
            let current = Workshop.localItemIDs(in: [Workshop.downloadDirectory])
            for folder in Workshop.downloadDirectories where Workshop.containsItems(folder) {
                if Self.key(folder) != Self.key(Workshop.downloadDirectory),
                   Workshop.localItemIDs(in: [folder]).isSubset(of: current) { continue }
                includeWorkshopFolder(folder)
            }
            // 创意工坊：本机存过登录会话就在后台连上 Steam（不用再登录一次）。不急：等壁纸先建好、画出来，
            // 免得和场景构建抢 CPU 和网络（先打开创意工坊的话 activate 会马上连）
            try? await Task.sleep(for: .seconds(3))
            workshop.start()
        }
    }

    /// 读取时可能要系统授权的位置：壁纸文件夹、WE 自带素材、每块屏幕（包括没接上的）用的壁纸、锁屏图片
    private var permissionLocations: [URL] {
        var locations = libraryFolders.folders
        if let assetsDirectory { locations.append(assetsDirectory) }
        for source in assignments.storedSources {
            switch source {
            case .video(let url), .project(let url): locations.append(url)
            case .testPattern: break
            }
        }
        if let path = lockScreenWallpaperPath { locations.append(URL(fileURLWithPath: path)) }
        return locations
    }

    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 应用不在运行时，桌面应该是用户原来的壁纸；恢复要在 stop 之前，stop 会清空显示器列表
        if let controller, controller.systemWallpaperSync != nil {
            systemWallpaper.restore(displays: controller.displays)
        }
        controller?.stop()
        crashGuard.clear()
        log.write("退出")
    }

    // MARK: - 内容

    private func makeContent(for display: DisplaySnapshot) -> any DesktopContent {
        switch resolvedSource(for: display) {
        case .testPattern:
            return makeTestPattern(for: display)
        case .video(let url):
            return makeVideo(url, for: display)
        case .project(let folder):
            return makeProjectContent(folder, for: display)
        }
    }

    /// 这块屏幕该放什么。单独设置过的用它自己那份；没设置过（刚插上的 HDMI / DP 副屏、或者
    /// 以前从没分配过的屏幕）就**沿用主显示器上现在用的那张**，并记成它自己的设置，
    /// 免得新屏幕显示默认的测试图案
    private func resolvedSource(for display: DisplaySnapshot) -> WallpaperSource {
        if let stored = assignments.storedSource(forDisplay: display.stableKey) { return stored }
        let mainKey = controller?.displays.first { $0.id == CGMainDisplayID() }?.stableKey
        let inherited = assignments.inheritedSource(forDisplay: display.stableKey, mainDisplayKey: mainKey)
        // 只在真继承到东西时记下来；继承不到（还只有测试图案）就先不写，
        // 这样以后主屏设了壁纸，这块屏还能跟上
        if inherited != .testPattern {
            assignments.setSource(inherited, forDisplay: display.stableKey)
            log.write("显示器 \(display.id) 没有单独设置过，沿用当前壁纸：\(inherited.storageValue)")
        }
        return inherited
    }

    private func makeVideo(
        _ url: URL, for display: DisplaySnapshot, options: WallpaperOptions = WallpaperOptions()
    ) -> any DesktopContent {
        if let reason = failedVideos[url] {
            return makeTestPattern(for: display, notice: String(localized: "无法播放 \(url.lastPathComponent)：\(reason)"))
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.write("显示器 \(display.id) 找不到视频文件：\(url.path)")
            return makeTestPattern(for: display, notice: String(localized: "找不到视频文件：\(url.path)"))
        }
        let video = VideoContent(url: url, label: "显示器 \(display.id)", log: log) { [weak self] reason in
            self?.videoDidFail(url: url, displayID: display.id, reason: reason)
        }
        video.setPausedByUser(isGloballyPaused || isPausedByPower || pausedDisplays.contains(display.id))
        apply(options, to: video)
        return video
    }

    private func makeProjectContent(_ folder: URL, for display: DisplaySnapshot) -> any DesktopContent {
        guard let loaded = projects[Self.key(folder)] else {
            loadProject(folder, thenReload: display.id)
            // 占位：读完之前屏幕上保持原来的画面（读取可能在等用户回应系统的访问授权）
            return makeTestPattern(
                for: display, notice: String(localized: "正在读取项目 \(folder.lastPathComponent)…　如果系统询问文件访问权限，请允许"),
                isPlaceholder: true)
        }
        let project: WallpaperProject
        do {
            project = try loaded.get()
        } catch {
            log.write("显示器 \(display.id) 读取项目失败 \(folder.path)：\(error.localizedDescription)")
            return makeTestPattern(for: display, notice: String(localized: "读取项目失败：\(error.localizedDescription)"))
        }
        guard let entry = project.entry else {
            return makeTestPattern(for: display, notice: String(localized: "「\(project.title)」的 project.json 没有写入口文件"))
        }

        switch project.kind {
        case .video:
            return makeVideo(entry, for: display, options: optionsStore.options(for: project.folder))
        case .web:
            // 开发用：设置了这个环境变量时，网页壁纸加载完会测帧率并截图到该目录
            let captureDirectory = ProcessInfo.processInfo.environment["MACWALLPAPER_CAPTURE_DIR"]
            let web = WebContent(
                folder: project.folder, entry: entry,
                userProperties: project.userPropertiesJSON(overrides: propertyStore.overrides(for: project.folder)),
                allowNetwork: allowWebNetwork, label: "显示器 \(display.id)", log: log,
                debugCapture: captureDirectory.map {
                    URL(fileURLWithPath: $0).appendingPathComponent("display-\(display.id).png")
                })
            web.setPausedByUser(isGloballyPaused || isPausedByPower || pausedDisplays.contains(display.id))
            apply(optionsStore.options(for: project.folder), to: web)
            applyPerformanceSettings(to: web)
            return web
        case .scene:
            if let reason = failedScenes[Self.key(project.folder)] {
                return makeTestPattern(for: display, notice: String(localized: "场景「\(project.title)」载入失败：\(reason)"))
            }
            let key = Self.key(project.folder)
            let options = optionsStore.options(for: project.folder)
            // 每次载入单独记一笔：同一张重建、或者放在两块屏幕上时，先到时的那次擦不掉后来的
            let guardToken = crashGuard.begin(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.crashGuardSeconds) { [weak self] in
                self?.crashGuard.end(guardToken)
            }
            let scene = SceneContent(
                projectFolder: project.folder, assets: assetsDirectory, targetSize: display.pixelSize,
                userProperties: project.propertyValuesJSON(overrides: propertyStore.overrides(for: project.folder)),
                hiddenElements: hiddenElementStore.hidden(for: project.folder),
                display: SceneContent.Display(fitsWhole: options.fitsWhole, position: Float(options.clampedPosition)),
                label: "显示器 \(display.id)", log: log
            ) { [weak self] reason in
                self?.crashGuard.end(guardToken)
                self?.failedScenes[key] = reason
                Task { [weak self] in self?.controller?.reloadContent(for: display.id) }
            }
            // 和视频、网页一样，新建时就按当前的暂停和声音设置来（之前场景漏了暂停状态）
            scene.setPausedByUser(isGloballyPaused || isPausedByPower || pausedDisplays.contains(display.id))
            apply(options, to: scene)
            applyPerformanceSettings(to: scene)
            return scene
        case .application:
            return makeTestPattern(for: display, notice: String(localized: "「\(project.title)」是应用程序类壁纸，macOS 上无法运行"))
        case .unknown:
            return makeTestPattern(for: display, notice: String(localized: "「\(project.title)」的类型认不出来"))
        }
    }

    private func loadProject(_ folder: URL, thenReload displayID: CGDirectDisplayID) {
        let alreadyLoading = projectReloads[Self.key(folder)] != nil
        projectReloads[Self.key(folder), default: []].insert(displayID)
        guard !alreadyLoading else { return }

        let started = Date()
        Task {
            let result = await Task.detached { Result { try WallpaperProject(folder: folder) } }.value
            let seconds = Date().timeIntervalSince(started)
            if seconds > 1 {
                log.write("读取项目 \(folder.lastPathComponent) 用了 \(String(format: "%.1f", seconds)) 秒（可能在等待访问授权）")
            }
            projects[Self.key(folder)] = result
            for id in projectReloads.removeValue(forKey: Self.key(folder)) ?? [] {
                controller?.reloadContent(for: id)
            }
            snapshotSettingsIfRequested()
            snapshotLibraryIfRequested()
        }
    }

    private func makeTestPattern(
        for display: DisplaySnapshot, notice: String? = nil, isPlaceholder: Bool = false
    ) -> TestPatternView {
        windowGeneration += 1
        return TestPatternView(display: display, generation: windowGeneration, notice: notice, isPlaceholder: isPlaceholder)
    }

    private func videoDidFail(url: URL, displayID: CGDirectDisplayID, reason: String) {
        failedVideos[url] = reason
        // 不在视频自己的回调里把它拆掉，等这一轮事件处理完再换
        Task { [weak self] in
            self?.controller?.reloadContent(for: displayID)
        }
    }

    private func applyPauseState() {
        guard let controller else { return }
        for display in controller.displays {
            let content = controller.content(for: display.id) as? any UserPausable
            content?.setPausedByUser(isGloballyPaused || isPausedByPower || pausedDisplays.contains(display.id))
        }
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle", accessibilityDescription: String(localized: "壁坞"))
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 每次打开菜单时重建，保证勾选状态和显示器列表是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let controller else { return }
        menu.removeAllItems()

        menu.addItem(makeItem(controller.isShown ? String(localized: "隐藏壁纸") : String(localized: "显示壁纸"), #selector(toggleShown)))
        menu.addItem(makeItem(String(localized: "壁纸库…"), #selector(openLibrary(_:))))

        let playlistMenu = NSMenu()
        playlistMenu.addItem(makeItem(playlist.isEnabled ? String(localized: "关闭轮播") : String(localized: "开启轮播"), #selector(togglePlaylist)))
        playlistMenu.addItem(.separator())
        for minutes in [5, 10, 15, 30, 60, 120] {
            let item = makeItem(String(localized: "每 \(minutes) 分钟换一张"), #selector(selectPlaylistInterval(_:)))
            item.representedObject = NSNumber(value: minutes)
            item.state = playlist.intervalMinutes == minutes ? .on : .off
            playlistMenu.addItem(item)
        }
        playlistMenu.addItem(.separator())
        for mode in PlaylistSettings.Mode.allCases {
            let item = makeItem(mode.title, #selector(selectPlaylistMode(_:)))
            item.representedObject = mode.rawValue
            item.state = playlist.mode == mode ? .on : .off
            playlistMenu.addItem(item)
        }
        playlistMenu.addItem(.separator())
        playlistMenu.addItem(makeItem(String(localized: "立即换一张"), #selector(rotateNow)))
        let playlistItem = NSMenuItem(title: String(localized: "轮播"), action: nil, keyEquivalent: "")
        playlistItem.submenu = playlistMenu
        playlistItem.toolTip = String(localized: "按时间自动换壁纸：只换当前用着项目壁纸的显示器，候选是壁纸库里的场景、视频和网页。")
        menu.addItem(playlistItem)

        menu.addItem(makeItem(isGloballyPaused ? String(localized: "全部继续") : String(localized: "全部暂停"), #selector(toggleGlobalPause)))
        let audio = makeItem(String(localized: "播放壁纸声音"), #selector(toggleAudio))
        audio.state = playAudio ? .on : .off
        audio.toolTip = String(localized: "总开关：视频的音轨、网页壁纸的声音、场景里的声音对象。壁纸被遮住或暂停时声音也停。单个壁纸的静音和音量在壁纸库右侧的设置里。")
        menu.addItem(audio)
        let network = makeItem(String(localized: "网页壁纸允许联网"), #selector(toggleWebNetwork))
        network.state = allowWebNetwork ? .on : .off
        menu.addItem(network)

        let performanceMenu = NSMenu()
        for fps in [30, 60, 0] {
            let item = makeItem(
                fps == 0 ? String(localized: "不限制帧率") : String(localized: "最高 \(fps) 帧"), #selector(selectFrameRate(_:)))
            item.representedObject = NSNumber(value: fps)
            item.state = performance.maximumFrameRate == fps ? .on : .off
            performanceMenu.addItem(item)
        }
        performanceMenu.addItem(.separator())
        for mode in PerformanceSettings.BatteryMode.allCases {
            let item = makeItem(String(localized: "用电池时：\(mode.title)"), #selector(selectBatteryMode(_:)))
            item.representedObject = mode.rawValue
            item.state = performance.batteryMode == mode ? .on : .off
            performanceMenu.addItem(item)
        }
        performanceMenu.addItem(.separator())
        let covered = makeItem(String(localized: "桌面被窗口挡住时暂停"), #selector(togglePausesWhenCovered))
        covered.state = performance.pausesWhenCovered ? .on : .off
        covered.toolTip = String(localized: "桌面几乎被窗口盖满（只剩菜单栏、程序坞那一条）时，动态壁纸停在当前画面，露出来马上接着播放。")
        performanceMenu.addItem(covered)
        let adaptive = makeItem(String(localized: "按画面快慢自动降帧"), #selector(toggleAdaptiveFrameRate))
        adaptive.state = performance.adaptsFrameRate ? .on : .off
        adaptive.toolTip = String(localized: "场景壁纸隔一会儿量一下画面动得多快，慢节奏的降到 20 或 24 帧（每帧挪动不超过 2 个点，看不出区别），动得快的照常。跟着音乐律动的不降；鼠标带动画面时按上限。")
        performanceMenu.addItem(adaptive)
        let performanceItem = NSMenuItem(title: String(localized: "性能"), action: nil, keyEquivalent: "")
        performanceItem.submenu = performanceMenu
        performanceItem.toolTip = PowerSource.isOnBattery
            ? String(localized: "帧率上限影响场景和网页壁纸；现在在用电池。") : String(localized: "帧率上限影响场景和网页壁纸；现在接着电源。")
        menu.addItem(performanceItem)

        let sync = makeItem(String(localized: "系统壁纸同步为当前画面"), #selector(toggleSystemWallpaperSync))
        sync.state = syncSystemWallpaper ? .on : .off
        sync.toolTip = String(localized: "编辑桌面小组件、调度中心、锁屏时，系统会藏起动态壁纸，露出系统壁纸。开启后露出的是当前画面的静态帧；退出应用时恢复原来的系统壁纸。")
        menu.addItem(sync)

        let lockScreenMenu = NSMenu()
        let follow = makeItem(String(localized: "跟随当前画面"), #selector(useCurrentFrameForLockScreen))
        follow.state = lockScreenWallpaperPath == nil ? .on : .off
        follow.toolTip = String(localized: "锁屏时显示动态壁纸当前的画面（默认）")
        lockScreenMenu.addItem(follow)
        lockScreenMenu.addItem(makeItem(String(localized: "选择图片…"), #selector(chooseLockScreenWallpaper)))
        if let path = lockScreenWallpaperPath {
            lockScreenMenu.addItem(.separator())
            lockScreenMenu.addItem(NSMenuItem(
                title: String(localized: "当前：\((path as NSString).lastPathComponent)"), action: nil, keyEquivalent: ""))
        }
        let lockScreenItem = NSMenuItem(title: String(localized: "锁屏壁纸"), action: nil, keyEquivalent: "")
        lockScreenItem.submenu = lockScreenMenu
        lockScreenItem.toolTip = String(localized: "锁屏、调度中心、编辑桌面小组件时系统会露出系统壁纸（需要打开上面的同步）。默认用动态壁纸当前的画面，也可以固定选一张图片——例如让锁屏看照片、桌面继续播动态壁纸。")
        menu.addItem(lockScreenItem)
        let login = makeItem(String(localized: "开机自动启动"), #selector(toggleLoginItem))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(makeItem(String(localized: "首次使用提示…"), #selector(showWelcomeAgain)))
        menu.addItem(makeItem(String(localized: "关于\(MainMenu.appName)…"), #selector(showAbout)))
        if updateRepository != nil {
            menu.addItem(makeItem(String(localized: "检查更新…"), #selector(checkForUpdatesNow)))
            let automatic = makeItem(String(localized: "自动检查更新"), #selector(toggleAutomaticUpdateChecks))
            automatic.state = checksForUpdatesAutomatically ? .on : .off
            automatic.toolTip = String(localized: "每天向 GitHub 读一次最新版本的信息（会用到你的网络地址，不带任何账号信息）。关掉以后只在点「检查更新…」时检查。")
            menu.addItem(automatic)
        }
        menu.addItem(.separator())

        for display in controller.displays {
            let item = NSMenuItem(title: display.summary, action: nil, keyEquivalent: "")
            item.submenu = makeDisplayMenu(for: display)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let levelMenu = NSMenu()
        for level in DesktopLevel.allCases {
            let item = makeItem(level.title, #selector(selectLevel(_:)))
            item.representedObject = level.rawValue
            item.state = level == controller.level ? .on : .off
            levelMenu.addItem(item)
        }
        let levelItem = NSMenuItem(title: String(localized: "窗口层级"), action: nil, keyEquivalent: "")
        levelItem.submenu = levelMenu
        menu.addItem(levelItem)
        menu.addItem(makeItem(String(localized: "立即自检"), #selector(probeNow)))
        menu.addItem(makeItem(String(localized: "打开日志"), #selector(openLog)))
        menu.addItem(makeItem(String(localized: "导出诊断信息…"), #selector(exportDiagnostics)))
        menu.addItem(makeItem(
            assetsDirectory == nil ? String(localized: "导入 Wallpaper Engine 自带素材…") : String(localized: "重新导入 Wallpaper Engine 自带素材…"),
            #selector(chooseAssetsDirectory)))
        menu.addItem(NSMenuItem(title: String(localized: "累计修复 \(controller.repairCount) 次"), action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func makeDisplayMenu(for display: DisplaySnapshot) -> NSMenu {
        let menu = NSMenu()
        let current: String
        switch assignments.source(forDisplay: display.stableKey) {
        case .testPattern: current = String(localized: "当前：测试图案")
        case .video(let url): current = String(localized: "当前：\(url.lastPathComponent)")
        case .project(let folder):
            current = String(localized: "当前：") + ((try? projects[Self.key(folder)]?.get())?.title ?? folder.lastPathComponent)
        }
        menu.addItem(NSMenuItem(title: current, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem(String(localized: "从壁纸库选择…"), #selector(openLibrary(_:)), display: display.id))
        menu.addItem(makeItem(String(localized: "选择视频…"), #selector(chooseVideo(_:)), display: display.id))
        menu.addItem(makeItem(String(localized: "选择壁纸项目文件夹…"), #selector(chooseProject(_:)), display: display.id))
        menu.addItem(makeItem(String(localized: "使用测试图案"), #selector(useTestPattern(_:)), display: display.id))
        if case .project(let folder) = assignments.source(forDisplay: display.stableKey),
           let project = try? projects[Self.key(folder)]?.get(), project.kind == .scene || project.kind == .web,
           project.properties.contains(where: \.isEditable) {
            menu.addItem(makeItem(String(localized: "壁纸设置…"), #selector(openProperties(_:)), display: display.id))
        }
        if controller?.content(for: display.id) is any UserPausable {
            let title = pausedDisplays.contains(display.id) ? String(localized: "继续播放") : String(localized: "暂停")
            menu.addItem(makeItem(title, #selector(toggleDisplayPause(_:)), display: display.id))
        }
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector, display: CGDirectDisplayID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = display.map { NSNumber(value: $0) }
        return item
    }

    private func display(from sender: NSMenuItem) -> DisplaySnapshot? {
        guard let number = sender.representedObject as? NSNumber else { return nil }
        return controller?.displays.first { $0.id == number.uint32Value }
    }

    // MARK: - 菜单动作

    @objc private func toggleShown() {
        guard let controller else { return }
        controller.setShown(!controller.isShown)
    }

    @objc private func toggleGlobalPause() {
        isGloballyPaused.toggle()
        applyPauseState()
    }

    @objc private func toggleDisplayPause(_ sender: NSMenuItem) {
        guard let display = display(from: sender) else { return }
        if pausedDisplays.remove(display.id) == nil { pausedDisplays.insert(display.id) }
        applyPauseState()
    }

    @objc private func chooseVideo(_ sender: NSMenuItem) {
        guard let display = display(from: sender) else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "为「\(display.name)」选择一个视频")
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            if let reason = await VideoContent.unplayableReason(for: url) {
                log.write("显示器 \(display.id) 拒绝了 \(url.path)：\(reason)")
                showAlert(String(localized: "不能用这个文件作壁纸"), detail: "\(url.lastPathComponent)\n\(reason)")
                return
            }
            failedVideos[url] = nil
            assignments.setSource(.video(url), forDisplay: display.stableKey)
            log.write("显示器 \(display.id) 改用视频：\(url.path)")
            controller?.reloadContent(for: display.id)
            refreshLibraryCurrent()
        }
    }

    @objc private func chooseProject(_ sender: NSMenuItem) {
        guard let display = display(from: sender) else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "为「\(display.name)」选择一个含 project.json 的壁纸项目文件夹")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let project: WallpaperProject
        do {
            project = try WallpaperProject(folder: folder)
        } catch {
            showAlert(String(localized: "不能用这个文件夹作壁纸"), detail: "\(folder.lastPathComponent)\n\(error.localizedDescription)")
            return
        }
        apply(project, to: display)
    }

    /// 把项目设为某块显示器的壁纸（菜单选文件夹、壁纸库共用）
    private func apply(_ project: WallpaperProject, to display: DisplaySnapshot) {
        apply(project, to: display, reportFailure: true)
    }

    /// - Parameter reportFailure: 轮播换壁纸时不弹窗打断用户（失败的照样写日志）
    private func apply(_ project: WallpaperProject, to display: DisplaySnapshot, reportFailure: Bool) {
        Task {
            if let reason = await unsupportedReason(for: project) {
                log.write("显示器 \(display.id) 拒绝了项目 \(project.folder.path)：\(reason)")
                if reportFailure { showAlert(String(localized: "不能用这个项目作壁纸"), detail: "\(project.title)\n\(reason)") }
                return
            }
            if let entry = project.entry { failedVideos[entry] = nil }
            failedScenes[Self.key(project.folder)] = nil
            projects[Self.key(project.folder)] = .success(project)
            assignments.setSource(.project(project.folder), forDisplay: display.stableKey)
            log.write("显示器 \(display.id) 改用项目「\(project.title)」（\(project.kind.rawValue)）：\(project.folder.path)")
            controller?.reloadContent(for: display.id)
            refreshLibraryCurrent()
        }
    }

    // MARK: - 壁纸库

    // MARK: - 轮播

    private var playlist: PlaylistSettings {
        get { playlistStore.settings }
        set { playlistStore.settings = newValue }
    }

    private var performance: PerformanceSettings {
        get { performanceStore.settings }
        set { performanceStore.settings = newValue }
    }

    private var effectiveFrameRate: Int {
        performance.effectiveFrameRate(PowerConditions.current)
    }

    /// 把帧率上限推给支持的内容（场景、网页）
    private func applyPerformanceSettings(to content: any DesktopContent) {
        guard let adjustable = content as? any FrameRateAdjustable else { return }
        adjustable.setMaximumFrameRate(effectiveFrameRate)
        adjustable.setAdaptiveFrameRate(performance.adaptsFrameRate)
    }

    /// 电源状态、低电量模式、机器温度或设置变了：更新帧率、必要时暂停
    private func applyPerformance() {
        let conditions = PowerConditions.current
        let settings = performance
        let pauseReason = settings.pauseReason(conditions)
        let fps = settings.effectiveFrameRate(conditions)
        if (pauseReason != nil) != isPausedByPower || fps != lastEffectiveFrameRate || conditions.summary != lastPowerSummary {
            let state = pauseReason.map { "暂停动态壁纸（\($0)）" } ?? (fps == 0 ? "不限帧率" : "最高 \(fps) 帧")
            log.write("性能：\(conditions.summary)，\(state)")
        }
        lastEffectiveFrameRate = fps
        lastPowerSummary = conditions.summary
        if (pauseReason != nil) != isPausedByPower {
            isPausedByPower = pauseReason != nil
            applyPauseState()
        }
        guard let controller else { return }
        controller.pausesWhenCovered = settings.pausesWhenCovered
        for display in controller.displays {
            guard let content = controller.content(for: display.id) else { continue }
            applyPerformanceSettings(to: content)
        }
    }

    /// 电源、低电量模式、温度一变就调整（系统通知，不轮询）
    private func configurePowerTimer() {
        powerMonitor.start()
    }

    /// 开启后每分钟检查一次到没到时间；到点把"当前用着项目壁纸"的显示器换成下一张
    private func configurePlaylistTimer() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        guard playlist.isEnabled else { return }
        lastRotation = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotateIfDue() }
        }
        timer.tolerance = 10
        playlistTimer = timer
    }

    private func rotateIfDue() {
        guard playlist.isEnabled else { return }
        let interval = Double(playlist.intervalMinutes) * 60
        guard Date().timeIntervalSince(lastRotation) >= interval else { return }
        lastRotation = Date()
        rotateWallpapers()
    }

    /// 立即换一张（菜单里的"立即换一张"和定时器共用）
    private func rotateWallpapers() {
        guard let controller else { return }
        let projects = LibraryScanner.scan(folders: libraryFolders.folders)
        guard !projects.isEmpty else {
            log.write("轮播：壁纸库是空的（先在壁纸库里添加文件夹）")
            return
        }
        let isRandom = playlist.mode == .random
        var switched = 0
        for display in controller.displays {
            guard case .project(let folder) = assignments.source(forDisplay: display.stableKey) else { continue }
            guard let next = PlaylistPicker.next(
                from: projects, current: folder, isRandom: isRandom, using: &playlistRandom)
            else { continue }
            apply(next, to: display, reportFailure: false)
            switched += 1
        }
        log.write("轮播：\(switched) 块显示器换了壁纸（\(playlist.mode.title)，每 \(playlist.intervalMinutes) 分钟）")
    }

    @objc private func openLibrary(_ sender: NSMenuItem) {
        showLibrary(selecting: display(from: sender)?.id)
    }

    // MARK: - 删除壁纸

    /// 先问一句再移到废纸篓（能从废纸篓放回来，不直接删）
    private func confirmDelete(_ project: WallpaperProject) {
        let alert = NSAlert()
        alert.messageText = String(localized: "把「\(project.title)」移到废纸篓？")
        var lines = [String(localized: "整个项目文件夹会移到废纸篓，需要时可以从废纸篓放回原处。")]
        let users = displays(showing: project)
        if !users.isEmpty {
            lines.append(String(localized: "它正在 \(users.count) 块显示器上用作壁纸，删除后这些显示器换成壁纸库里的下一张。"))
        }
        let workshopID = Workshop.itemID(ofProjectFolder: project.folder)
        if workshopID != nil {
            lines.append(String(localized: "勾上下面这项，会同时在 Steam 上取消订阅（不用打开网页）。"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "同时在 Steam 上取消订阅")
            alert.suppressionButton?.state = workshop.subscribedIDs.contains(workshopID ?? "") ? .on : .off
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: String(localized: "移到废纸篓"))
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "取消"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard moveToTrash([project.folder]) else { return }
        if let workshopID, alert.suppressionButton?.state == .on {
            unsubscribeOnSteam(workshopID, title: project.title)
        }
    }

    /// 只在 Steam 上取消订阅（本机文件已经处理过了）。没登录就先登录，登录好接着取消
    private func unsubscribeOnSteam(_ id: String, title: String) {
        Task { [self] in
            switch await workshop.setSubscribed(false, id: id) {
            case .done:
                break
            case .notLoggedIn:
                showLibrary(selecting: nil)
                workshop.showLogin(reason: String(localized: "在 Steam 上取消订阅「\(title)」要先登录。")) { [weak self] in
                    self?.unsubscribeOnSteam(id, title: title)
                }
            case .failed(let reason):
                showAlert(String(localized: "在 Steam 上取消订阅没有成功"), detail: String(localized: "「\(title)」\n\(reason)\n本机的文件已经移到废纸篓。"))
            }
        }
    }

    /// 把这些项目文件夹移到废纸篓；正在用它们的显示器换成壁纸库里剩下的下一张（没有就回到测试图案）
    @discardableResult
    /// - Parameter library: 换"下一张"时按哪个列表的顺序；nil 时用壁纸库现在的列表（窗口没开就现扫）
    private func moveToTrash(_ folders: [URL], library: [WallpaperProject]? = nil) -> Bool {
        var trashed: [URL] = []
        for folder in folders {
            do {
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                trashed.append(folder)
                log.write("壁纸库：移到废纸篓 \(folder.path)")
            } catch {
                showAlert(String(localized: "移不到废纸篓"), detail: "\(folder.path)\n\(error.localizedDescription)")
            }
        }
        guard !trashed.isEmpty else { return false }
        let keys = Set(trashed.map(Self.key))
        // 壁纸库窗口没开（例如从创意工坊同步时删的）就现扫一遍
        let library = library ?? libraryWindow?.model.projects ?? LibraryScanner.scan(folders: libraryFolders.folders)
        for display in controller?.displays ?? [] {
            guard case .project(let folder) = assignments.source(forDisplay: display.stableKey),
                  keys.contains(Self.key(folder))
            else { continue }
            if let next = PlaylistPicker.replacement(for: folder, deleting: trashed, in: library) {
                apply(next, to: display, reportFailure: false)
            } else {
                assignments.setSource(.testPattern, forDisplay: display.stableKey)
                controller?.reloadContent(for: display.id)
            }
        }
        for key in keys {
            projects[key] = nil
            failedScenes[key] = nil
        }
        for folder in trashed { libraryWindow?.model.forget(folder) }
        refreshLibraryCurrent()
        return true
    }

    // MARK: - 创意工坊

    @objc private func openWorkshop() {
        showWorkshop(item: nil)
    }

    /// 打开壁纸库并切到"Steam 创意工坊"；给了编号就在 Steam 上打开那一条（网格里不一定有它）
    private func showWorkshop(item: String?) {
        showLibrary(selecting: nil)
        guard let model = libraryWindow?.model else { return }
        model.mode = .workshop
        if let item {
            if workshop.items.contains(where: { $0.id == item }) {
                workshop.selectedID = item
            } else {
                NSWorkspace.shared.open(Workshop.itemURL(item))
            }
        }
    }

    /// 创意工坊页里的"取消订阅"：本机有这张（在创意工坊下载目录里）就走和设置栏一样的流程；
    /// 只在 Steam 上订阅着的，问一句后只在 Steam 上取消
    private func confirmUnsubscribe(itemID id: String) {
        let project = Workshop.downloadDirectories.lazy
            .compactMap { try? WallpaperProject(folder: $0.appendingPathComponent(id, isDirectory: true)) }
            .first
        if let project {
            confirmUnsubscribe(project)
            return
        }
        let title = workshop.items.first { $0.id == id }?.title ?? id
        let alert = NSAlert()
        alert.messageText = String(localized: "取消订阅「\(title)」？")
        alert.informativeText = String(localized: "会在 Steam 上取消订阅。")
        alert.addButton(withTitle: String(localized: "取消订阅")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "保留"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [self] in
            switch await workshop.setSubscribed(false, id: id) {
            case .done: break
            case .notLoggedIn:
                workshop.showLogin(reason: String(localized: "取消订阅要先登录 Steam。")) { [weak self] in self?.confirmUnsubscribe(itemID: id) }
            case .failed(let reason):
                showAlert(String(localized: "取消订阅没有成功"), detail: "「\(title)」\n\(reason)")
            }
        }
    }

    /// 从创意工坊下载的壁纸"删除"就是取消订阅：问一句，在 Steam 上取消订阅，成功后把本机的文件移到废纸篓
    private func confirmUnsubscribe(_ project: WallpaperProject) {
        guard let id = Workshop.itemID(ofProjectFolder: project.folder) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "取消订阅「\(project.title)」？")
        var lines = [String(localized: "会在 Steam 上取消订阅，并把它从这台 Mac 移除（文件移到废纸篓）。")]
        if !displays(showing: project).isEmpty {
            lines.append(String(localized: "它正在用作壁纸，取消后换成壁纸库里的下一张。"))
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .warning
        let button = alert.addButton(withTitle: String(localized: "取消订阅"))
        button.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "保留"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        unsubscribe(project, id: id)
    }

    private func unsubscribe(_ project: WallpaperProject, id: String) {
        // 界面先变：点了确认就从列表里拿掉（Steam 回话要一会儿，断线时还要重连）；没成功再扫一遍放回来。
        // 拿掉之前记下列表：正在用它当壁纸的屏要按原来的顺序换成"下一张"
        let library = libraryWindow?.model.projects
        libraryWindow?.model.forget(project.folder)
        Task { [self] in
            switch await workshop.setSubscribed(false, id: id) {
            case .done:
                log.write("创意工坊：取消订阅 \(id)，移走本机文件")
                // 移不走（权限、外接盘上正在用）时文件还在：扫一遍放回列表
                if !moveToTrash([project.folder], library: library) { libraryWindow?.model.rescan() }
            case .notLoggedIn:
                libraryWindow?.model.rescan()
                workshop.showLogin(reason: String(localized: "取消订阅要先登录 Steam。")) { [weak self] in
                    self?.unsubscribe(project, id: id)
                }
            case .failed(let reason):
                libraryWindow?.model.rescan()
                showAlert(String(localized: "取消订阅没有成功"), detail: String(localized: "「\(project.title)」\n\(reason)\n本机的文件没有动。"))
            }
        }
    }

    /// 创意工坊的壁纸下好了：下载目录加进壁纸库（第一次时），壁纸库重新扫描
    private func workshopDidDownload(into folder: URL) {
        includeWorkshopFolder(folder)
        libraryWindow?.model.rescan()
    }

    /// 创意工坊的下载目录还不在壁纸库里就加进去
    private func includeWorkshopFolder(_ folder: URL) {
        guard !libraryFolders.folders.contains(where: { Self.key($0) == Self.key(folder) }) else { return }
        // 日志由 libraryFolders.onChange 写
        libraryFolders.add(folder)
        libraryWindow?.model.rescan()
    }

    /// 同步订阅时发现的：从创意工坊下载过、但已经不在订阅里的条目，问要不要移到废纸篓
    private func offerToTrashUnsubscribed(_ folders: [URL]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "有 \(folders.count) 个壁纸已经不在你的订阅里")
        alert.informativeText = String(localized: "它们是之前从创意工坊下到这台 Mac 的，后来在 Steam 上取消了订阅。要移到废纸篓吗？（只处理创意工坊下载目录里的，你自己拷来的壁纸不动）")
        alert.addButton(withTitle: String(localized: "移到废纸篓"))
        alert.addButton(withTitle: String(localized: "保留"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moveToTrash(folders)
    }

    @objc private func togglePlaylist() {
        var settings = playlist
        settings.isEnabled.toggle()
        playlist = settings
        log.write("轮播：\(settings.isEnabled ? "开启（每 \(settings.intervalMinutes) 分钟）" : "关闭")")
        configurePlaylistTimer()
    }

    @objc private func selectPlaylistInterval(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? NSNumber else { return }
        var settings = playlist
        settings.intervalMinutes = minutes.intValue
        settings.isEnabled = true
        playlist = settings
        log.write("轮播：每 \(settings.intervalMinutes) 分钟换一张")
        configurePlaylistTimer()
    }

    @objc private func selectPlaylistMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PlaylistSettings.Mode(rawValue: raw)
        else { return }
        var settings = playlist
        settings.mode = mode
        playlist = settings
        log.write("轮播：改成\(mode.title)")
    }

    @objc private func rotateNow() {
        lastRotation = Date()
        rotateWallpapers()
    }

    @objc private func selectFrameRate(_ sender: NSMenuItem) {
        guard let fps = sender.representedObject as? NSNumber else { return }
        var settings = performance
        settings.maximumFrameRate = fps.intValue
        performance = settings
        log.write("性能：帧率上限 \(settings.frameRateTitle)")
        applyPerformance()
    }

    @objc private func toggleAdaptiveFrameRate() {
        var settings = performance
        settings.adaptsFrameRate.toggle()
        performance = settings
        log.write("性能：按画面快慢自动降帧\(settings.adaptsFrameRate ? "开" : "关")")
        applyPerformance()
    }

    @objc private func togglePausesWhenCovered() {
        var settings = performance
        settings.pausesWhenCovered.toggle()
        performance = settings
        log.write("性能：桌面被窗口挡住时\(settings.pausesWhenCovered ? "暂停" : "照常播放")")
        applyPerformance()
    }

    @objc private func selectBatteryMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PerformanceSettings.BatteryMode(rawValue: raw)
        else { return }
        var settings = performance
        settings.batteryMode = mode
        performance = settings
        log.write("性能：用电池时\(mode.title)")
        applyPerformance()
    }

    // MARK: - 开机启动与首次引导

    @objc private func toggleLoginItem() {
        let enable = !LoginItem.isEnabled
        if let reason = LoginItem.setEnabled(enable) {
            log.write("开机自动启动：\(enable ? "开启" : "关闭")失败：\(reason)")
            showAlert(
                String(localized: "改不了开机启动"), detail: String(localized: "\(reason)\n\n把 WallPort.app（壁坞）放到「应用程序」里再试（直接 swift run 的调试版不支持）。"))
        } else {
            log.write("开机自动启动：\(enable ? "开启" : "关闭")")
        }
    }

    @objc private func showWelcomeAgain() {
        showWelcome()
    }

    /// 直接在 .dmg 里、或者没挪过地方的下载文件夹里打开时，macOS 会把 App 放到一个随机的只读位置运行
    /// （App Translocation）：开机自动启动登记不上，每次打开的位置都不一样。提示用户先拖进「应用程序」
    private func warnIfNotInstalled() {
        guard LoginItem.isRunningFromTemporaryLocation else { return }
        log.write("启动：App 在只读位置运行（\(Bundle.main.bundleURL.path)），提示拖进「应用程序」")
        showAlert(
            String(localized: "请先把\(MainMenu.appName)拖进「应用程序」文件夹"),
            detail: String(localized: "现在是直接从安装包（.dmg）或下载文件夹里打开的，macOS 会把它放在临时位置运行，「开机自动启动」等功能用不了。退出后把它拖进「应用程序」，再从那里打开。"))
    }

    // MARK: - 检查更新

    private static let skippedUpdateKey = "skippedUpdateVersion"

    /// 发布在哪个 GitHub 仓库（"用户名/仓库名"，发布脚本写进 Info.plist）；开发版没有，不检查
    private var updateRepository: String? { PublisherInfo.gitHubRepository }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 启动 10 秒后查一次（不和壁纸构建抢），之后每 24 小时一次
    private func configureUpdateChecks() {
        guard updateRepository != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            await checkForUpdates(manual: false)
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdates(manual: false) }
        }
    }

    private static let automaticUpdateChecksKey = "checksForUpdatesAutomatically"

    /// 自动检查更新（默认开）。关掉以后只在手动点"检查更新…"时连 GitHub
    private var checksForUpdatesAutomatically: Bool {
        get { AppFolder.settings.object(forKey: Self.automaticUpdateChecksKey) as? Bool ?? true }
        set { AppFolder.settings.set(newValue, forKey: Self.automaticUpdateChecksKey) }
    }

    @objc private func toggleAutomaticUpdateChecks() {
        checksForUpdatesAutomatically.toggle()
        log.write("检查更新：自动检查\(checksForUpdatesAutomatically ? "开" : "关")")
    }

    @objc private func checkForUpdatesNow() {
        Task { await checkForUpdates(manual: true) }
    }

    /// 有新版本就问一句：下载（打开下载页）/ 以后再说 / 跳过这个版本。手动检查时没有新版本、出错也告诉用户
    private func checkForUpdates(manual: Bool) async {
        guard let repository = updateRepository, manual || checksForUpdatesAutomatically else { return }
        let info: UpdateInfo
        do {
            info = try await UpdateCheck.fetch(repository: repository)
        } catch {
            log.write("检查更新：\(error.localizedDescription)")
            if manual { showAlert(String(localized: "没能检查更新"), detail: error.localizedDescription) }
            return
        }
        let skipped = manual ? nil : AppFolder.settings.string(forKey: Self.skippedUpdateKey)
        guard let update = UpdateCheck.newer(info, currentVersion: currentVersion, skippedVersion: skipped) else {
            if manual {
                showAlert(String(localized: "已经是最新版本"), detail: String(localized: "\(MainMenu.appName) \(currentVersion) 就是现在最新的版本。"))
            }
            return
        }
        guard manual || announcedUpdateVersion != update.version else { return }
        announcedUpdateVersion = update.version
        log.write("检查更新：有新版本 \(update.version)")
        let alert = NSAlert()
        alert.messageText = String(localized: "\(MainMenu.appName) 有新版本 \(update.version)")
        // GitHub 的更新说明可能很长（Markdown）：提示框里只放开头一段，全文在发布页上
        let notes = update.notes.map { $0.count > 600 ? String($0.prefix(600)) + "…" : $0 }
        alert.informativeText = (notes.map { $0 + "\n\n" } ?? "")
            + String(localized: "下载后把新的\(MainMenu.appName)拖进「应用程序」替换旧的；设置和壁纸都在 ~/WallPort 里，不受影响。")
        alert.addButton(withTitle: String(localized: "下载"))
        alert.addButton(withTitle: String(localized: "以后再说"))
        alert.addButton(withTitle: String(localized: "跳过这个版本"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(update.url)
        case .alertThirdButtonReturn: AppFolder.settings.set(update.version, forKey: Self.skippedUpdateKey)
        default: break
        }
    }

    // MARK: - 诊断信息

    /// 导出诊断信息：概况和日志打成 zip（默认放在桌面），用户发给开发者。账号名、用户主目录在导出前去掉，
    /// 登录凭证和完整的设置不打包（见 `Diagnostics`）
    @objc private func exportDiagnostics() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "\(MainMenu.appName)诊断信息-\(formatter.string(from: Date())).zip")
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = String(localized: "日志里的 Steam 账号名和你的用户名会被去掉；登录信息不会导出")
        NSApp.activate()
        guard panel.runModal() == .OK, let zip = panel.url else { return }
        let summary = diagnosticsSummary()
        let prefix = "workshop.subscribedIDs."
        let accounts = [workshop.accountName, AppFolder.settings.string(forKey: WorkshopModel.lastAccountKey)].compactMap { $0 }
            + AppFolder.settings.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        // 日志，加上最近 30 天壁坞自己的崩溃报告（用户说"闪退了"时看崩在哪；同样去掉账号名和主目录）
        let crashReports = Diagnostics.crashReports(
            in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
            process: ProcessInfo.processInfo.processName, since: Date().addingTimeInterval(-30 * 86400))
        let logs = [log.fileURL, log.fileURL.appendingPathExtension("1")] + crashReports
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Task {
            let failure = await Task.detached { () -> String? in
                do {
                    try Diagnostics.export(summary: summary, logs: logs, accounts: accounts, home: home, to: zip)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                showAlert(String(localized: "没能导出诊断信息"), detail: failure)
            } else {
                log.write("导出诊断信息：\(zip.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            }
        }
    }

    /// 概况：版本、系统、机器、显示器、主要设置、每块屏幕放的什么（只写编号和类型）、素材和登录状态
    private func diagnosticsSummary() -> String {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "?" }
            return String(cString: value)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let settings = performance
        var lines = [
            "\(MainMenu.appName) \(info["CFBundleShortVersionString"] ?? "?")（\(info["CFBundleVersion"] ?? "?")），\(Bundle.main.bundleIdentifier ?? "?")",
            "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "机器：\(sysctl("hw.model"))，\(sysctl("machdep.cpu.brand_string"))，内存 \(ProcessInfo.processInfo.physicalMemory >> 30) GB",
            "电源：\(PowerConditions.current.summary)",
            "性能：帧率上限 \(settings.frameRateTitle)，用电池时 \(settings.batteryMode.title)，"
                + "挡住时暂停 \(settings.pausesWhenCovered ? "开" : "关")，按画面快慢自动降帧 \(settings.adaptsFrameRate ? "开" : "关")",
            "其它：声音 \(playAudio ? "开" : "关")，网页壁纸联网 \(allowWebNetwork ? "允许" : "禁止")，"
                + "同步系统壁纸 \(syncSystemWallpaper ? "开" : "关")，窗口层级 \(controller?.level.title ?? "?")",
            "WE 自带素材：\(assetsDirectory.map { "有（\((try? FileManager.default.contentsOfDirectory(atPath: $0.path).count) ?? 0) 个子文件夹）" } ?? "没有（用兼容素材）")",
            "Steam：\(workshop.isLoggedIn ? "已登录" : "未登录")，订阅 \(workshop.subscribedIDs.count) 个",
            "壁纸库：\(libraryFolders.folders.count) 个文件夹" + (libraryWindow.map { "，\($0.model.summary)" } ?? ""),
            "",
            "显示器：",
        ]
        for display in controller?.displays ?? [] {
            let source = assignments.source(forDisplay: display.stableKey)
            let what: String = switch source {
            case .testPattern: "测试图案"
            case .video(let url): "视频 \(url.pathExtension)"
            case .project(let url): "项目 \(url.lastPathComponent)"
            }
            lines.append("  \(display.id)：\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height)) @\(display.scale)x，放的是 \(what)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 系统的"关于"窗口：版本号，以及 Credits.html 里和 Wallpaper Engine 关系的声明、第三方库的许可证
    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// 引导窗口里的"添加壁纸文件夹"
    private func addLibraryFolder() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "选择放着壁纸项目的文件夹（里面每个子文件夹是一个壁纸项目）")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        for url in panel.urls { libraryFolders.add(url) }
        log.write("壁纸库：添加 \(panel.urls.map(\.lastPathComponent).joined(separator: "、"))")
        welcomeModel?.libraryFolderCount = libraryFolders.folders.count
        libraryWindow?.model.rescan()
    }

    /// 第一次运行（或从菜单打开）时的引导
    private func showWelcome() {
        if let existing = welcomeWindow {
            presentAppWindow(existing)
            return
        }
        let model = WelcomeModel(hasAssets: assetsDirectory != nil, libraryFolderCount: libraryFolders.folders.count)
        welcomeModel = model
        let window = WelcomeWindowController(
            model: model, workshop: workshop,
            onSignIn: { [weak self] in self?.menuSignIn() },
            onChooseAssets: { [weak self] in self?.chooseAssetsDirectory() },
            onAddLibraryFolder: { [weak self] in self?.addLibraryFolder() },
            onOpenLibrary: { [weak self] in
                self?.welcomeWindow?.close()
                self?.welcomeWindow = nil
                self?.showLibrary(selecting: nil)
            })
        welcomeWindow = window
        presentAppWindow(window)
    }

    // MARK: - 顶部菜单栏

    /// 显示壁坞自己的窗口（壁纸库、欢迎）：临时切成普通应用，屏幕顶部才有这排菜单、Dock 里才有图标；
    /// 窗口全关掉以后退回菜单栏应用
    private func presentAppWindow(_ controller: NSWindowController) {
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let window = controller.window, !observedAppWindows.contains(ObjectIdentifier(window)) else { return }
        observedAppWindows.insert(ObjectIdentifier(window))
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWindowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func appWindowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        // 壁纸库关了：缩略图不再需要，内存还给系统（壁坞常驻后台）
        if closing === libraryWindow?.window { ThumbnailCache.shared.removeAll() }
        // 关的这一个之外还有壁坞自己的窗口开着就不动
        let stillOpen = [libraryWindow?.window, welcomeWindow?.window].contains { window in
            guard let window, window !== closing else { return false }
            return window.isVisible
        }
        guard !stillOpen else { return }
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }

    @objc private func menuOpenLibrary() { showLibrary(selecting: nil) }

    /// 已经在运行时又打开一次（访达里双击、`open ~/WallPort/WallPort.app`、聚焦搜索）：菜单栏应用没有 Dock 图标，
    /// 系统默认什么也不显示，看着像"没打开"——弹出壁纸库
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log.write("再次打开：显示壁纸库")
        showLibrary(selecting: nil)
        return false
    }

    @objc private func menuAddLibraryFolder() { addLibraryFolder() }

    @objc private func menuShowLocal() {
        showLibrary(selecting: nil)
        libraryWindow?.model.mode = .local
    }

    @objc private func menuShowSubscriptions() {
        showWorkshop(item: nil)
        workshop.showSubscriptions()
    }

    @objc private func menuSignIn() {
        showWorkshop(item: nil)
        workshop.showLogin(reason: nil)
    }

    @objc private func menuOpenLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
    }

    @objc private func menuShowPrivacy() { PublisherInfo.open(.privacy) }

    @objc private func menuShowTerms() { PublisherInfo.open(.terms) }

    @objc private func menuOpenWebsite() {
        if let url = PublisherInfo.websiteURL { NSWorkspace.shared.open(url) }
    }

    @objc private func menuContactSupport() {
        if let url = PublisherInfo.supportURL { NSWorkspace.shared.open(url) }
    }

    /// - Parameter project: 右侧设置栏要显示的项目；nil 时保留之前选中的，还没选过就选这块屏幕当前的壁纸
    private func showLibrary(
        selecting displayID: CGDirectDisplayID?, showsThumbnails: Bool = true, project: WallpaperProject? = nil
    ) {
        let window: LibraryWindowController
        if let existing = libraryWindow {
            window = existing
        } else {
            let model = LibraryModel(
                folderStore: libraryFolders,
                onApply: { [weak self] project, displayID in
                    guard let self, let display = self.controller?.displays.first(where: { $0.id == displayID }) else { return }
                    self.apply(project, to: display)
                },
                overrides: { [weak self] project in self?.propertyStore.overrides(for: project.folder) ?? [:] },
                onPropertyChange: { [weak self] project, name, value in
                    self?.propertyDidChange(project, name: name, value: value)
                },
                onPropertyReset: { [weak self] project in self?.propertiesDidReset(project) },
                hiddenElements: { [weak self] project in self?.hiddenElementStore.hidden(for: project.folder) ?? [] },
                onElementChange: { [weak self] project, id, hidden in
                    self?.elementVisibilityDidChange(project, id: id, hidden: hidden)
                },
                onDelete: { [weak self] project in self?.confirmDelete(project) },
                onUnsubscribe: { [weak self] project in self?.confirmUnsubscribe(project) },
                onOpenInWorkshop: { [weak self] id in self?.showWorkshop(item: id) },
                onUnsubscribeItem: { [weak self] id in self?.confirmUnsubscribe(itemID: id) },
                wallpaperOptions: { [weak self] project in
                    self?.optionsStore.options(for: project.folder) ?? WallpaperOptions()
                },
                onOptionsChange: { [weak self] project, options in self?.optionsDidChange(project, options: options) },
                onEnableAudio: { [weak self] in self?.setPlayAudio(true) },
                workshop: workshop)
            model.playsAudio = playAudio
            model.showsThumbnails = showsThumbnails
            window = LibraryWindowController(model: model)
            libraryWindow = window
            model.rescan()
        }
        if let displayID { window.model.selectedDisplay = displayID }
        refreshLibraryDisplays()
        if let project {
            window.model.selectedKey = LibraryModel.key(project.folder)
        } else {
            window.model.selectCurrentIfNeeded()
        }
        presentAppWindow(window)
    }

    /// 壁纸库里的显示器列表："设到"选中的那块拔掉了就换成第一块
    private func refreshLibraryDisplays() {
        guard let model = libraryWindow?.model else { return }
        let displays = controller?.displays ?? []
        model.displays = displays.map { display in
            let pixels = display.pixelSize
            return .init(
                id: display.id, name: display.name,
                aspect: pixels.height > 0 ? Double(pixels.width / pixels.height) : 16.0 / 9)
        }
        if let selected = model.selectedDisplay, !displays.contains(where: { $0.id == selected }) {
            model.selectedDisplay = nil
        }
        if model.selectedDisplay == nil { model.selectedDisplay = displays.first?.id }
        refreshLibraryCurrent()
    }

    /// 壁纸库里标出每块显示器当前用的项目
    private func refreshLibraryCurrent() {
        guard let model = libraryWindow?.model, let controller else { return }
        var current: [CGDirectDisplayID: String] = [:]
        for display in controller.displays {
            if case .project(let folder) = assignments.source(forDisplay: display.stableKey) {
                current[display.id] = LibraryModel.key(folder)
            }
        }
        model.currentFolders = current
    }

    /// 目前能放的是视频和网页项目；返回 nil 表示可以用
    private func unsupportedReason(for project: WallpaperProject) async -> String? {
        guard let entry = project.entry else { return String(localized: "project.json 没有写入口文件") }
        switch project.kind {
        case .video: return await VideoContent.unplayableReason(for: entry)
        case .web: return FileManager.default.fileExists(atPath: entry.path) ? nil : String(localized: "入口页面不存在")
        case .scene: return nil
        case .application: return String(localized: "应用程序类壁纸在 macOS 上无法运行")
        case .unknown: return String(localized: "认不出项目类型")
        }
    }

    @objc private func toggleSystemWallpaperSync() {
        syncSystemWallpaper.toggle()
        log.write("同步系统壁纸：\(syncSystemWallpaper ? "开启" : "关闭")")
        guard let controller else { return }
        if syncSystemWallpaper {
            controller.systemWallpaperSync = systemWallpaper
        } else {
            controller.systemWallpaperSync = nil
            systemWallpaper.restore(displays: controller.displays)
        }
    }

    /// 锁屏壁纸：跟随当前画面（默认）
    @objc private func useCurrentFrameForLockScreen() {
        lockScreenWallpaperPath = nil
        log.write("锁屏壁纸：跟随当前画面")
    }

    /// 锁屏壁纸：选一张固定的图片
    @objc private func chooseLockScreenWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "选一张锁屏时显示的图片。锁屏、调度中心等时候系统壁纸会换成它；桌面上的动态壁纸不受影响。")
        panel.prompt = String(localized: "用作锁屏壁纸")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lockScreenWallpaperPath = url.path
        log.write("锁屏壁纸：\(url.path)")
    }

    // MARK: - 壁纸设置

    /// 菜单里的"壁纸设置…"：打开壁纸库，右侧栏显示这块屏幕当前壁纸的设置
    @objc private func openProperties(_ sender: NSMenuItem) {
        guard let display = display(from: sender),
              case .project(let folder) = assignments.source(forDisplay: display.stableKey),
              let project = try? projects[Self.key(folder)]?.get()
        else { return }
        showLibrary(selecting: display.id, project: project)
    }

    /// 开发用：设置了 MACWALLPAPER_LIBRARY_SNAPSHOT（PNG 路径）时，启动后打开壁纸库，扫描完把窗口存成图片。
    /// 截图不加载缩略图：预览图里可能有不适合查看的内容，这里只检查布局
    private func snapshotLibraryIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["MACWALLPAPER_LIBRARY_SNAPSHOT"], libraryWindow == nil else { return }
        showLibrary(selecting: nil, showsThumbnails: false)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            // cacheDisplay 抓不到 SwiftUI 自己画的文字和网格，这里直接用 ImageRenderer 渲染同一个视图
            guard let model = self?.libraryWindow?.model else { return }
            // ImageRenderer 也画不了滚动视图（整窗渲染时卡片区是空的），卡片网格另外按普通网格渲染前 12 张
            let cards = Array(model.visibleProjects.prefix(12))
            let content = VStack(alignment: .leading, spacing: 0) {
                LibraryView(model: model, workshop: model.workshop).frame(width: 1200, height: 700)
                Grid(horizontalSpacing: 16, verticalSpacing: 18) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow {
                            ForEach(cards.indices.filter { $0 / 4 == row }, id: \.self) { index in
                                LibraryCard(
                                    project: cards[index], preview: nil, isCurrent: model.isCurrent(cards[index]),
                                    isSupported: model.isSupported(cards[index]), hidesTitle: true)
                                .frame(width: 200)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.white)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
            self?.log.write("壁纸库截图：\(path)（\(model.summary)）")
        }
    }

    /// 开发用：设置了 MACWALLPAPER_SETTINGS_SNAPSHOT（PNG 路径）时，项目读好后打开壁纸库、右侧栏显示主显示器壁纸的设置，
    /// 2 秒后把窗口内容存成图片（用窗口自己的绘制，不需要录屏权限；不加载缩略图、不显示标题）
    private func snapshotSettingsIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["MACWALLPAPER_SETTINGS_SNAPSHOT"],
              libraryWindow == nil, let display = controller?.displays.first,
              case .project(let folder) = assignments.source(forDisplay: display.stableKey),
              let project = try? projects[Self.key(folder)]?.get()
        else { return }
        showLibrary(selecting: display.id, showsThumbnails: false, project: project)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let view = self?.libraryWindow?.window?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            self?.log.write("设置窗口截图：\(path)")
        }
    }

    /// 正在显示这个项目的显示器
    private func displays(showing project: WallpaperProject) -> [DisplaySnapshot] {
        (controller?.displays ?? []).filter { display in
            if case .project(let folder) = assignments.source(forDisplay: display.stableKey) {
                return Self.key(folder) == Self.key(project.folder)
            }
            return false
        }
    }

    private func propertyDidChange(_ project: WallpaperProject, name: String, value: PropertyValue?) {
        propertyStore.set(value, for: name, in: project.folder)
        let current = value ?? project.properties.first { $0.name == name }?.defaultValue
        for display in displays(showing: project) {
            if let web = controller?.content(for: display.id) as? WebContent {
                // 网页壁纸自己有 applyUserProperties 回调，实时生效
                if let current, let change = project.userPropertyChangeJSON(name: name, value: current) {
                    web.applyUserProperties(change)
                }
            } else {
                scheduleSceneRebuild(project)
            }
        }
    }

    /// 壁纸自己的静音、音量（菜单栏的"播放壁纸声音"是总开关）；视频的显示方式也在这里设
    private func apply(_ options: WallpaperOptions, to content: any AudioPlaying) {
        content.setAudioEnabled(playAudio && !options.isMuted)
        content.setVolume(Float(options.volume))
        (content as? VideoContent)?.setDisplay(fitsWhole: options.fitsWhole, position: Float(options.clampedPosition))
    }

    private func optionsDidChange(_ project: WallpaperProject, options: WallpaperOptions) {
        let previous = optionsStore.options(for: project.folder)
        guard options != previous else { return }
        optionsStore.set(options, for: project.folder)
        if options.isMuted != previous.isMuted {
            log.write("「\(project.title)」\(options.isMuted ? "静音" : "取消静音")")
        }
        let displayChanged = options.fitsWhole != previous.fitsWhole || options.position != previous.position
        if displayChanged {
            log.write("「\(project.title)」显示方式：\(options.fitsWhole ? "完整显示" : String(format: "铺满，画面位置 %.2f", options.position))")
        }
        for display in displays(showing: project) {
            guard let content = controller?.content(for: display.id) else { continue }
            if let audible = content as? any AudioPlaying { apply(options, to: audible) }
            // 场景的取景在构建时定（特效缓冲、屏幕投影都按它算），换了显示方式要重建；拖滑块时等停手再建
            if displayChanged, content is SceneContent { scheduleSceneRebuild(project) }
        }
    }

    private func elementVisibilityDidChange(_ project: WallpaperProject, id: String, hidden: Bool) {
        hiddenElementStore.setHidden(hidden, element: id, in: project.folder)
        log.write("「\(project.title)」\(hidden ? "关掉" : "打开")显示内容 \(id)")
        if !displays(showing: project).isEmpty { scheduleSceneRebuild(project) }
    }

    private func propertiesDidReset(_ project: WallpaperProject) {
        propertyStore.reset(project.folder)
        hiddenElementStore.reset(project.folder)
        optionsStore.reset(project.folder)
        log.write("「\(project.title)」的设置恢复默认")
        for display in displays(showing: project) { controller?.reloadContent(for: display.id) }
    }

    /// 场景按属性值重建（着色器翻译有磁盘缓存，重建通常零点几秒）；拖动滑块时等停手 0.4 秒再做
    private func scheduleSceneRebuild(_ project: WallpaperProject) {
        let key = Self.key(project.folder)
        pendingSceneRebuilds[key]?.cancel()
        pendingSceneRebuilds[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.pendingSceneRebuilds[key] = nil
            for display in self.displays(showing: project) {
                self.controller?.reloadContent(for: display.id)
            }
        }
    }

    @objc private func toggleAudio() {
        setPlayAudio(!playAudio)
    }

    private func setPlayAudio(_ enabled: Bool) {
        playAudio = enabled
        log.write("壁纸声音：\(playAudio ? "播放" : "静音")")
        libraryWindow?.model.playsAudio = playAudio
        guard let controller else { return }
        for display in controller.displays {
            guard let content = controller.content(for: display.id) as? any AudioPlaying else { continue }
            var options = WallpaperOptions()
            if case .project(let folder) = assignments.source(forDisplay: display.stableKey) {
                options = optionsStore.options(for: folder)
            }
            content.setAudioEnabled(playAudio && !options.isMuted)
        }
    }

    @objc private func toggleWebNetwork() {
        allowWebNetwork.toggle()
        log.write("网页壁纸联网：\(allowWebNetwork ? "允许" : "禁止")")
        guard let controller else { return }
        for display in controller.displays where controller.content(for: display.id) is WebContent {
            controller.reloadContent(for: display.id)
        }
    }

    /// 选 WE 自带素材：认得出是素材文件夹（或 WE 的安装目录）就拷进 ~/WallPort/Assets，拷完重新载入场景
    @objc private func chooseAssetsDirectory() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "选择从 Windows 上 Wallpaper Engine 安装目录拷来的 assets 文件夹（场景壁纸要用里面的着色器和贴图）")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard let source = WallpaperEngineAssets.locate(in: folder) else {
            showAlert(
                String(localized: "这不是 Wallpaper Engine 的 assets 文件夹"),
                detail: String(localized: "「\(folder.lastPathComponent)」里没有 shaders、materials 这些子文件夹。请选 Windows 上 Wallpaper Engine 安装目录（通常在 Steam\\steamapps\\common\\wallpaper_engine）里的 assets 文件夹。"))
            return
        }
        welcomeModel?.isImportingAssets = true
        log.write("WE 自带素材：从 \(source.path) 拷进 \(AppFolder.assets.path)")
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try WallpaperEngineAssets.install(from: source, to: AppFolder.assets)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            welcomeModel?.isImportingAssets = false
            if let failure {
                log.write("WE 自带素材：拷贝失败（\(failure)）")
                showAlert(String(localized: "没能拷贝 Wallpaper Engine 自带素材"), detail: failure)
                return
            }
            // 用统一文件夹里的那份（以前另外指定过的目录不再用）
            assetsDirectory = nil
            welcomeModel?.hasAssets = assetsDirectory != nil
            failedScenes = [:]
            log.write("WE 自带素材：已就绪")
            guard let controller else { return }
            for display in controller.displays where controller.content(for: display.id) is SceneContent {
                controller.reloadContent(for: display.id)
            }
        }
    }

    @objc private func useTestPattern(_ sender: NSMenuItem) {
        guard let display = display(from: sender) else { return }
        assignments.setSource(.testPattern, forDisplay: display.stableKey)
        log.write("显示器 \(display.id) 改用测试图案")
        controller?.reloadContent(for: display.id)
        refreshLibraryCurrent()
    }

    @objc private func selectLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = DesktopLevel(rawValue: raw)
        else { return }
        controller?.setLevel(level)
        AppFolder.settings.set(raw, forKey: Self.levelDefaultsKey)
    }

    @objc private func probeNow() {
        controller?.probeNow(reason: "手动")
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(log.fileURL)
    }

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}
