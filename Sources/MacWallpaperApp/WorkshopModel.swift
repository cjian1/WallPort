import AppKit
import CryptoKit
import DesktopHost
import SwiftUI
import WallpaperLibrary

/// 壁纸库里的"Steam 创意工坊"：原生的壁纸网格（浏览 / 我的订阅）、一次登录、订阅 / 取消订阅、下载、同步订阅。
///
/// 数据来源：
/// - 浏览：Steam 公开的浏览页读条目编号 + `GetPublishedFileDetails` 取详情（都不用登录，见 `WorkshopCatalog`）；
/// - 登录：账号密码或手机扫码，整条认证会话走 Steam 客户端协议（CM，`WorkshopNative`）。密码只在登录过程中
///   留在内存里，不存盘；会话（refresh token）存本机加密文件（`SteamCMSessionStore`，不碰钥匙串），
///   App 启动时读出来直接当作已登录，后台连 CM——Steam 不认这个会话了才要重新登录；
/// - 订阅 / 取消订阅 / 我的订阅：同一个会话走 CM（`PublishedFile.Subscribe/Unsubscribe/GetUserFiles`）；
/// - 下载：同一个会话走 CM（条目详情 → depot 密钥 → 清单 → 分块拼装），不需要 SteamCMD。
@MainActor
final class WorkshopModel: NSObject, ObservableObject {
    enum ItemState: Equatable {
        case waiting, downloading, done, failed(String)
    }

    struct QueueItem: Identifiable, Equatable {
        let id: String
        var state: ItemState
    }

    enum Source: String, CaseIterable, Identifiable {
        case browse = "浏览", subscriptions = "我的订阅"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .browse: String(localized: "浏览")
            case .subscriptions: String(localized: "我的订阅")
            }
        }
    }

    /// 登录进行到哪一步（登录框里显示）
    enum LoginStep: Equatable {
        case idle
        case signingIn
        /// 要填验证码：邮件里的（email）或者手机令牌上的
        case needsCode(email: Bool)
        /// 在手机 Steam App 上点「批准」；`canEnterCode` 时也可以直接填令牌上的验证码
        case waitingForPhone(canEnterCode: Bool)
        /// 扫码登录：二维码显示在登录框里
        case waitingForScan
        /// 验证码交上去了，等 Steam 回应
        case checkingCode
        case failed(String)
    }

    // MARK: 壁纸网格

    /// 切换"浏览 / 我的订阅"：各自的列表、加载到第几页、选中的和滚到的位置都留着，切回来原样恢复
    @Published var source: Source = .browse {
        didSet { if source != oldValue { switchGallery(from: oldValue) } }
    }
    /// 切回来时视图要滚到的条目（视图滚完就清掉）
    @Published var scrollTarget: String?
    /// 浏览的筛选（类型/排序/分级/分辨率）：改了就存起来，切换页面、重启 App 都记得
    /// 没确认过年满 18 岁时，存下的筛选里的家长指导级 / 限制级不算（见 `AgeConfirmation`）
    @Published var query = AgeConfirmation.restricted(
        FilterDefaults.load(WorkshopQuery.self, key: "workshop.browse") ?? WorkshopQuery()) {
        didSet {
            if query != oldValue {
                FilterDefaults.save(query, key: "workshop.browse")
                reloadGallery()
            }
        }
    }
    @Published private(set) var items: [WorkshopItem] = []
    @Published private(set) var isLoadingPage = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var loadError: String?
    @Published var selectedID: String?
    /// 知道的订阅（登录后读过订阅列表，或者在这里订阅 / 取消订阅过）。按账号存在本机：
    /// 启动后马上就有"已订阅"标记和"取消订阅"按钮，不用等连上 Steam 读完列表（原来要等几秒才冒出来）
    @Published private(set) var subscribedIDs: Set<String> = [] {
        didSet { if subscribedIDs != oldValue { saveSubscribedIDs() } }
    }
    /// 编号 → 在 Steam 上订阅的时间：读订阅列表时记下（列表里每一项都带），在 App 里点订阅时记成当时。
    /// 按账号存在设置里。本机壁纸库的"最近加入"用它排创意工坊下的壁纸——文件夹的创建时间是下载时间，
    /// 整批重新下载过（换下载目录、同步时按"最近订阅的先下"）就和订阅的先后对不上了
    @Published private(set) var subscriptionDates: [String: Date] = [:] {
        didSet { if subscriptionDates != oldValue { saveSubscriptionDates() } }
    }
    /// 正在 Steam 上改订阅状态的条目：界面已经先变了，回来失败再改回去
    @Published private(set) var pendingSubscriptions: Set<String> = []
    /// "我的订阅"的筛选和排序（在本机做，改了不用重新问 Steam）
    @Published var subscriptionFilter =
        FilterDefaults.load(WorkshopSubscriptionFilter.self, key: "workshop.subscriptions")
            ?? WorkshopSubscriptionFilter() {
        didSet {
            if subscriptionFilter != oldValue {
                FilterDefaults.save(subscriptionFilter, key: "workshop.subscriptions")
                applySubscriptionFilter()
            }
        }
    }
    private var nextPage = 1
    private var galleryGeneration = 0
    /// 网格里现在是上次存下来的第一页（见 `GalleryCache`），新的一页回来要整个换掉而不是接在后面
    private var showingCachedPage = false
    /// "我的订阅"的全部条目（一次读全；nil 表示还没读）
    private var allSubscriptions: [WorkshopItem]?
    /// 切走时留下的网格状态
    private struct GallerySnapshot {
        var items: [WorkshopItem]
        var nextPage: Int
        var reachedEnd: Bool
        var anchor: String?
        var selectedID: String?
    }
    private var snapshots: [Source: GallerySnapshot] = [:]
    /// 网格里现在看得见的卡片（视图报告；切走时取最上面那张记下来）
    private var visibleIDs: Set<String> = []
    /// 本机壁纸库里已经有的条目编号。卡片每次重绘都要问"本机有没有"，原来每问一次就读一遍磁盘
    /// （几百个条目约 6 毫秒，一屏几十张卡片 = 每次重绘 0.2～0.4 秒，滚动就一卡一卡的）；
    /// 现在缓存起来，壁纸库扫描完、下载完、删除后更新
    @Published private(set) var localIDs: Set<String> = []
    private var localScanGeneration = 0

    // MARK: 登录

    /// 登录着的会话（本机加密文件里读出来的，或者刚登录拿到的）
    @Published private(set) var session: SteamCMSession?
    @Published private(set) var loginStep: LoginStep = .idle
    /// 验证码不对之类，显示在验证码输入框下面
    @Published private(set) var codeError: String?
    @Published var isShowingLogin = false
    @Published private(set) var loginReason: String?
    /// 扫码登录：把二维码画出来给用户扫（模型只负责出图，界面负责显示）
    @Published private(set) var qrCodeImage: Data?
    @Published private(set) var qrChallengeURL: String?

    // MARK: 下载

    @Published private(set) var queue: [QueueItem] = []
    /// 正在下载的条目下到多少了（0…1）；还在准备（取清单）时没有
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var isDownloading = false
    /// 用户点了「暂停」：正在下的那件停下、放回等待，队列不往下走，点「继续」再接着下
    @Published private(set) var isPaused = false
    @Published private(set) var isSyncing = false
    @Published private(set) var message: String?

    /// 从创意工坊下载的壁纸放在这里（每件一个以编号命名的文件夹）
    let downloadDirectory = Workshop.downloadDirectory
    /// 正在跑的下载（暂停时取消它）
    private var downloadTask: Task<Void, Never>?
    private let catalog = WorkshopCatalog()
    /// 原生会话：登录、订阅、下载都走它
    private let native = WorkshopNative()
    private let sessionStore = SteamCMSessionStore()
    /// 壁纸库的文件夹（在后台扫描本机已有的条目用）
    private let libraryFolders: () -> [URL]
    private let onDownloaded: (URL) -> Void
    private let onUnsubscribed: ([URL]) -> Void
    /// 写进 App 的日志（~/WallPort/Logs/desktop.log）；只记事件，不记令牌、密码
    private let log: (String) -> Void
    private var didStart = false
    private var didPromptLogin = false
    /// 账号密码登录进行中时的状态（交验证码要用）
    private var passwordLogin: WorkshopNative.PasswordPending?
    /// 当前这次登录（取消 / 重新开始时作废）
    private var loginTask: Task<Void, Never>?
    /// 登录的编号：取消或重新开始后，旧的那次登录回来的结果一律不用
    private var loginAttempt = 0
    /// 登录好以后要接着做的事（例如刚才因为没登录而没做成的下载）
    private var afterLogin: [() -> Void] = []

    /// 上次登录用的账户名称（登录框里预先填好）。键名沿用 M7 的，老用户的记录不丢
    static let lastAccountKey = "steamcmdAccount"

    init(
        libraryFolders: @escaping () -> [URL], onDownloaded: @escaping (URL) -> Void,
        onUnsubscribed: @escaping ([URL]) -> Void, log: @escaping (String) -> Void = { _ in },
        usesCustomAssets: @escaping () -> Bool = { false }, onEngineAssetsInstalled: @escaping () -> Void = {}
    ) {
        self.libraryFolders = libraryFolders
        self.onDownloaded = onDownloaded
        self.onUnsubscribed = onUnsubscribed
        self.log = log
        self.usesCustomAssets = usesCustomAssets
        self.onEngineAssetsInstalled = onEngineAssetsInstalled
        super.init()
    }

    // MARK: - Wallpaper Engine 自带素材

    /// 从 Steam 下好的 WE 自带素材是哪个版本（"<depot>:<清单编号>"，存在设置里）。没有表示没下过：
    /// 要么还没有素材，要么是用户自己导入的
    static let engineAssetsVersionKey = "engineAssetsVersion"
    /// 正在从 Steam 下载 WE 自带素材时的进度（0…1）；nil 表示没在下
    @Published private(set) var engineAssetsProgress: Double?
    private var engineAssetsTask: Task<Void, Never>?
    /// 设置里另外指定了素材目录（迁移前指到外接盘上 WE 的安装目录之类）：不自动下载
    private let usesCustomAssets: () -> Bool
    /// 下好了：App 换用新素材、重建场景
    private let onEngineAssetsInstalled: () -> Void

    /// 用登录的账号从 Steam 下载 WE 自带素材（账号要拥有 Wallpaper Engine），装进 `~/WallPort/Assets`。
    /// 登录后自动调：本机还没有素材，或者之前是从 Steam 下的、Steam 上又更新了，才在后台下；
    /// 用户自己导入的（没记下版本）不动。`force`（菜单里点"从 Steam 下载"）时不管有没有都重新下
    func syncEngineAssets(force: Bool = false) {
        guard engineAssetsTask == nil, AppFolder.isActive else { return }
        guard session != nil else {
            if force {
                showLogin(reason: String(localized: "从 Steam 下载 Wallpaper Engine 自带素材要先登录。")) {
                    self.syncEngineAssets(force: true)
                }
            }
            return
        }
        let target = AppFolder.assets
        let installed = AppFolder.settings.string(forKey: Self.engineAssetsVersionKey)
        let exists = FileManager.default.fileExists(atPath: target.path)
        if !force, usesCustomAssets() || (exists && installed == nil) { return }
        engineAssetsTask = Task {
            defer {
                engineAssetsTask = nil
                engineAssetsProgress = nil
            }
            do {
                if !force, exists {
                    let latest = try await withSession { try await self.native.engineAssetsVersion(session: $0) }
                    guard latest != installed else { return }
                    log("WE 自带素材：Steam 上有新版本 \(latest)（本机 \(installed ?? "无")），重新下载")
                }
                engineAssetsProgress = 0
                log("WE 自带素材：开始用账号从 Steam 下载")
                let throttle = ProgressThrottle()
                let version = try await withSession { session in
                    try await self.native.downloadEngineAssets(session: session, to: target) { fraction in
                        guard throttle.shouldReport(fraction) else { return }
                        Task { @MainActor in if self.engineAssetsTask != nil { self.engineAssetsProgress = fraction } }
                    }
                }
                AppFolder.settings.set(version, forKey: Self.engineAssetsVersionKey)
                log("WE 自带素材：已从 Steam 下载（\(version)）")
                message = String(localized: "Wallpaper Engine 自带素材已经从 Steam 下载好，场景壁纸会和原版一样。")
                onEngineAssetsInstalled()
            } catch is CancellationError {
                log("WE 自带素材：下载取消")
            } catch WorkshopNative.Failure.notLoggedIn {
                log("WE 自带素材：登录过期，没有下载")
            } catch {
                log("WE 自带素材：下载失败（\(error.localizedDescription)）")
                // 自动更新失败不打扰（旧的那份照样能用）；第一次下、或者用户点的，告诉一声
                if force || !exists {
                    message = String(localized: "没能从 Steam 下载 Wallpaper Engine 自带素材（\(error.localizedDescription)），现在用壁坞自带的兼容素材。")
                }
            }
        }
    }

    /// 下载进度每涨 1% 才报一次（素材是几千个小文件，每个文件都报的话界面要刷几千次）
    private final class ProgressThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1

        func shouldReport(_ fraction: Double) -> Bool {
            let percent = Int(fraction * 100)
            return lock.withLock {
                guard percent > last else { return false }
                last = percent
                return true
            }
        }
    }

    var isLoggedIn: Bool { session != nil }
    var accountName: String? { session?.accountName }

    /// 用户点开铃铛看过了，清掉那条提示
    func clearMessage() {
        message = nil
    }

    /// 偶发失败（刚唤醒、换网络、CM 连接被回收）自动重试一次；登录过期直接抛出去，
    /// 交给上面走"请重新登录"那条路
    private static func withRetry<T>(
        attempts: Int = 2, _ body: () async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?
        for attempt in 1...max(1, attempts) {
            do {
                return try await body()
            } catch WorkshopNative.Failure.notLoggedIn {
                throw WorkshopNative.Failure.notLoggedIn
            } catch {
                lastError = error
                if attempt < attempts { try? await Task.sleep(for: .seconds(1.5)) }
            }
        }
        throw lastError ?? WorkshopNative.Failure.failed(String(localized: "失败"))
    }

    /// App 启动时调用（重复调用没关系）：本机存过会话就直接当作已登录，后台连上 CM。
    /// 连不上（没网）时会话照样留着，之后的操作自己重连；Steam 明确不认这个会话了才要重新登录
    func start() {
        guard !didStart else { return }
        didStart = true
        guard let stored = sessionStore.load() else {
            log("创意工坊：本机没有存过登录会话")
            return
        }
        session = stored
        subscribedIDs = Set(AppFolder.settings.stringArray(forKey: Self.subscribedIDsKey(stored.accountName)) ?? [])
        subscriptionDates = Self.loadSubscriptionDates(stored.accountName)
        Task {
            switch await native.restore(stored) {
            case .connected:
                log("创意工坊：用存着的会话登上 Steam（账号 \(stored.accountName)）")
                refreshSubscribedIDs()
                syncEngineAssets()
            case .expired:
                if session?.refreshToken == stored.refreshToken { sessionExpired(reason: "启动时 Steam 不认存着的会话") }
            case .unreachable(let reason):
                log("创意工坊：启动时连不上 Steam（\(reason)），会话留着，之后的操作会重连")
            }
        }
    }

    /// 切到"创意工坊"时调用：第一次加载壁纸网格；没登录就弹一次登录框（关掉以后不再自动弹）
    func activate() {
        start()
        refreshLocalItems()
        // 先把和 Steam 的连接接好（睡眠唤醒、换网络后连接多半已经断了）：
        // 用户接着点订阅 / 取消订阅时就不用再等重连登录
        if let session { Task { _ = await native.restore(session) } }
        if items.isEmpty, !isLoadingPage, loadError == nil { reloadGallery() }
        if !didPromptLogin, !isLoggedIn {
            didPromptLogin = true
            showLogin(reason: nil)
        }
        if session != nil, subscribedIDs.isEmpty { refreshSubscribedIDs() }
    }

    func isLocal(_ id: String) -> Bool { localIDs.contains(id) }

    /// 在后台重新扫一遍本机已有的条目（壁纸库窗口没开、没有扫描结果可用的时候）
    func refreshLocalItems() {
        Task { _ = await scanLocalItems() }
    }

    /// 壁纸库刚扫描完：直接用扫描结果，不用再读一遍磁盘
    func updateLocalItems(from projects: [WallpaperProject]) {
        localScanGeneration += 1
        let ids = Set(projects.compactMap { Workshop.itemID(ofProjectFolder: $0.folder) })
        if ids != localIDs { localIDs = ids }
    }

    /// 读磁盘拿到最新的本机条目（后台线程），顺便更新缓存
    private func scanLocalItems() async -> Set<String> {
        localScanGeneration += 1
        let generation = localScanGeneration
        let folders = libraryFolders()
        let ids = await Task.detached(priority: .userInitiated) { Workshop.localItemIDs(in: folders) }.value
        if generation == localScanGeneration, ids != localIDs { localIDs = ids }
        return ids
    }
    func state(of id: String) -> ItemState? { queue.first { $0.id == id }?.state }
    var selectedItem: WorkshopItem? { items.first { $0.id == selectedID } }

    // MARK: - 壁纸网格

    func reloadGallery() {
        galleryGeneration += 1
        items = []
        nextPage = 1
        reachedEnd = false
        loadError = nil
        isLoadingPage = false
        showingCachedPage = false
        if source == .subscriptions { allSubscriptions = nil }
        // 先摆上次看到的（打开就有东西看，预览图也多半在磁盘缓存里），同时去 Steam 取新的，回来再换掉
        if let cached = GalleryCache.load(cacheKey) {
            items = source == .subscriptions ? subscriptionFilter.apply(cached) : cached.filter(query.accepts)
            showingCachedPage = !items.isEmpty
        }
        loadMore()
    }

    /// 上次看到的第一页存在哪：浏览按筛选条件（排序、搜索、类型、分级、分辨率都会改变服务器给的结果），
    /// 我的订阅按账号
    private var cacheKey: String? {
        switch source {
        case .browse:
            return GalleryCache.canonicalJSON(query).map { "browse-" + GalleryCache.hash($0) }
        case .subscriptions:
            return session.map { "subscriptions-" + GalleryCache.hash(Data($0.accountName.utf8)) }
        }
    }

    /// 视图报告卡片进出可见区域
    func noteCard(_ id: String, visible: Bool) {
        if visible { visibleIDs.insert(id) } else { visibleIDs.remove(id) }
    }

    private func switchGallery(from old: Source) {
        snapshots[old] = GallerySnapshot(
            items: items, nextPage: nextPage, reachedEnd: reachedEnd && loadError == nil,
            anchor: items.first { visibleIDs.contains($0.id) }?.id, selectedID: selectedID)
        visibleIDs = []
        galleryGeneration += 1
        isLoadingPage = false
        loadError = nil
        guard let saved = snapshots[source], !saved.items.isEmpty,
              source == .browse || allSubscriptions != nil
        else {
            selectedID = nil
            reloadGallery()
            return
        }
        nextPage = saved.nextPage
        reachedEnd = saved.reachedEnd
        // 我的订阅按最新的列表重排一遍（期间在浏览里订阅 / 取消订阅的要算进去）
        items = source == .subscriptions ? subscriptionFilter.apply(allSubscriptions ?? []) : saved.items
        selectedID = saved.selectedID
        scrollTarget = saved.anchor
    }

    /// 在别处（浏览列表、切走前的列表）见过的条目
    private func knownItem(_ id: String) -> WorkshopItem? {
        items.first { $0.id == id } ?? snapshots.values.lazy.compactMap { $0.items.first { $0.id == id } }.first
    }

    func showSubscriptions() {
        if source == .subscriptions { reloadGallery() } else { source = .subscriptions }
    }

    /// 滚到底时加载下一页
    func loadMore() {
        guard !isLoadingPage, !reachedEnd else { return }
        let generation = galleryGeneration
        let isFirstPage = nextPage == 1
        isLoadingPage = true
        Task {
            do {
                let (fresh, end) = try await fetchPage()
                guard generation == galleryGeneration else { return }
                if showingCachedPage {
                    showingCachedPage = false
                    items = fresh
                } else {
                    let known = Set(items.map(\.id))
                    items += fresh.filter { !known.contains($0.id) }
                }
                reachedEnd = end
                if isFirstPage, let key = cacheKey {
                    GalleryCache.save(source == .subscriptions ? allSubscriptions ?? fresh : fresh, key: key)
                }
            } catch {
                guard generation == galleryGeneration else { return }
                loadError = error.localizedDescription
                reachedEnd = true
            }
            isLoadingPage = false
        }
    }

    private func fetchPage() async throws -> ([WorkshopItem], Bool) {
        switch source {
        case .browse:
            // 分级、类型是回来再筛的，一页可能全被筛掉：最多连着往后翻三页
            var collected: [WorkshopItem] = []
            var reachedEnd = false
            let first = nextPage
            while collected.isEmpty, !reachedEnd, nextPage < first + 3 {
                let page = try await catalog.page(nextPage, of: query)
                nextPage += 1
                collected += page.items
                reachedEnd = page.reachedEnd
            }
            return (collected, reachedEnd)
        case .subscriptions:
            guard isLoggedIn else {
                showLogin(reason: String(localized: "看自己的订阅要先登录 Steam。")) { self.reloadGallery() }
                return ([], true)
            }
            if allSubscriptions == nil {
                do {
                    let all = try await loadSubscriptions()
                    allSubscriptions = all
                    subscribedIDs = Set(all.map(\.id))
                    recordSubscriptionDates(all)
                } catch WorkshopNative.Failure.notLoggedIn {
                    showLogin(reason: String(localized: "Steam 的登录过期了，请重新登录。")) { self.reloadGallery() }
                    return ([], true)
                }
            }
            return (subscriptionFilter.apply(allSubscriptions ?? []), true)
        }
    }

    /// 我的订阅：CM 一次给出全部编号和详情（`PublishedFile.GetUserFiles`）；缺预览图或标签的
    /// 再用公开的详情接口补（筛类型、分级要靠标签）
    private func loadSubscriptions() async throws -> [WorkshopItem] {
        let listed = try await withSession { try await self.native.subscribedFiles(session: $0, includeTags: true) }
        let incomplete = listed.filter { $0.previewURL == nil || $0.tags.isEmpty }.map(\.id)
        guard !incomplete.isEmpty else { return listed }
        // 每次最多问 50 个；几百个订阅分好几批，一起发（以前一批等一批，订阅多的要多等好几秒）
        var fetched: [String: WorkshopItem] = [:]
        let catalog = catalog
        let batches = stride(from: 0, to: incomplete.count, by: 50).map {
            Array(incomplete[$0..<min($0 + 50, incomplete.count)])
        }
        await withTaskGroup(of: [WorkshopItem].self) { group in
            for batch in batches { group.addTask { (try? await catalog.details(batch)) ?? [] } }
            for await items in group {
                for item in items { fetched[item.id] = item }
            }
        }
        // 公开接口不知道"什么时候订阅的"，这个要留 CM 给的
        return listed.map { original in
            guard var replacement = fetched[original.id] else { return original }
            replacement.subscribedAt = original.subscribedAt
            return replacement
        }
    }

    private func applySubscriptionFilter() {
        guard source == .subscriptions, let all = allSubscriptions else { return }
        items = subscriptionFilter.apply(all)
    }

    // MARK: - 登录

    /// 弹出登录框。`then` 是登录好以后接着做的事
    func showLogin(reason: String?, then action: (() -> Void)? = nil) {
        loginReason = reason
        if let action { afterLogin.append(action) }
        if case .failed = loginStep { loginStep = .idle }
        isShowingLogin = true
    }

    func closeLogin() {
        isShowingLogin = false
        if loginStep != .idle { cancelSignIn() }
        // 用户不登录了：刚才等着登录的操作也不做了
        afterLogin = []
    }

    /// 账号密码登录（整条认证会话走 CM）：要验证码或手机确认时，登录框换成对应的一步
    func signIn(account: String, password: String) {
        let name = account.trimmingCharacters(in: .whitespaces)
        guard Workshop.isValidAccountName(name) else {
            loginStep = .failed(String(localized: "账户名称只能是字母、数字和 _ . -（登录 Steam 用的账户名称，不是昵称）"))
            return
        }
        guard !password.isEmpty else { loginStep = .failed(String(localized: "请填密码")); return }
        let attempt = beginLoginAttempt()
        AppFolder.settings.set(name, forKey: Self.lastAccountKey)
        loginTask = Task {
            do {
                let pending = try await native.beginPasswordLogin(account: name, password: password)
                guard attempt == loginAttempt else { return }
                passwordLogin = pending
                if pending.needsConfirmation != nil {
                    loginStep = .waitingForPhone(canEnterCode: pending.needsCode != nil)
                } else if let code = pending.needsCode {
                    loginStep = .needsCode(email: code.type == 2)
                }
                let session = try await native.waitForLogin(pending)
                guard attempt == loginAttempt else { return }
                loginSucceeded(session)
            } catch {
                guard attempt == loginAttempt, !(error is CancellationError) else { return }
                failSignIn(error.localizedDescription)
            }
        }
    }

    /// 扫码登录：不用输密码，手机上确认一下（二维码显示在登录框里，过期换新时跟着换）
    func signInWithQRCode() {
        let attempt = beginLoginAttempt()
        loginTask = Task {
            do {
                let qr = try await native.beginQRLogin()
                guard attempt == loginAttempt else { return }
                showQRCode(qr.challengeURL)
                loginStep = .waitingForScan
                let session = try await native.waitForLogin(qr) { url in
                    Task { @MainActor in
                        guard attempt == self.loginAttempt else { return }
                        self.showQRCode(url)
                    }
                }
                guard attempt == loginAttempt else { return }
                loginSucceeded(session)
            } catch {
                guard attempt == loginAttempt, !(error is CancellationError) else { return }
                failSignIn(error.localizedDescription)
            }
        }
    }

    /// 交验证码（邮件 / 手机令牌上的）。填错了回到填验证码那一步，显示原因
    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty, let login = passwordLogin, login.needsCode != nil else { return }
        let previous = loginStep
        switch previous {
        case .needsCode, .waitingForPhone(canEnterCode: true): break
        default: return
        }
        let attempt = loginAttempt
        codeError = nil
        loginStep = .checkingCode
        Task {
            do {
                // 交上去就行：令牌由正在跑的那次登录（轮询）拿到
                try await native.submitCode(trimmed, to: login)
            } catch {
                guard attempt == loginAttempt else { return }
                codeError = error.localizedDescription
                loginStep = previous
            }
        }
    }

    func cancelSignIn() {
        loginAttempt += 1
        loginTask?.cancel()
        loginTask = nil
        passwordLogin = nil
        qrCodeImage = nil
        qrChallengeURL = nil
        codeError = nil
        loginStep = .idle
    }

    /// 退出登录：删掉本机存的会话、断开 CM（下次要重新登录）
    func signOut() {
        log("创意工坊：用户退出登录")
        cancelSignIn()
        engineAssetsTask?.cancel()
        sessionStore.clear()
        if let account = session?.accountName {
            AppFolder.settings.removeObject(forKey: Self.subscribedIDsKey(account))
            AppFolder.settings.removeObject(forKey: Self.subscriptionDatesKey(account))
        }
        session = nil
        subscribedIDs = []
        subscriptionDates = [:]
        Task { await native.logOut() }
        if source == .subscriptions { reloadGallery() }
    }

    /// 开始一次新的登录：前一次（如果还在进行）作废
    private func beginLoginAttempt() -> Int {
        cancelSignIn()
        loginStep = .signingIn
        return loginAttempt
    }

    private func showQRCode(_ url: String) {
        qrChallengeURL = url
        qrCodeImage = SteamLoginQRCode.imageData(for: url)
    }

    private func loginSucceeded(_ session: SteamCMSession) {
        log("创意工坊：登录成功（账号 \(session.accountName)）")
        sessionStore.save(session)
        self.session = session
        // 这个账号以前存下的订阅和订阅时间（和启动时一样）：换了账号时不能接着用上一个账号的
        subscribedIDs = Set(AppFolder.settings.stringArray(forKey: Self.subscribedIDsKey(session.accountName)) ?? [])
        subscriptionDates = Self.loadSubscriptionDates(session.accountName)
        AppFolder.settings.set(session.accountName, forKey: Self.lastAccountKey)
        loginTask = nil
        passwordLogin = nil
        qrCodeImage = nil
        qrChallengeURL = nil
        codeError = nil
        loginStep = .idle
        isShowingLogin = false
        refreshSubscribedIDs()
        syncEngineAssets()
        let actions = afterLogin
        afterLogin = []
        actions.forEach { $0() }
    }

    private func failSignIn(_ reason: String) {
        log("创意工坊：登录没有成功（\(reason)）")
        loginTask = nil
        passwordLogin = nil
        qrCodeImage = nil
        qrChallengeURL = nil
        loginStep = .failed(reason)
    }

    /// 需要登录的操作都经过这里：Steam 明确不认存着的会话了，就当作退出登录（调用方再弹登录框）
    private func withSession<T>(_ body: (SteamCMSession) async throws -> T) async throws -> T {
        guard let session else { throw WorkshopNative.Failure.notLoggedIn }
        do {
            return try await body(session)
        } catch WorkshopNative.Failure.notLoggedIn {
            if self.session?.refreshToken == session.refreshToken { sessionExpired(reason: "Steam 不认这个会话了") }
            throw WorkshopNative.Failure.notLoggedIn
        }
    }

    /// Steam 明确不认存着的会话（令牌过期 / 被撤销）：删掉本机存的会话，下次操作时让用户重新登录
    private func sessionExpired(reason: String) {
        log("创意工坊：退出登录——\(reason)")
        sessionStore.clear()
        // 先清会话再清内存里的订阅：这个账号存在设置里的那份留着（重新登录同一个账号时接着用）
        session = nil
        subscribedIDs = []
        subscriptionDates = [:]
        Task { await native.logOut() }
    }

    /// 读一遍订阅列表（卡片上的"已订阅"标记用）
    private func refreshSubscribedIDs() {
        guard isLoggedIn else { return }
        Task {
            if let files = try? await withSession({ try await self.native.subscribedFiles(session: $0) }) {
                subscribedIDs = Set(files.map(\.id))
                recordSubscriptionDates(files)
            }
        }
    }

    // MARK: - 订阅 / 取消订阅

    /// 在 Steam 上订阅或取消订阅（用户点了按钮才调）
    func setSubscribed(_ subscribed: Bool, id: String) async -> Workshop.SubscribeResult {
        // 界面先变：点了马上看到结果（网络来回、断线后重连登录要一两秒到几秒）；Steam 回失败再改回去
        let wasSubscribed = subscribedIDs.contains(id)
        let previousAll = allSubscriptions
        let previousDate = subscriptionDates[id]
        markSubscribed(subscribed, id: id)
        pendingSubscriptions.insert(id)
        defer { pendingSubscriptions.remove(id) }
        func revert() {
            // 登录过期时会话已经清掉了，不要把"已订阅"标记又放回去
            guard session != nil else { return }
            if wasSubscribed { subscribedIDs.insert(id) } else { subscribedIDs.remove(id) }
            subscriptionDates[id] = previousDate
            allSubscriptions = previousAll
            applySubscriptionFilter()
        }
        do {
            try await withSession { try await self.native.setSubscribed(subscribed, id: id, session: $0) }
        } catch WorkshopNative.Failure.notLoggedIn {
            revert()
            return .notLoggedIn
        } catch {
            revert()
            log("创意工坊：\(subscribed ? "订阅" : "取消订阅") \(id) 没有成功（\(error.localizedDescription)）")
            return .failed(error.localizedDescription)
        }
        log("创意工坊：\(subscribed ? "订阅" : "取消订阅") \(id)")
        return .done
    }

    /// 本机记下的订阅状态（标记、"我的订阅"列表）改成这样
    private func markSubscribed(_ subscribed: Bool, id: String) {
        if subscribed { subscribedIDs.insert(id) } else { subscribedIDs.remove(id) }
        if subscribed {
            if subscriptionDates[id] == nil { subscriptionDates[id] = Date() }
        } else {
            subscriptionDates[id] = nil
        }
        // "我的订阅"马上跟着变（不用等下次从 Steam 重读）：新订阅的按"刚刚订阅"排在最前
        if var all = allSubscriptions {
            if subscribed {
                if !all.contains(where: { $0.id == id }), var item = knownItem(id) {
                    item.subscribedAt = Date()
                    all.append(item)
                }
            } else {
                all.removeAll { $0.id == id }
            }
            allSubscriptions = all
            applySubscriptionFilter()
        }
    }

    private static func subscribedIDsKey(_ account: String) -> String { "workshop.subscribedIDs." + account }
    private static func subscriptionDatesKey(_ account: String) -> String { "workshop.subscriptionDates." + account }

    /// 订阅列表里带的订阅时间整个换掉（列表是全量的：不在里面的已经取消了）
    private func recordSubscriptionDates(_ items: [WorkshopItem]) {
        var dates: [String: Date] = [:]
        for item in items { dates[item.id] = item.subscribedAt ?? subscriptionDates[item.id] }
        subscriptionDates = dates
    }

    private static func loadSubscriptionDates(_ account: String) -> [String: Date] {
        let raw = AppFolder.settings.dictionary(forKey: subscriptionDatesKey(account)) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveSubscriptionDates() {
        guard let account = session?.accountName else { return }
        AppFolder.settings.set(subscriptionDates.mapValues(\.timeIntervalSince1970), forKey: Self.subscriptionDatesKey(account))
    }

    private func saveSubscribedIDs() {
        guard let account = session?.accountName else { return }
        AppFolder.settings.set(subscribedIDs.sorted(), forKey: Self.subscribedIDsKey(account))
    }

    /// 订阅并下载
    func subscribeAndDownload(_ id: String) {
        guard isLoggedIn else {
            showLogin(reason: String(localized: "订阅要先登录 Steam。")) { self.subscribeAndDownload(id) }
            return
        }
        message = String(localized: "正在订阅…")
        Task {
            switch await setSubscribed(true, id: id) {
            case .done:
                message = String(localized: "已订阅，开始下载。")
                download([id])
            case .notLoggedIn:
                showLogin(reason: String(localized: "Steam 的登录过期了，请重新登录。")) { self.subscribeAndDownload(id) }
            case .failed(let reason):
                // 在 Steam 上订阅没成功也照样下载：下载不依赖订阅，用户要的是这张壁纸
                message = String(localized: "在 Steam 上订阅没有成功（\(reason)），先下载到这台 Mac。")
                download([id])
            }
        }
    }

    // MARK: - 下载

    func download(_ ids: [String]) {
        let fresh = ids.filter { state(of: $0) != .waiting && state(of: $0) != .downloading }
        guard !fresh.isEmpty else { return }
        queue.removeAll { fresh.contains($0.id) }
        queue += fresh.map { QueueItem(id: $0, state: .waiting) }
        runQueue()
    }

    #if DEBUG
    /// 布局测试用：直接摆出"有等着的、有失败的、暂停着"的样子
    func showQueueForLayoutTest(_ items: [QueueItem], paused: Bool) {
        queue = items
        isPaused = paused
    }
    #endif

    /// 还没下的（等着的和正在下的）
    var pendingCount: Int { queue.filter { $0.state == .waiting || $0.state == .downloading }.count }

    /// 暂停：正在下的那件马上停下、放回等待（半截的临时文件会删掉），点「继续」从它开始接着下
    func pauseDownloads() {
        guard !isPaused else { return }
        isPaused = true
        downloadTask?.cancel()
        message = String(localized: "已暂停下载，还有 \(pendingCount) 个没下。")
        log("创意工坊：暂停下载（还有 \(pendingCount) 个没下）")
    }

    func resumeDownloads() {
        guard isPaused else { return }
        isPaused = false
        log("创意工坊：继续下载（还有 \(pendingCount) 个）")
        runQueue()
    }

    private func runQueue() {
        guard !isPaused, !isDownloading, queue.contains(where: { $0.state == .waiting }) else { return }
        guard isLoggedIn else {
            showLogin(reason: String(localized: "下载前要先登录 Steam。")) { self.runQueue() }
            return
        }
        let batch = queue.filter { $0.state == .waiting }.prefix(20).map(\.id)
        isDownloading = true
        setState(.downloading, for: batch)
        message = String(localized: "正在下载 \(batch.count) 个…")
        downloadTask = Task {
            // 一件一件来（每件内部是"详情 → depot 密钥 → 清单 → 分块"，整件下完才放进下载目录）
            var lastFailure: String?
            var needsLogin = false
            var done: [String] = []
            for id in batch {
                // 暂停了：剩下的留着，点「继续」再下
                if isPaused || Task.isCancelled { break }
                do {
                    log("创意工坊：开始下载 \(id)")
                    _ = try await withSession { session in
                        try await self.native.download(id: id, to: self.downloadDirectory, session: session) { fraction in
                            Task { @MainActor in self.setProgress(fraction, for: id) }
                        }
                    }
                    progress[id] = nil
                    setState(.done, for: [id])
                    done.append(id)
                    log("创意工坊：下载完成 \(id)")
                    // 下好一个就进壁纸库（原来等这一批 20 个都下完才刷新，同步订阅时要等好几分钟）
                    onDownloaded(downloadDirectory)
                } catch WorkshopNative.Failure.notLoggedIn {
                    // 登录过期了：剩下的先放回等待，重新登录后接着下
                    progress[id] = nil
                    needsLogin = true
                    break
                } catch {
                    progress[id] = nil
                    // 暂停打断的不算失败：放回等待
                    if isPaused || Task.isCancelled { break }
                    lastFailure = error.localizedDescription
                    setState(.failed(error.localizedDescription), for: [id])
                    log("创意工坊：下载 \(id) 失败（\(error.localizedDescription)）")
                }
            }
            setState(.waiting, for: batch.filter { state(of: $0) == .downloading })
            isDownloading = false
            downloadTask = nil
            if isPaused { return }
            if needsLogin {
                showLogin(reason: String(localized: "Steam 的登录过期了，重新登录后接着下载。")) { self.runQueue() }
                return
            }
            let failed = batch.count - done.count
            if let lastFailure, done.isEmpty {
                message = String(localized: "下载失败：\(lastFailure)")
            } else {
                switch (failed > 0, done.isEmpty) {
                case (false, false): message = String(localized: "下载完成 \(done.count) 个，已加进壁纸库。")
                case (true, false): message = String(localized: "下载完成 \(done.count) 个，失败 \(failed) 个，已加进壁纸库。")
                case (true, true): message = String(localized: "下载失败 \(failed) 个。")
                case (false, true): message = String(localized: "没有要下载的。")
                }
            }
            runQueue()
        }
    }

    /// 下载进度：每涨 1% 才刷新一次界面
    private func setProgress(_ fraction: Double, for id: String) {
        guard state(of: id) == .downloading else { return }
        let value = min(max(fraction, 0), 1)
        if value - (progress[id] ?? -1) >= 0.01 || value >= 1 { progress[id] = value }
    }

    func clearFinished() {
        queue.removeAll { $0.state != .waiting && $0.state != .downloading }
    }

    private func setState(_ state: ItemState, for ids: [String]) {
        for index in queue.indices where ids.contains(queue[index].id) { queue[index].state = state }
    }

    // MARK: - 同步订阅

    /// 按订阅时间从新到旧（没有订阅时间的放最后，保持原来的顺序）
    static func newestSubscriptionsFirst(_ items: [WorkshopItem]) -> [WorkshopItem] {
        items.enumerated().sorted { a, b in
            switch (a.element.subscribedAt, b.element.subscribedAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// 读 Steam 上的订阅列表，把创意工坊下载目录里还没有的下载下来；下载目录里已经不在订阅里的，交给 App 问用户要不要移走
    func syncSubscriptions() {
        guard !isSyncing else { return }
        guard isLoggedIn else {
            showLogin(reason: String(localized: "同步订阅要先登录 Steam。")) { self.syncSubscriptions() }
            return
        }
        isSyncing = true
        message = String(localized: "正在读取你的订阅列表…")
        Task {
            defer { isSyncing = false }
            let subscribed: [String]
            do {
                let files = try await withSession { session in
                    // 刚唤醒、换网络这类原因会偶发失败：等一下自动再试一次，还不行才把原因告诉用户
                    try await Self.withRetry { try await self.native.subscribedFiles(session: session) }
                }
                // 最近订阅的先下：Steam 回来的顺序是按作者最后更新的时间排的，刚订阅的老壁纸会排到很后面
                subscribed = Self.newestSubscriptionsFirst(files).map(\.id)
                recordSubscriptionDates(files)
            } catch WorkshopNative.Failure.notLoggedIn {
                showLogin(reason: String(localized: "Steam 的登录过期了，请重新登录。")) { self.syncSubscriptions() }
                return
            } catch {
                message = String(localized: "读取订阅失败：\(error.localizedDescription)")
                return
            }
            subscribedIDs = Set(subscribed)
            // 本机有没有只看创意工坊的下载目录（Steam 放 WE 创意工坊内容的文件夹）：已经在那里的不再下；
            // 壁纸库里别的文件夹（自己拷来的）不算。壁纸网格上"本机已有"的标记照样按整个壁纸库刷新
            refreshLocalItems()
            let local = await Task.detached(priority: .userInitiated) {
                Workshop.localItemIDs(in: Workshop.downloadDirectories)
            }.value
            let missing = subscribed.filter { !local.contains($0) }
            let subscribedSet = Set(subscribed)
            let stale = await Task.detached(priority: .userInitiated) { () -> [URL] in
                Workshop.downloadDirectories.flatMap { directory in
                    (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                }
                .filter { folder in
                    guard let id = Workshop.itemID(ofProjectFolder: folder) else { return false }
                    return !subscribedSet.contains(id)
                }
            }.value
            message = String(localized: "你订阅了 \(subscribed.count) 个，这台 Mac 上还缺 \(missing.count) 个。")
            log("创意工坊：同步订阅——订阅 \(subscribed.count) 个，下载目录里已有 \(subscribed.count - missing.count) 个，"
                + "要下载 \(missing.count) 个；不在订阅里的下载 \(stale.count) 个")
            // 暂停着又点了「同步订阅」：就是要接着下
            if isPaused, !missing.isEmpty { resumeDownloads() }
            if !missing.isEmpty { download(missing) }
            if !stale.isEmpty { onUnsubscribed(stale) }
        }
    }
}

/// 创意工坊网格上次看到的第一页（浏览）/ 全部订阅（我的订阅），存在壁坞文件夹的 Cache/Workshop 里。
/// 打开创意工坊先摆它，不用干等 Steam 回话；存了一周以上的不用
enum GalleryCache {
    private struct Saved: Codable {
        var saved: Date
        var items: [WorkshopItem]
    }

    private static var directory: URL? {
        AppFolder.isActive ? AppFolder.cache.appendingPathComponent("Workshop", isDirectory: true) : nil
    }

    static func load(_ key: String?) -> [WorkshopItem]? {
        guard let key, let file = directory?.appendingPathComponent(key + ".json"),
              let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              Date().timeIntervalSince(saved.saved) < 7 * 86400
        else { return nil }
        return saved.items
    }

    static func save(_ items: [WorkshopItem], key: String) {
        guard let directory, !items.isEmpty,
              let data = try? JSONEncoder().encode(Saved(saved: Date(), items: items))
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        // 过期的（一周以上没再存过的筛选条件）删掉，不让文件越攒越多
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for file in (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys))) ?? [] {
            guard let modified = try? file.resourceValues(forKeys: keys).contentModificationDate,
                  Date().timeIntervalSince(modified) >= 7 * 86400
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 编成 JSON 再把键和数组都排好序：筛选里的分级、分辨率是 Set，直接编码的顺序每次启动都不一样，
    /// 同一个筛选条件会算出不同的文件名
    static func canonicalJSON(_ value: some Encodable) -> Data? {
        func sorted(_ object: Any) -> Any {
            switch object {
            case let dictionary as [String: Any]: return dictionary.mapValues(sorted)
            case let array as [Any]: return array.map(sorted).sorted { "\($0)" < "\($1)" }
            default: return object
            }
        }
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: sorted(object), options: [.sortedKeys, .fragmentsAllowed])
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
