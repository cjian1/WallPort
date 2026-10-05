import AppKit
import CryptoKit
import DesktopHost
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WallpaperLibrary

// MARK: - 壁纸网格

/// 壁纸库左边的"Steam 创意工坊"：和 WE 的壁纸浏览一样的网格，打开就能看，不用进网页
struct WorkshopGallery: View {
    @ObservedObject var model: WorkshopModel
    /// 本机壁纸库：设为壁纸、选中（右边显示设置）、取消订阅（App 先问一句；本机有的一并移走）都交给它。
    /// 不观察它；也不用闭包传这些操作——闭包没法比较，SwiftUI 会当成"变了"，外面每次重绘都连带重算整个网格
    let library: LibraryModel
    @State private var searchText = ""

    /// 浏览要问 Steam（一页是几百 KB 的网页），边打边搜时等用户停下来再发请求
    private static let browseSearchDelay = Duration.milliseconds(500)

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            content
        }
        // 不在这里 activate：这个视图一直留在壁纸库的视图树里（切走只是隐藏），onAppear 在打开"本机壁纸"时
        // 也会触发。切到创意工坊时由 LibraryView 调用
        .onAppear { searchText = currentSearch }
        .onChange(of: model.source) { searchText = currentSearch }
    }

    /// 两种来源各有各的搜索词：浏览是问 Steam 的，我的订阅在本机筛
    private var currentSearch: String {
        model.source == .browse ? model.query.search : model.subscriptionFilter.search
    }

    /// 把搜索框里的词交给浏览查询（和原来一样，值没变就不重复问 Steam）
    private func applyBrowseSearch() {
        guard model.source == .browse, model.query.search != searchText else { return }
        model.query.search = searchText
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $model.source) {
                    ForEach(WorkshopModel.Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                // 刷新挪到列表这边（紧挨"浏览 / 我的订阅"）：放在搜索框旁边会被当成"搜索"按钮
                Button { model.reloadGallery() } label: { Image(systemName: "arrow.clockwise") }
                    .help(model.source == .browse ? "刷新创意工坊列表" : "重新读取订阅列表")
                Spacer()
                TextField(model.source == .browse ? "搜索创意工坊" : "搜索我的订阅", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    // 回车：马上搜（浏览页不用等防抖）
                    .onSubmit { applyBrowseSearch() }
                    // 边打边搜。我的订阅是本机筛，立刻生效；浏览要问 Steam，停一下再发请求
                    .onChange(of: searchText) {
                        if model.source == .subscriptions { model.subscriptionFilter.search = searchText }
                    }
                    .task(id: searchText) {
                        guard model.source == .browse else { return }
                        try? await Task.sleep(for: Self.browseSearchDelay)
                        // 又打了字（或切了页面）时这次就作废，只发最后一次
                        guard !Task.isCancelled else { return }
                        applyBrowseSearch()
                    }
            }
            HStack(spacing: 10) {
                switch model.source {
                case .browse:
                    Picker("排序", selection: $model.query.sort) {
                        ForEach(WorkshopQuery.Sort.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 170)
                    KindPicker(kind: $model.query.kind)
                case .subscriptions:
                    Picker("排序", selection: $model.subscriptionFilter.sort) {
                        ForEach(WorkshopSubscriptionFilter.Sort.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 170)
                    KindPicker(kind: $model.subscriptionFilter.kind)
                }
                Spacer()
            }
            HStack {
                switch model.source {
                case .browse: RatingToggles(ratings: $model.query.ratings.ratings, asksAge: true)
                case .subscriptions: RatingToggles(ratings: $model.subscriptionFilter.ratings.ratings)
                }
                Spacer()
            }
            switch model.source {
            case .browse: ResolutionToggles(resolutions: $model.query.resolutions)
            case .subscriptions: ResolutionToggles(resolutions: $model.subscriptionFilter.resolutions)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            VStack(spacing: 10) {
                if model.isLoadingPage {
                    ProgressView()
                    Text(model.source == .subscriptions ? "正在读取你的订阅…" : "正在加载创意工坊…")
                        .foregroundStyle(.secondary)
                } else if let error = model.loadError {
                    Text("加载失败：\(error)").foregroundStyle(.secondary)
                    Button("重试") { model.reloadGallery() }
                } else if model.source == .subscriptions && model.session == nil {
                    Text("登录 Steam 后，这里会列出你订阅的壁纸。").foregroundStyle(.secondary)
                    Button("登录 Steam…") { [model] in model.showLogin(reason: nil) { [weak model] in model?.reloadGallery() } }
                } else {
                    Text(model.source == .subscriptions ? "没有符合条件的订阅" : "没有符合条件的壁纸").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], spacing: 18) {
                        ForEach(model.items) { item in
                            let isLocal = model.isLocal(item.id)
                            let isSubscribed = model.subscribedIDs.contains(item.id)
                            WorkshopCard(
                                item: item, isSelected: model.selectedID == item.id, isLocal: isLocal,
                                isSubscribed: isSubscribed, state: model.state(of: item.id),
                                progress: model.progress[item.id])
                            .id(item.id)
                            .onTapGesture { tap(item) }
                            .onAppear {
                                model.noteCard(item.id, visible: true)
                                if item.id == model.items.last?.id { model.loadMore() }
                            }
                            .onDisappear { model.noteCard(item.id, visible: false) }
                            .contextMenu { menu(for: item, isLocal: isLocal, isSubscribed: isSubscribed) }
                        }
                    }
                    .padding(16)
                    if model.isLoadingPage {
                        ProgressView().padding(.bottom, 16)
                    } else if model.reachedEnd {
                        Text(model.source == .subscriptions ? "共 \(model.items.count) 个" : "没有更多了")
                            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
                    }
                }
                // 从另一页切回来：滚回切走时看到的位置
                .onChange(of: model.scrollTarget) {
                    guard let target = model.scrollTarget else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(target, anchor: .top)
                        model.scrollTarget = nil
                    }
                }
                .onAppear {
                    if let target = model.scrollTarget {
                        proxy.scrollTo(target, anchor: .top)
                        model.scrollTarget = nil
                    }
                }
            }
        }
    }

    /// 点卡片：选中它（右边显示详情）；"我的订阅"里本机已经有的，和本机壁纸一样直接设为壁纸，右边显示它的设置
    private func tap(_ item: WorkshopItem) {
        model.selectedID = item.id
        guard model.isLocal(item.id) else { return }
        library.selectWorkshopItem(item.id)
        if model.source == .subscriptions { library.applyWorkshopItem(item.id) }
    }

    /// 右键菜单：按条目现在的状态给能做的事
    @ViewBuilder
    private func menu(for item: WorkshopItem, isLocal: Bool, isSubscribed: Bool) -> some View {
        if isLocal {
            Button("设为壁纸") { library.applyWorkshopItem(item.id) }
        } else if isSubscribed {
            Button("下载到壁纸库") { model.download([item.id]) }
        } else {
            Button("订阅并下载") { model.subscribeAndDownload(item.id) }
        }
        if isSubscribed {
            Button("取消订阅…") { library.onUnsubscribeItem(item.id) }
        }
        Divider()
        Button("在 Steam 上查看") { NSWorkspace.shared.open(Workshop.itemURL(item.id)) }
    }
}

struct WorkshopCard: View {
    let item: WorkshopItem
    let isSelected: Bool
    let isLocal: Bool
    let isSubscribed: Bool
    let state: WorkshopModel.ItemState?
    /// 下载进度（0…1）；还在准备时是 nil
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImage(url: item.previewURL)
                .frame(height: 118)
                .frame(maxWidth: .infinity)
                .overlay { downloadOverlay }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { badge.padding(6) }
            HStack(spacing: 6) {
                Text(Self.kindTitle(item.kind))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                Text("\(Self.count(item.subscriptions)) 订阅").font(.caption2).foregroundStyle(.secondary)
            }
            Text(item.title).font(.callout).lineLimit(2).help(item.title)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
    }

    /// 下载中：在预览图上盖一层，显示百分比和进度条
    @ViewBuilder
    private var downloadOverlay: some View {
        if state == .downloading || state == .waiting {
            ZStack {
                Color.black.opacity(0.5)
                VStack(spacing: 6) {
                    if state == .waiting {
                        Image(systemName: "clock").font(.title3)
                        Text("等待下载").font(.caption.bold())
                    } else if let progress {
                        Text("\(Int((progress * 100).rounded(.down)))%").font(.title2.bold()).monospacedDigit()
                        ProgressView(value: progress).progressViewStyle(.linear).tint(.white).frame(width: 130)
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("准备下载…").font(.caption.bold())
                    }
                }
                .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if state == .downloading || state == .waiting {
            EmptyView()
        } else if isLocal {
            Label("已下载", systemImage: "checkmark.circle.fill").badgeStyle(.green)
        } else if isSubscribed {
            Label("已订阅", systemImage: "bookmark.fill").badgeStyle(.gray)
        }
    }

    static func kindTitle(_ kind: String?) -> String {
        switch kind {
        case "Scene": String(localized: "场景")
        case "Video": String(localized: "视频")
        case "Web": String(localized: "网页")
        case "Application": String(localized: "应用")
        default: String(localized: "壁纸")
        }
    }

    /// 订阅数：中文 1.2万、英文 12K（跟着系统的语言和地区）
    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

private extension View {
    func badgeStyle(_ color: Color) -> some View {
        font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.85)))
            .foregroundStyle(.white)
    }
}

/// 预览图：卡片出现时才加载（本机文件直接解码，创意工坊的先下载），缩成缩略图放在内存里；没有图时显示占位符号
struct ThumbnailImage: View {
    let url: URL?
    var placeholder = "photo"
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: placeholder).font(.system(size: 26)).foregroundStyle(.secondary)
            }
        }
        .task(id: url) { image = await ThumbnailCache.shared.image(for: url) }
    }
}

/// 缩略图缓存。解码在后台线程；同一张图同时只解一次。
/// 按字节设上限（系统内存紧张时 NSCache 也会自己清），壁纸库窗口关掉时整个清空——
/// 壁坞常驻后台，不能一直占着几百张缩略图的内存。
///
/// 创意工坊的预览图：只下到能解出第一帧为止（见 `WorkshopPreview`，GIF 动图从 1 MB 降到几十 KB），
/// 解好的缩略图另存一份在磁盘上（壁坞文件夹的 Cache/Thumbnails，几十 KB 一张），下次打开不用再下载
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// 卡片约 260×118 点，2 倍屏要 520 像素宽
    nonisolated static let maxPixelSize = 520
    /// 磁盘上最多留多少张（超过就删最久没用的）
    nonisolated static let diskLimit = 3000
    private let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private var loading: [URL: Task<CGImage?, Never>] = [:]
    /// 预览图一页 30 张，同一台服务器多开几条连接
    private let client = URLSessionHTTPClient(connectionsPerHost: 10)
    private let diskDirectory: URL? = AppFolder.isActive
        ? AppFolder.cache.appendingPathComponent("Thumbnails", isDirectory: true) : nil

    private init() {
        if let diskDirectory {
            Task.detached(priority: .background) { Self.pruneDisk(diskDirectory) }
        }
    }

    func image(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let cached = images.object(forKey: url as NSURL) { return cached }
        let task: Task<CGImage?, Never>
        if let running = loading[url] {
            task = running
        } else {
            let client = client
            let diskFile = url.isFileURL ? nil : diskDirectory.map { $0.appendingPathComponent(Self.diskName(url)) }
            task = Task.detached(priority: .utility) { () -> CGImage? in
                if let diskFile, let saved = Self.thumbnail(CGImageSourceCreateWithURL(diskFile as CFURL, nil)) {
                    // 碰一下修改时间：清理时按它判断最近有没有用过
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: diskFile.path)
                    return saved
                }
                let source: CGImageSource?
                if url.isFileURL {
                    source = CGImageSourceCreateWithURL(url as CFURL, nil)
                } else if let data = try? await WorkshopPreview.data(for: url, client: client) {
                    source = CGImageSourceCreateWithData(data as CFData, nil)
                } else {
                    source = nil
                }
                guard let image = Self.thumbnail(source) else { return nil }
                if let diskFile { Self.save(image, to: diskFile) }
                return image
            }
            loading[url] = task
        }
        let decoded = await task.value
        loading[url] = nil
        guard let decoded else { return nil }
        if let cached = images.object(forKey: url as NSURL) { return cached }
        let image = NSImage(cgImage: decoded, size: .zero)
        images.setObject(image, forKey: url as NSURL, cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    func removeAll() {
        images.removeAllObjects()
    }

    private nonisolated static func thumbnail(_ source: CGImageSource?) -> CGImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 地址 → 文件名（Steam 的预览图地址里带着内容的哈希，图换了地址也会换）
    private nonisolated static func diskName(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private nonisolated static func save(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// 超过上限时删掉最久没用过的，留下上限的四分之三
    private nonisolated static func pruneDisk(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys), files.count > diskLimit
        else { return }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - diskLimit * 3 / 4) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - 右侧：选中的壁纸

struct WorkshopItemPanel: View {
    @ObservedObject var model: WorkshopModel
    /// 本机已有时设为壁纸；取消订阅（App 先问一句、在 Steam 上取消、再把本机文件移走）
    let library: LibraryModel

    var body: some View {
        if let item = model.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ThumbnailImage(url: item.previewURL)
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(item.title).font(.title3.bold()).lineLimit(3)
                    Text(details(item)).font(.callout).foregroundStyle(.secondary)
                    if !item.tags.isEmpty {
                        Text(item.tags.map { WallpaperRating(tag: $0)?.title ?? $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    actions(item)
                    // 界面已经先变了，Steam 那边还在确认（回失败会改回去）
                    if model.pendingSubscriptions.contains(item.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在同步到 Steam…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("在 Steam 上查看") { NSWorkspace.shared.open(Workshop.itemURL(item.id)) }
                        .buttonStyle(.link)
                }
                .padding(16)
            }
        } else {
            Text("点一张壁纸，在这里订阅、下载或设为壁纸。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func actions(_ item: WorkshopItem) -> some View {
        let state = model.state(of: item.id)
        if state == .waiting {
            HStack { ProgressView().controlSize(.small); Text("等待下载…") }
        } else if state == .downloading {
            if let progress = model.progress[item.id] {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text("正在下载 \(Int((progress * 100).rounded(.down)))%").font(.callout).monospacedDigit()
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("正在准备下载…") }
            }
        } else if model.isLocal(item.id) {
            Label("已在壁纸库", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            HStack {
                Button("设为壁纸") { library.applyWorkshopItem(item.id) }.keyboardShortcut(.defaultAction)
                if model.subscribedIDs.contains(item.id) {
                    Button("取消订阅", role: .destructive) { library.onUnsubscribeItem(item.id) }
                }
            }
        } else if model.subscribedIDs.contains(item.id) {
            Label("已在 Steam 上订阅", systemImage: "bookmark.fill").foregroundStyle(.secondary)
            HStack {
                Button("下载到壁纸库") { model.download([item.id]) }.keyboardShortcut(.defaultAction)
                Button("取消订阅", role: .destructive) { library.onUnsubscribeItem(item.id) }
            }
        } else {
            Button("订阅并下载") { model.subscribeAndDownload(item.id) }.keyboardShortcut(.defaultAction)
            Text("在 Steam 上订阅，并把它下到这台 Mac 的壁纸库。").font(.caption).foregroundStyle(.secondary)
        }
        if case .failed(let reason)? = state {
            Text("下载失败：\(reason)").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Button("重试") { model.download([item.id]) }
        }
    }

    private func details(_ item: WorkshopItem) -> String {
        var parts = [WorkshopCard.kindTitle(item.kind), String(localized: "\(WorkshopCard.count(item.subscriptions)) 订阅")]
        if item.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
        }
        if let updated = item.updated {
            parts.append(String(localized: "更新于 \(updated.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 底部状态栏

/// 壁纸库底部：Steam 的登录状态、同步订阅、下载进度（本机和创意工坊两种模式共用）。
/// 始终只有一行：消息收在铃铛里、下载失败的收在「N 项下载失败」里（原来每项失败占一行，
/// 内容服务器连着回几次 503 就把底栏撑高了）
struct WorkshopStatusBar: View {
    @ObservedObject var model: WorkshopModel
    @State private var showsFailures = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud").foregroundStyle(.secondary)
            Text(statusText).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if ((model.isSyncing || model.isDownloading) && !model.isPaused) || model.engineAssetsProgress != nil {
                ProgressView().controlSize(.small)
            }
            if model.pendingCount > 0 {
                if model.isPaused {
                    Button("继续") { model.resumeDownloads() }
                        .help("接着下载剩下的 \(model.pendingCount) 个")
                } else {
                    Button("暂停") { model.pauseDownloads() }
                        .help("正在下的那个停下，剩下的先不下；点「继续」接着下")
                }
            }
            let failedItems = model.queue.filter { if case .failed = $0.state { true } else { false } }
            if !failedItems.isEmpty {
                Button {
                    showsFailures = true
                } label: {
                    Label("\(failedItems.count) 项下载失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: $showsFailures, arrowEdge: .bottom) {
                    FailedDownloadsPanel(model: model, items: failedItems) { showsFailures = false }
                }
            }
            // 给用户的消息（同步失败、登录过期…）都收在铃铛里：以前直接铺在底栏上，
            // 一条长消息就会把底栏撑高，看着像"底部被拉起来了"
            NoticeBell(message: model.message) { model.clearMessage() }
            if model.queue.contains(where: { $0.state != .waiting && $0.state != .downloading }) {
                Button("清除记录") { model.clearFinished() }.buttonStyle(.link).fixedSize()
            }
            if model.isLoggedIn {
                Menu(model.accountName ?? "Steam") {
                    Button("退出登录") { model.signOut() }
                }
                .fixedSize()
            } else {
                Button("登录 Steam…") { model.showLogin(reason: nil) }
            }
            Button("同步订阅") { model.syncSubscriptions() }
                .disabled(model.isSyncing)
                .help("读取你在 Steam 上的订阅，把这台 Mac 上还没有的下载下来")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        // 正在从 Steam 下载 WE 自带素材（登录后自动）：先说这个
        if let progress = model.engineAssetsProgress, model.pendingCount == 0 {
            return String(localized: "正在从 Steam 下载 Wallpaper Engine 自带素材（\(Int(progress * 100))%）")
        }
        let waiting = model.pendingCount
        if waiting > 0 {
            if model.isPaused { return String(localized: "Steam 创意工坊：已暂停，还有 \(waiting) 个没下") }
            let current = model.queue.first { $0.state == .downloading }.flatMap { model.progress[$0.id] }
            guard let current else { return String(localized: "Steam 创意工坊：还有 \(waiting) 个在下载") }
            return String(localized: "Steam 创意工坊：还有 \(waiting) 个在下载（当前 \(Int((current * 100).rounded(.down)))%）")
        }
        return model.isLoggedIn ? String(localized: "Steam 创意工坊：已登录") : String(localized: "Steam 创意工坊：未登录（可以浏览，订阅和下载要登录）")
    }
}

/// 下载失败的明细：每项一行（编号、原因、重试），多了在里面滚动
struct FailedDownloadsPanel: View {
    @ObservedObject var model: WorkshopModel
    let items: [WorkshopModel.QueueItem]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("下载失败的 \(items.count) 项").font(.headline)
                Spacer()
                Button("全部重试") {
                    model.download(items.map(\.id))
                    onClose()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        if case .failed(let reason) = item.state {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.id).monospacedDigit().textSelection(.enabled)
                                Text(reason).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("重试") { model.download([item.id]) }.buttonStyle(.link)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 460)
    }
}

/// 状态栏右侧的铃铛：有提示时变成"带点的铃铛"，点开是一个小面板（长消息在里面滚动，
/// 不会把底栏撑高）。看完了点「知道了」清掉。
struct NoticeBell: View {
    let message: String?
    let onClear: () -> Void
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            Image(systemName: message == nil ? "bell" : "bell.badge.fill")
                .foregroundStyle(message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        }
        .buttonStyle(.plain)
        .help(message.map { "有提示：\($0.prefix(40))" } ?? "没有新提示")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("提示").font(.headline)
                if let message {
                    ScrollView {
                        Text(message).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    HStack {
                        Spacer()
                        Button("知道了") {
                            onClear()
                            isShowing = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text("没有新提示").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 380)
        }
    }
}

// MARK: - 登录框

/// 登录框：扫码（推荐）或者账户名称 + 密码。
///
/// 用系统标准的外观，不照着 Steam 客户端的样子做：这是壁坞自己的窗口，不能让人以为是 Steam 的登录页
/// （仿冒的登录界面正是钓鱼的样子，也有商标问题）。下面写清楚和 Valve 的关系、凭证存在哪、可能的风险。
/// 账号密码只发给 Steam，不保存；登录后订阅和下载都用这一个会话
struct SteamLoginSheet: View {
    @ObservedObject var model: WorkshopModel
    @State private var account = AppFolder.settings.string(forKey: WorkshopModel.lastAccountKey) ?? ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录 Steam").font(.title2.bold())
                    Text("\(MainMenu.appName)用你的 Steam 账号读取订阅、下载创意工坊的壁纸")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { model.closeLogin() } label: { Image(systemName: "xmark").font(.body.bold()) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭")
            }
            if let reason = model.loginReason {
                Text(reason).font(.callout).foregroundStyle(.orange)
            }
            step
            Divider()
            notice
        }
        .padding(24)
        .frame(width: 460)
    }

    /// 和 Valve 的关系、凭证存在哪、风险；链到隐私政策和使用条款
    private var notice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(MainMenu.appName)不是 Steam 或 Valve 的产品，用的是自己实现的 Steam 客户端（不是 Steam 官方软件）。密码只发给 Steam、不保存；登录后的凭证加密存在这台 Mac 上，退出登录即删除。Valve 有可能限制用非官方客户端登录的账号，是否登录请自行判断。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("隐私政策") { PublisherInfo.open(.privacy) }
                Button("使用条款") { PublisherInfo.open(.terms) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var step: some View {
        switch model.loginStep {
        case .idle, .failed:
            qrLogin
            credentials
        case .signingIn:
            progress("正在登录 Steam…")
        case .checkingCode:
            progress("正在核对验证码…")
        case .needsCode(let email):
            codeEntry(
                title: email ? "请查看你的邮箱" : "输入 Steam 手机令牌上的验证码",
                detail: email ? "Steam 给你的邮箱发了一个验证码。" : "打开手机上的 Steam 应用，在「Steam 令牌」里查看。")
        case .waitingForPhone(let canEnterCode):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("请在手机 Steam 应用上点「批准」")
                }
                if canEnterCode {
                    Text("或者输入 Steam 令牌上的验证码：").font(.callout).foregroundStyle(.secondary)
                    codeField
                } else {
                    Button("取消登录") { model.cancelSignIn() }.buttonStyle(.link).font(.caption)
                }
            }
        case .waitingForScan:
            qrWaiting
        }
    }

    /// 扫码登录：推荐的方式，不用在壁坞里输密码
    private var qrLogin: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.signInWithQRCode()
            } label: {
                Label("扫码登录（推荐）", systemImage: "qrcode").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("用手机上的 Steam 应用扫二维码确认，不用在这里输入密码。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 二维码 + 说明
    private var qrWaiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("用手机上的 Steam 应用扫这个二维码，然后点「批准」")
            HStack(alignment: .top, spacing: 16) {
                if let data = model.qrCodeImage, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .padding(8)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView().controlSize(.small).frame(width: 168, height: 168)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Steam 应用 → 右下角「≡」→ 扫码（或直接扫这个码）")
                        .font(.callout).foregroundStyle(.secondary)
                    if let url = model.qrChallengeURL {
                        Text(url).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Button("取消") { model.cancelSignIn() }.buttonStyle(.link)
                }
            }
        }
    }

    /// 账户名称 + 密码（备用）
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("或者用账户名称和密码登录").font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            TextField("Steam 账户名称", text: $account)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit(submit)
            if case .failed(let reason) = model.loginStep {
                Text(reason).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("忘记了账号或密码？") {
                    NSWorkspace.shared.open(URL(string: "https://help.steampowered.com/wizard/HelpWithLogin")!)
                }
                .buttonStyle(.link)
                .font(.caption)
                Spacer()
                Button("登录", action: submit)
                    .disabled(account.isEmpty || password.isEmpty)
            }
        }
    }

    private func codeEntry(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            codeField
        }
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .onSubmit(submitCode)
                Button("确定", action: submitCode).keyboardShortcut(.defaultAction).disabled(code.isEmpty)
            }
            if let error = model.codeError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Button("取消登录") { model.cancelSignIn() }.buttonStyle(.link).font(.caption)
        }
    }

    private func progress(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
            Spacer()
            Button("取消") { model.cancelSignIn() }.buttonStyle(.link)
        }
        .padding(.vertical, 20)
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty else { return }
        model.signIn(account: account, password: password)
        password = ""
    }

    private func submitCode() {
        guard !code.isEmpty else { return }
        model.submitCode(code)
        code = ""
    }
}
