import AVFoundation
import Combine
import AppKit
import ImageIO
import SwiftUI
import WallpaperFormats
import WallpaperLibrary

/// 壁纸库窗口：左边列出壁纸文件夹里的全部项目（数量、类型、预览图），点一下就设为所选显示器的壁纸；
/// 右边是选中那张壁纸的设置（作者在 project.json 里声明的用户属性），改了立即生效。
/// 顶部可以切到"Steam 创意工坊"：浏览、订阅、下载都在这个窗口里，底部是登录状态、同步订阅和下载进度
@MainActor
final class LibraryWindowController: NSWindowController {
    let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: LibraryView(model: model, workshop: model.workshop)))
        window.title = String(localized: "壁纸库")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.isReleasedWhenClosed = false
        // 加了右侧设置栏以后窗口要更宽，换个名字，不沿用以前存下的窄窗口尺寸
        window.setFrameAutosaveName("LibraryWindowWithSettings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", scene = "场景", video = "视频", web = "网页"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .scene: String(localized: "场景")
            case .video: String(localized: "视频")
            case .web: String(localized: "网页")
            }
        }

        var kind: WallpaperProject.Kind? {
            switch self {
            case .all: nil
            case .scene: .scene
            case .video: .video
            case .web: .web
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case local = "本机壁纸", workshop = "Steam 创意工坊"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .local: String(localized: "本机壁纸")
            case .workshop: String(localized: "Steam 创意工坊")
            }
        }
    }

    @Published var mode: Mode = .local
    let workshop: WorkshopModel

    struct DisplayChoice: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        /// 屏幕像素的宽高比（壁纸设置里算"铺满会裁掉多少"）
        var aspect: Double = 16.0 / 9
    }

    /// 壁纸比例和屏幕不同时，铺满屏幕会裁掉的方向，以及还看得到多少（0–1）
    struct Crop: Equatable {
        enum Axis { case horizontal, vertical }
        let axis: Axis
        let visible: Double
    }

    @Published private(set) var projects: [WallpaperProject] = [] {
        didSet { refilter() }
    }
    @Published private(set) var isScanning = false
    /// 有一遍扫描正在跑；跑的时候又要求扫描时记下来，扫完再补一遍（见 `rescan`）
    private var scanRunning = false
    private var rescanPending = false
    @Published private(set) var folders: [URL] = []
    @Published var filter: Filter = .all {
        didSet { libraryFilter.kind = filter.kind }
    }
    /// 排序、分级、分辨率、搜索词（类型由 `filter` 带进来）
    /// 本机壁纸的筛选/排序：同样存起来，切换页面、重启 App 都记得
    @Published var libraryFilter = FilterDefaults.load(LocalLibraryFilter.self, key: "library") ?? LocalLibraryFilter() {
        didSet {
            guard libraryFilter != oldValue else { return }
            FilterDefaults.save(libraryFilter, key: "library")
            refilter()
        }
    }
    /// 从内容本身读出来的尺寸、占用空间、加入时间（后台读，见 `ProjectDetailsIndex`）
    @Published private(set) var details: [String: WallpaperProjectDetails] = [:] {
        didSet { refilter() }
    }
    /// 扫描时顺手取的加入时间（文件夹创建时间）：详情还没读完时"最近加入"按它排，刚下载的排在最前
    @Published private(set) var addedDates: [String: Date] = [:] {
        didSet { refilter() }
    }
    /// 筛选、排序后的列表。算好存起来：原来是每次重绘现算（几百个项目筛一遍再排序，一次重绘里还算两遍）
    @Published private(set) var visibleProjects: [WallpaperProject] = []
    private var detailsTask: Task<Void, Never>?
    @Published var displays: [DisplayChoice] = []
    @Published var selectedDisplay: CGDirectDisplayID?
    /// 显示器 → 正在用的项目文件夹（标出"当前"）
    @Published var currentFolders: [CGDirectDisplayID: String] = [:]
    /// 右侧设置栏显示的项目（文件夹键）；nil 表示还没选
    @Published var selectedKey: String?

    /// 截图检查布局时不加载缩略图、也不显示标题（预览图和标题里可能有不适合查看的内容）
    var showsThumbnails = true

    private let folderStore: LibraryFolderStore
    /// 分辨率 / 占用空间的缓存（测试里换成临时文件，不碰用户的缓存）
    private let detailsIndex: ProjectDetailsIndex
    let onApply: (WallpaperProject, CGDirectDisplayID) -> Void
    /// 这个项目用户改过的设置
    let overrides: (WallpaperProject) -> [String: PropertyValue]
    /// 设置里某一项改了（nil 表示恢复成默认值）
    let onPropertyChange: (WallpaperProject, String, PropertyValue?) -> Void
    /// 设置全部恢复默认
    let onPropertyReset: (WallpaperProject) -> Void
    /// 这个项目里用户关掉的内容（粒子、文字、特效）
    let hiddenElements: (WallpaperProject) -> Set<String>
    /// 某项内容关掉（true）或重新打开（false）
    let onElementChange: (WallpaperProject, String, Bool) -> Void
    /// 移到废纸篓（App 先问一句）。只用于用户自己导入的壁纸；从创意工坊下载的走 `onUnsubscribe`
    let onDelete: (WallpaperProject) -> Void
    /// 在 Steam 上取消订阅，并从本机移走（App 先问一句），用于从创意工坊下载的壁纸
    let onUnsubscribe: (WallpaperProject) -> Void
    /// 创意工坊下载目录（现在的，以及 M7 时 SteamCMD 下到的地方）：在这里面的项目是从创意工坊下载的
    var workshopDownloads: [URL] { Workshop.downloadDirectories }
    /// 在创意工坊里选中这个条目（参数是创意工坊编号）
    let onOpenInWorkshop: (String) -> Void
    /// 创意工坊页里点"取消订阅"（参数是编号；本机有就一并移走）
    let onUnsubscribeItem: (String) -> Void
    /// 场景里可以关掉的内容、有没有声音对象，按项目缓存（场景包只读一次，设置栏每次刷新都读也没必要）
    private var sceneCache: [String: (elements: [SceneElement], hasSound: Bool)] = [:]
    /// 这个壁纸自己的播放选项（静音、音量、显示方式）
    let wallpaperOptions: (WallpaperProject) -> WallpaperOptions
    /// 播放选项改了
    let onOptionsChange: (WallpaperProject, WallpaperOptions) -> Void
    /// 菜单栏的"播放壁纸声音"开着吗（总开关；关着时设置栏里提示一句）
    @Published var playsAudio = false
    /// 设置栏里点"打开"：把总开关打开
    let onEnableAudio: () -> Void
    /// 视频有没有音轨（后台读；场景的记在 `sceneCache` 里，网页一律当作可能有）。
    /// 设置栏的 body 里会查它，所以缓存不是 @Published（body 里改发布的值 SwiftUI 会警告）；
    /// 视频读完以后改 `audioVersion` 让设置栏刷新
    private var audioCache: [String: Bool] = [:]
    private var audioChecks: Set<String> = []
    @Published private(set) var audioVersion = 0

    init(
        folderStore: LibraryFolderStore, onApply: @escaping (WallpaperProject, CGDirectDisplayID) -> Void,
        overrides: @escaping (WallpaperProject) -> [String: PropertyValue],
        onPropertyChange: @escaping (WallpaperProject, String, PropertyValue?) -> Void,
        onPropertyReset: @escaping (WallpaperProject) -> Void,
        hiddenElements: @escaping (WallpaperProject) -> Set<String>,
        onElementChange: @escaping (WallpaperProject, String, Bool) -> Void,
        onDelete: @escaping (WallpaperProject) -> Void,
        onUnsubscribe: @escaping (WallpaperProject) -> Void,
        onOpenInWorkshop: @escaping (String) -> Void,
        onUnsubscribeItem: @escaping (String) -> Void,
        wallpaperOptions: @escaping (WallpaperProject) -> WallpaperOptions = { _ in WallpaperOptions() },
        onOptionsChange: @escaping (WallpaperProject, WallpaperOptions) -> Void = { _, _ in },
        onEnableAudio: @escaping () -> Void = {},
        workshop: WorkshopModel,
        detailsIndex: ProjectDetailsIndex = .shared
    ) {
        self.wallpaperOptions = wallpaperOptions
        self.onOptionsChange = onOptionsChange
        self.onEnableAudio = onEnableAudio
        self.folderStore = folderStore
        self.detailsIndex = detailsIndex
        self.onApply = onApply
        self.overrides = overrides
        self.onPropertyChange = onPropertyChange
        self.onPropertyReset = onPropertyReset
        self.hiddenElements = hiddenElements
        self.onElementChange = onElementChange
        self.onDelete = onDelete
        self.onUnsubscribe = onUnsubscribe
        self.onOpenInWorkshop = onOpenInWorkshop
        self.onUnsubscribeItem = onUnsubscribeItem
        self.workshop = workshop
        // 类型选择器跟着存下来的筛选走（否则重启后列表只剩视频，选择器却停在"全部"，再点"全部"也没反应）
        let savedFilter = Filter.allCases.first { $0.kind == libraryFilter.kind }
        filter = savedFilter ?? .all
        if savedFilter == nil { libraryFilter.kind = nil }
        // 订阅时间读到或者变了（启动后连上 Steam、同步订阅、点订阅）：重新排一次
        subscriptionWatch = workshop.$subscriptionDates.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refilter() }
        }
    }

    private var subscriptionWatch: AnyCancellable?

    /// 创意工坊里选中的条目在本机时，把它设成当前选中的项目（右边显示它的设置）
    func selectWorkshopItem(_ id: String) {
        guard let project = projects.first(where: { Workshop.itemID(ofProjectFolder: $0.folder) == id }) else { return }
        selectedKey = Self.key(project.folder)
    }

    /// 创意工坊里打开的条目在本机时，设为壁纸
    func applyWorkshopItem(_ id: String) {
        guard let project = projects.first(where: { Workshop.itemID(ofProjectFolder: $0.folder) == id }) else { return }
        selectedKey = Self.key(project.folder)
        apply(project)
    }

    /// 从创意工坊下载的（在创意工坊下载目录里）：删除换成"取消订阅"
    func isWorkshopDownload(_ project: WallpaperProject) -> Bool {
        let parent = Self.key(project.folder.deletingLastPathComponent())
        return workshopDownloads.contains { Self.key($0) == parent }
            && Workshop.itemID(ofProjectFolder: project.folder) != nil
    }

    /// 删除：自己导入的移到废纸篓，从创意工坊下载的在 Steam 上取消订阅
    func remove(_ project: WallpaperProject) {
        if isWorkshopDownload(project) { onUnsubscribe(project) } else { onDelete(project) }
    }

    /// 删掉以后把它从列表里拿掉、取消选中（不必等重新扫描）
    func forget(_ folder: URL) {
        let key = Self.key(folder)
        projects.removeAll { Self.key($0.folder) == key }
        workshop.updateLocalItems(from: projects)
        sceneCache[key] = nil
        if selectedKey == key { selectedKey = nil }
    }

    /// 场景里可以单独关掉的粒子、文字、特效；不是场景或者读不了包时是空的
    func elements(for project: WallpaperProject) -> [SceneElement] {
        guard project.kind == .scene else { return [] }
        return sceneInfo(project).elements
    }

    /// 读一次场景包：可以关掉的内容和有没有声音对象一起记下（设置栏两样都要）
    private func sceneInfo(_ project: WallpaperProject) -> (elements: [SceneElement], hasSound: Bool) {
        let key = Self.key(project.folder)
        if let cached = sceneCache[key] { return cached }
        let package = try? ScenePackage(contentsOf: project.folder.appendingPathComponent("scene.pkg"))
        let json = package?.contents(of: "scene.json")
        let info = (
            elements: json.map(SceneElements.list(sceneJSON:)) ?? [],
            hasSound: json.flatMap { try? SceneDescription(json: $0) }?.objects.contains { $0.sound != nil } ?? false)
        sceneCache[key] = info
        return info
    }

    static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }

    /// 一次换好几样（扫描完同时换列表和加入时间）时先不筛，换完再筛一遍
    private var batchingRefilter = false

    private func refilter() {
        guard !batchingRefilter else { return }
        let added = Self.addedDates(
            addedDates, projects: projects, subscriptionDates: workshop.subscriptionDates,
            isWorkshopDownload: isWorkshopDownload)
        let fresh = libraryFilter.apply(projects, details: details, added: added)
        if fresh != visibleProjects { visibleProjects = fresh }
    }

    /// "最近加入"用的时间：从创意工坊下载的按订阅时间（文件夹创建时间是下载时间，整批重新下载过就和订阅的
    /// 先后对不上了），其余的按文件夹创建时间
    nonisolated static func addedDates(
        _ created: [String: Date], projects: [WallpaperProject], subscriptionDates: [String: Date],
        isWorkshopDownload: (WallpaperProject) -> Bool
    ) -> [String: Date] {
        guard !subscriptionDates.isEmpty else { return created }
        var added = created
        for project in projects where isWorkshopDownload(project) {
            if let id = Workshop.itemID(ofProjectFolder: project.folder), let date = subscriptionDates[id] {
                added[project.folder.path] = date
            }
        }
        return added
    }

    /// 分辨率、占用空间、加入时间：先用缓存里的，缺的在后台读，读完一批刷新一次
    private func loadDetails(for projects: [WallpaperProject]) {
        detailsTask?.cancel()
        detailsTask = Task {
            let index = detailsIndex
            details.merge(await index.known(projects)) { _, new in new }
            await index.fill(projects) { batch in
                await MainActor.run { self.details.merge(batch) { _, new in new } }
            }
        }
    }

    /// 选了分辨率筛选、但还有项目的尺寸没读出来（这时它们暂时不显示）
    var isReadingDetails: Bool {
        !libraryFilter.resolutions.isEmpty && projects.contains { details[$0.folder.path] == nil }
    }

    var summary: String {
        guard !projects.isEmpty else { return isScanning ? String(localized: "正在扫描…") : String(localized: "壁纸文件夹里还没有项目") }
        let count = { (kind: WallpaperProject.Kind) in self.projects.filter { $0.kind == kind }.count }
        var parts = [
            String(localized: "场景 \(count(.scene))"), String(localized: "视频 \(count(.video))"),
            String(localized: "网页 \(count(.web))"),
        ]
        let others = projects.count - count(.scene) - count(.video) - count(.web)
        if others > 0 { parts.append(String(localized: "其它 \(others)")) }
        return String(localized: "共 \(projects.count) 个：\(parts.joined(separator: " · "))")
    }

    var selectedProject: WallpaperProject? {
        guard let selectedKey else { return nil }
        return projects.first { Self.key($0.folder) == selectedKey }
    }

    var selectedDisplayName: String? {
        let id = selectedDisplay ?? displays.first?.id
        return displays.first { $0.id == id }?.name
    }

    func isCurrent(_ project: WallpaperProject) -> Bool {
        guard let selectedDisplay else { return false }
        return currentFolders[selectedDisplay] == Self.key(project.folder)
    }

    /// 有哪块显示器正在放它（设置改了能马上看到效果）
    func isShownAnywhere(_ project: WallpaperProject) -> Bool {
        currentFolders.values.contains(Self.key(project.folder))
    }

    func isSelected(_ project: WallpaperProject) -> Bool {
        selectedKey == Self.key(project.folder)
    }

    /// macOS 上放不了的类型（应用程序类、认不出来的）
    func isSupported(_ project: WallpaperProject) -> Bool {
        project.kind == .scene || project.kind == .video || project.kind == .web
    }

    /// 设置能生效的类型：场景按属性重建，网页走 applyUserProperties；视频的属性暂时用不上
    func supportsSettings(_ project: WallpaperProject) -> Bool {
        project.kind == .scene || project.kind == .web || project.kind == .video
    }

    /// 这个壁纸有没有声音（决定设置栏里显不显示"声音"一节）
    func hasAudio(_ project: WallpaperProject) -> Bool {
        let key = Self.key(project.folder)
        if let known = audioCache[key] { return known }
        switch project.kind {
        case .web:
            return true
        case .scene:
            return sceneInfo(project).hasSound
        case .video:
            // 读音轨要异步：先当没有，读完了设置栏自己刷新
            guard let entry = project.entry, audioChecks.insert(key).inserted else { return false }
            Task { [weak self] in
                let tracks = try? await AVURLAsset(url: entry).loadTracks(withMediaType: .audio)
                guard let self else { return }
                self.audioCache[key] = !(tracks ?? []).isEmpty
                self.audioChecks.remove(key)
                self.audioVersion += 1
            }
            return false
        case .application, .unknown:
            return false
        }
    }

    /// 铺满当前选中的屏幕时会裁掉多少（场景按画布、视频按画面尺寸）；比例差不多（2% 以内）或者不适用时为 nil
    func crop(for project: WallpaperProject) -> Crop? {
        guard project.kind == .scene || project.kind == .video,
              let details = details[project.folder.path], !details.isDynamic,
              let width = details.width, let height = details.height, width > 0, height > 0
        else { return nil }
        let screen = displays.first { $0.id == (selectedDisplay ?? displays.first?.id) }?.aspect ?? 16.0 / 9
        let content = Double(width) / Double(height)
        guard abs(content / screen - 1) > 0.02 else { return nil }
        return content > screen
            ? Crop(axis: .horizontal, visible: screen / content) : Crop(axis: .vertical, visible: content / screen)
    }

    /// 设置栏里显示的当前值：项目默认值叠上用户改过的
    func propertyValues(for project: WallpaperProject) -> [String: PropertyValue] {
        project.propertyValues(overrides: overrides(project))
    }

    /// 点卡片：选中它（右边显示设置），还不是当前壁纸的话顺便设为壁纸
    func tap(_ project: WallpaperProject) {
        selectedKey = Self.key(project.folder)
        if !isCurrent(project) { apply(project) }
    }

    /// 还没选中任何项目时，选中所选显示器正在用的那张
    func selectCurrentIfNeeded() {
        guard selectedKey == nil, let display = selectedDisplay ?? displays.first?.id else { return }
        selectedKey = currentFolders[display]
    }

    /// 重新扫描壁纸文件夹。一次只扫一遍：扫的时候又要求扫（同步订阅时每下好一个就要求一次），
    /// 这遍扫完再补扫一遍——几遍同时跑的话，先开始、后结束的那遍会把刚下好的壁纸又盖掉
    func rescan() {
        folders = folderStore.folders
        isScanning = true
        guard !scanRunning else {
            rescanPending = true
            return
        }
        scanRunning = true
        let folders = self.folders
        Task {
            let (found, added) = await Task.detached { () -> ([WallpaperProject], [String: Date]) in
                let found = LibraryScanner.scan(folders: folders)
                var added: [String: Date] = [:]
                for project in found {
                    added[project.folder.path] = try? project.folder.resourceValues(forKeys: [.creationDateKey]).creationDate
                }
                return (found, added)
            }.value
            scanRunning = false
            // 两样一起换完再筛一遍（各自的 didSet 都会筛，先换的那次还对着旧列表）
            batchingRefilter = true
            addedDates = added
            projects = found
            batchingRefilter = false
            refilter()
            if rescanPending {
                rescanPending = false
                rescan()
            } else {
                isScanning = false
            }
            // 创意工坊页的"本机已有"直接用这次扫描的结果（不用再读一遍磁盘）
            workshop.updateLocalItems(from: found)
            loadDetails(for: found)
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "选择放壁纸项目的文件夹（里面每个子文件夹是一个含 project.json 的项目）")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        folderStore.add(folder)
        rescan()
    }

    func removeFolder(_ folder: URL) {
        folderStore.remove(folder)
        rescan()
    }

    /// 把项目设成某块显示器的壁纸。不传显示器就用"设到"里选中的那块（只有一块屏时就是它）
    func apply(_ project: WallpaperProject, to display: CGDirectDisplayID? = nil) {
        guard isSupported(project) else { return }
        guard let target = display ?? selectedDisplay ?? displays.first?.id else { return }
        // 从右键菜单设到某块屏时，把"设到"也切过去，界面上的状态和实际一致
        selectedDisplay = target
        onApply(project, target)
    }

    /// 这块显示器上现在放的就是它吗（菜单里标"当前"）
    func isCurrentOn(_ project: WallpaperProject, display: DisplayChoice) -> Bool {
        currentFolders[display.id] == Self.key(project.folder)
    }

    /// 菜单项标题：显示器名字 + 是否当前
    func menuTitle(for display: DisplayChoice, project: WallpaperProject) -> String {
        display.name + (isCurrentOn(project, display: display) ? String(localized: "（当前）") : "")
    }
}

/// 壁纸库窗口。两个页面、右侧栏、底栏、登录框各自观察自己用到的模型：
/// 原来整个窗口同时观察本机和创意工坊两个模型，工坊里加载一页、下载进度涨 1%、本机每解码一张缩略图，
/// 都会让整窗（包括隐藏着的另一页的整个网格）重算一遍，滚动时一卡一卡的
struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    /// 不在这里观察：工坊的变化只该让工坊自己的视图重算
    let workshop: WorkshopModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.mode) {
                    ForEach(LibraryModel.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            HStack(spacing: 0) {
                // 两个页面都留在视图树里，只切换可见性：这样来回切的时候列表的滚动位置、
                // 已经翻到第几页都还在，不用重新滑回刚才看的地方
                ZStack {
                    LocalLibraryBrowser(model: model)
                        .opacity(model.mode == .local ? 1 : 0)
                        .allowsHitTesting(model.mode == .local)
                        .disabled(model.mode != .local)
                    WorkshopGallery(model: workshop, library: model)
                        .opacity(model.mode == .workshop ? 1 : 0)
                        .allowsHitTesting(model.mode == .workshop)
                        .disabled(model.mode != .workshop)
                }
                .frame(minWidth: 520, maxWidth: .infinity)
                Divider()
                LibraryDetailColumn(library: model, workshop: workshop)
                    .frame(width: 340)
            }
            Divider()
            WorkshopStatusBar(model: workshop)
        }
        .frame(minWidth: 880, minHeight: 520)
        .modifier(SteamLoginSheetHost(workshop: workshop))
        // 真正切到创意工坊时才加载网格、没登录时弹登录框（工坊页一直在视图树里，不能靠它自己的 onAppear）
        .onAppear { if model.mode == .workshop { workshop.activate() } }
        .onChange(of: model.mode) { if model.mode == .workshop { workshop.activate() } }
    }
}

/// 登录框挂在这里：只有它观察创意工坊模型，工坊有变化时不连带整窗重算
private struct SteamLoginSheetHost: ViewModifier {
    @ObservedObject var workshop: WorkshopModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: $workshop.isShowingLogin) { SteamLoginSheet(model: workshop) }
    }
}

/// 右侧栏：本机壁纸的设置，或者创意工坊条目的详情。两个面板都留着，只切可见性（切回来时选中状态、滚动都还在）
private struct LibraryDetailColumn: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var workshop: WorkshopModel

    var body: some View {
        ZStack {
            LibrarySettingsPanel(model: library)
                .opacity(showsLibraryPanel ? 1 : 0)
                .allowsHitTesting(showsLibraryPanel)
                .disabled(!showsLibraryPanel)
            WorkshopItemPanel(model: workshop, library: library)
                .opacity(showsLibraryPanel ? 0 : 1)
                .allowsHitTesting(!showsLibraryPanel)
                .disabled(showsLibraryPanel)
        }
    }

    /// 右边显示"本机设置面板"的时机：本机壁纸页；或者工坊"我的订阅"里选中的恰好是本机已有的那张
    private var showsLibraryPanel: Bool {
        if library.mode == .local { return true }
        guard workshop.source == .subscriptions, let id = workshop.selectedID, workshop.isLocal(id) else {
            return false
        }
        return library.selectedProject.flatMap { Workshop.itemID(ofProjectFolder: $0.folder) } == id
    }
}

/// "本机壁纸"页：只观察本机模型
private struct LocalLibraryBrowser: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            // 左栏最窄 520：数量一行只放搜索框，类型和排序放下一行（和创意工坊页一样），
            // 否则"共 N 个：…"会被挤成竖着的好几行
            HStack(spacing: 12) {
                Text(model.summary).font(.headline).lineLimit(1).help(model.summary)
                if model.isScanning { ProgressView().controlSize(.small) }
                Spacer(minLength: 12)
                TextField("搜索标题", text: $model.libraryFilter.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 200)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(spacing: 12) {
                Picker("类型", selection: $model.filter) {
                    ForEach(LibraryModel.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("排序", selection: $model.libraryFilter.sort) {
                    ForEach(LocalLibraryFilter.Sort.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                if model.isReadingDetails {
                    ProgressView().controlSize(.small)
                    Text("正在读取分辨率…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            HStack {
                RatingToggles(ratings: $model.libraryFilter.ratings)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            ResolutionToggles(resolutions: $model.libraryFilter.resolutions)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            HStack(spacing: 12) {
                // 不论接了几块屏都留着"设到"：一块屏时也是它，接上新的显示器马上能选
                if model.displays.isEmpty {
                    Text("没找到显示器").foregroundStyle(.secondary)
                } else {
                    Picker("设到", selection: $model.selectedDisplay) {
                        ForEach(model.displays) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .frame(maxWidth: 260)
                }
                Spacer()
                Menu("壁纸文件夹（\(model.folders.count)）") {
                    ForEach(model.folders, id: \.self) { folder in
                        Menu(folder.path) {
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            Button("从壁纸库移除") { model.removeFolder(folder) }
                        }
                    }
                    Divider()
                    Button("添加文件夹…") { model.addFolder() }
                }
                .fixedSize()
                Button("重新扫描") { model.rescan() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if model.visibleProjects.isEmpty && !model.isScanning {
                VStack(spacing: 8) {
                    Text(model.projects.isEmpty ? "还没有壁纸" : "没有符合条件的壁纸").font(.title3)
                    if model.projects.isEmpty {
                        Text("用「壁纸文件夹 → 添加文件夹…」加入从 Windows 拷来的 Wallpaper Engine 项目文件夹")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], spacing: 18) {
                        ForEach(model.visibleProjects, id: \.folder) { project in
                            LibraryCard(
                                project: project, preview: model.showsThumbnails ? project.preview : nil,
                                isCurrent: model.isCurrent(project), isSupported: model.isSupported(project),
                                hidesTitle: !model.showsThumbnails, isSelected: model.isSelected(project))
                            .onTapGesture { model.tap(project) }
                            .contextMenu {
                                Button("设为壁纸") { model.apply(project) }.disabled(!model.isSupported(project))
                                // 每张壁纸都能单独指定放到哪块显示器（一块屏时也显示，接上新屏后直接可选）
                                Menu("设到显示器") {
                                    ForEach(model.displays) { display in
                                        Button(model.menuTitle(for: display, project: project)) {
                                            model.apply(project, to: display.id)
                                        }
                                    }
                                }
                                .disabled(!model.isSupported(project) || model.displays.isEmpty)
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) }
                                if let id = Workshop.itemID(ofProjectFolder: project.folder) {
                                    Button("在创意工坊中打开") { model.onOpenInWorkshop(id) }
                                }
                                Divider()
                                Button(model.isWorkshopDownload(project) ? "取消订阅…" : "移到废纸篓…", role: .destructive) {
                                    model.remove(project)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

/// 壁纸库右侧：选中那张壁纸的名字、状态和设置
struct LibrarySettingsPanel: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        if let project = model.selectedProject {
            VStack(alignment: .leading, spacing: 0) {
                header(project)
                    .padding(16)
                Divider()
                if !model.isSupported(project) {
                    placeholder("macOS 上放不了这种壁纸，也没有可以调整的设置。")
                } else if model.supportsSettings(project) {
                    // 换了项目要用新项目的值重新建（PropertiesView 的当前值存在它自己的 State 里）
                    PropertiesView(
                        project: project, values: model.propertyValues(for: project),
                        elements: model.elements(for: project), hidden: model.hiddenElements(project),
                        options: model.wallpaperOptions(project),
                        playback: PlaybackOptionsContext(
                            hasAudio: model.hasAudio(project), playsAudio: model.playsAudio,
                            crop: model.crop(for: project), onEnableAudio: model.onEnableAudio),
                        onChange: { name, value in model.onPropertyChange(project, name, value) },
                        onElementChange: { id, hidden in model.onElementChange(project, id, hidden) },
                        onOptionsChange: { options in model.onOptionsChange(project, options) },
                        onReset: { model.onPropertyReset(project) })
                    .id(LibraryModel.key(project.folder))
                }
            }
        } else {
            placeholder("点一张壁纸，它的设置会显示在这里。")
        }
    }

    /// 右侧栏只有 340 宽：这里每一行都不能比它宽。一行撑宽了，整栏会往两边撑出去——右边的按钮被切到窗口外，
    /// 左边盖住壁纸列表的搜索框、"重新扫描"和滚动条
    private func header(_ project: WallpaperProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 图标按钮跟标题放一行（标题最多三行），不跟"设为壁纸"挤
            HStack(alignment: .top, spacing: 6) {
                Text(model.showsThumbnails ? project.title : String(localized: "（截图时不显示标题）"))
                    .font(.title3.bold())
                    .lineLimit(3)
                    .help(project.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                iconButtons(project)
            }
            HStack(spacing: 8) {
                if model.isCurrent(project) {
                    Label("当前壁纸", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                } else if model.isSupported(project) {
                    // 显示器名字长、带上它放不下时退成"设为壁纸"（设到哪块看上面的"设到"）
                    ViewThatFits(in: .horizontal) {
                        applyMenu(project, title: model.selectedDisplayName.map { String(localized: "设为「\($0)」的壁纸") } ?? String(localized: "设为壁纸"))
                        applyMenu(project, title: String(localized: "设为壁纸"))
                    }
                }
                Spacer(minLength: 0)
                // 已经是这块屏的壁纸时，也能再设到别的屏上
                if model.isSupported(project), model.isCurrent(project), model.displays.count > 1 {
                    Menu("设到其它显示器") { displayItems(project) }
                        .fixedSize()
                }
            }
            if model.isWorkshopDownload(project) {
                HStack {
                    Label("从 Steam 创意工坊订阅", systemImage: "cloud").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消订阅", role: .destructive) { model.remove(project) }
                        .help("在 Steam 上取消订阅，并把它从这台 Mac 移除")
                }
            }
            if model.supportsSettings(project), !model.isShownAnywhere(project) {
                Text("这张壁纸现在没有在哪块屏幕上显示；改好的设置会在设为壁纸后生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 点按钮本身：设到"设到"里选中的那块（一下就好）；点右边的箭头挑别的显示器
    private func applyMenu(_ project: WallpaperProject, title: String) -> some View {
        Menu {
            displayItems(project)
        } label: {
            Text(title)
        } primaryAction: {
            model.apply(project)
        }
        .fixedSize()
        .disabled(model.displays.isEmpty)
    }

    private func displayItems(_ project: WallpaperProject) -> some View {
        ForEach(model.displays) { display in
            Button(model.menuTitle(for: display, project: project)) {
                model.apply(project, to: display.id)
            }
        }
    }

    @ViewBuilder
    private func iconButtons(_ project: WallpaperProject) -> some View {
        HStack(spacing: 4) {
            if let id = Workshop.itemID(ofProjectFolder: project.folder) {
                Button {
                    model.onOpenInWorkshop(id)
                } label: {
                    Image(systemName: "globe")
                }
                .help("在创意工坊中打开（订阅、取消订阅、看评论）")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([project.folder])
            } label: {
                Image(systemName: "folder")
            }
            .help("在访达中显示")
            if !model.isWorkshopDownload(project) {
                Button {
                    model.remove(project)
                } label: {
                    Image(systemName: "trash")
                }
                .help("移到废纸篓")
            }
        }
        .fixedSize()
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibraryCard: View {
    let project: WallpaperProject
    /// 预览图文件；nil 时只显示类型图标（截图检查布局时不加载预览图）
    let preview: URL?
    let isCurrent: Bool
    let isSupported: Bool
    var hidesTitle = false
    /// 右侧设置栏正在显示它
    var isSelected = false

    private var kindLabel: String {
        switch project.kind {
        case .scene: return String(localized: "场景")
        case .video: return String(localized: "视频")
        case .web: return String(localized: "网页")
        case .application: return String(localized: "应用（不支持）")
        case .unknown: return String(localized: "未知类型")
        }
    }

    private var symbol: String {
        switch project.kind {
        case .scene: return "square.stack.3d.up"
        case .video: return "film"
        case .web: return "globe"
        default: return "questionmark.square"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImage(url: preview, placeholder: symbol)
            .frame(height: 118)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 3))
            HStack(spacing: 6) {
                Text(kindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                if isCurrent { Text("当前").font(.caption2).foregroundStyle(Color.accentColor) }
            }
            Text(hidesTitle ? String(localized: "（截图时不显示标题）") : project.title).font(.callout).lineLimit(2).help(project.title)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear))
        .opacity(isSupported ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}
