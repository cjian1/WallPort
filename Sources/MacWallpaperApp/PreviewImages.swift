import AppKit
import CryptoKit
import DesktopHost
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WallpaperLibrary

/// 预览图：卡片出现时才加载（本机文件直接解码，创意工坊的先下载），缩成缩略图放在内存里；没有图时显示占位符号。
/// 原图是 GIF 动图时，鼠标停在上面才拿整张（本机的直接读，创意工坊的接着下完），盖在缩略图上动起来；移开就停，
/// 换回缩略图。一屏几十张一起动太费电、也太费流量（一页 15 张 GIF 要多下 10 MB、占单核 20%）
struct ThumbnailImage: View {
    let url: URL?
    var placeholder = "photo"
    @State private var image: NSImage?
    @State private var isHovering = false
    @State private var animation: AnimatedPreview?

    /// 鼠标停这么久才开始拿整张动图：只是划过去的卡片不下载
    static let hoverDelay = Duration.milliseconds(200)

    var body: some View {
        // 叠在底色上（而不是 ZStack 并排）：铺满的缩略图会比卡片大，并排的话整块被它撑大，
        // 动图视图（AppKit 的视图）跟着变大、画到卡片外面去；叠加层只按底色（卡片）的大小摆
        Rectangle().fill(Color.secondary.opacity(0.15))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: placeholder).font(.system(size: 26)).foregroundStyle(.secondary)
                }
            }
            // 第一帧出来之前是透明的，看到的还是缩略图。不参与点按测试：悬停、点击、右键都按底下的卡片算，
            // 动图出现时不会被当成鼠标移到了别的视图上（那样会马上撤掉动图，来回闪）
            .overlay { if let animation { AnimatedImage(preview: animation).allowsHitTesting(false) } }
            .clipped()
            .onHover { isHovering = $0 }
            .task(id: url) {
                let loaded = await ThumbnailCache.shared.image(for: url)
                // 等的时候换了别的图（任务被取消）：不要拿旧图盖掉
                guard !Task.isCancelled else { return }
                image = loaded
            }
            .task(id: Playback(url: url, isHovering: isHovering, hasImage: image != nil)) { await play() }
    }

    private struct Playback: Equatable {
        let url: URL?
        let isHovering: Bool
        let hasImage: Bool
    }

    /// 鼠标停在上面：拿整张动图来播（内存里有的马上播，没有的停一会儿再拿）；移开时这个任务被取消，
    /// 还在下的不下了，动图撤掉
    private func play() async {
        animation = nil
        guard isHovering, image != nil, let url else { return }
        if let cached = ThumbnailCache.shared.cachedAnimation(for: url) {
            animation = cached
            return
        }
        try? await Task.sleep(for: Self.hoverDelay)
        guard !Task.isCancelled else { return }
        let loaded = await ThumbnailCache.shared.animation(for: url)
        guard !Task.isCancelled else { return }
        animation = loaded
    }
}

// MARK: - 动图

/// 一张能动的预览图：整张 GIF，以及开头要跳过的空帧
final class AnimatedPreview: Sendable {
    let data: Data
    /// 开头的空帧（全黑或全透明；视频壁纸的 GIF 预览常有一张），播放时不显示
    let leadingBlankFrames: Int

    /// 不是 GIF、或者只有一帧（不会动）时为 nil
    init?(data: Data) {
        guard WorkshopPreview.isGIF(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1
        else { return nil }
        self.data = data
        leadingBlankFrames = WorkshopPreview.leadingBlankFrames(in: source)
    }
}

/// 播放预览动图：按 GIF 自带的帧间隔，用 ImageIO 的 `CGAnimateImageDataWithBlock`（它在主线程按时回调每一帧）。
/// 和缩略图一样铺满、居中裁掉多出来的。鼠标移开、卡片划出去（视图拆掉）时停，窗口看不见（被挡住、最小化）时也停；
/// 开头的空帧不显示。不接收鼠标：点击、右键照样交给卡片
struct AnimatedImage: NSViewRepresentable {
    let preview: AnimatedPreview

    func makeNSView(context: Context) -> AnimatedImageView { AnimatedImageView() }

    func updateNSView(_ view: AnimatedImageView, context: Context) { view.preview = preview }

    static func dismantleNSView(_ view: AnimatedImageView, coordinator: ()) { view.preview = nil }
}

final class AnimatedImageView: NSView {
    var preview: AnimatedPreview? {
        didSet {
            guard preview !== oldValue else { return }
            playing = nil
            frameImage = nil
            layer?.contents = nil
            nextFrame = preview?.leadingBlankFrames ?? 0
            updatePlayback()
        }
    }
    /// 只在窗口看得见时播（测试里没有显示出来的窗口，关掉这一条）
    var requiresVisibleWindow = true
    /// 正在播的那一轮的编号，nil 表示停着。停下以后，那一轮下一次回调时发现编号对不上就结束
    private var playing: Int?
    private var rounds = 0
    /// 停下以后从哪一帧接着播
    private var nextFrame = 0
    /// 现在显示的这一帧
    private(set) var frameImage: CGImage?
    var isPlaying: Bool { playing != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 自己管图层的内容（AppKit 重画时不会拿空白盖掉当前这一帧）
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.contents = frameImage
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowOcclusionDidChange),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updatePlayback()
    }

    @objc private func windowOcclusionDidChange() {
        updatePlayback()
    }

    private var shouldPlay: Bool {
        guard preview != nil else { return false }
        return !requiresVisibleWindow || window?.occlusionState.contains(.visible) == true
    }

    private func updatePlayback() {
        guard shouldPlay else {
            playing = nil
            return
        }
        guard playing == nil, let preview else { return }
        rounds += 1
        let round = rounds
        playing = round
        let options = [kCGImageAnimationStartIndex: nextFrame] as CFDictionary
        let status = CGAnimateImageDataWithBlock(preview.data as CFData, options) { [weak self] index, image, stop in
            MainActor.assumeIsolated {
                guard let self, self.playing == round else {
                    stop.pointee = true
                    return
                }
                self.show(frame: index, image: image)
            }
        }
        if status != noErr { playing = nil }
    }

    /// 换上这一帧；开头的空帧跳过，留着上一帧
    func show(frame index: Int, image: CGImage) {
        nextFrame = index
        guard let preview, index >= preview.leadingBlankFrames else { return }
        frameImage = image
        layer?.contents = image
    }
}

// MARK: - 缓存

/// 缩略图和预览动图的缓存。解码、下载在后台线程；同一张图的缩略图同时只做一次。
/// 内存里按字节设上限（系统内存紧张时 NSCache 也会自己清），壁纸库窗口关掉时整个清空——
/// 壁坞常驻后台，不能一直占着几百张缩略图的内存。
///
/// 创意工坊的预览图先只下到能解出一帧看得见的为止（见 `WorkshopPreview`，GIF 动图从 1 MB 降到几十 KB），卡片马上有图；
/// 是 GIF 动图的话，鼠标停在卡片上时再接着下完、动起来（`animation(for:)`），鼠标移开就不下了。
/// 下好的存在磁盘上（壁坞文件夹的 Cache/Thumbnails），下次打开不用再下：缩略图按原图是什么存成 `<哈希>-3.jpg`（静态图）
/// 或 `<哈希>-3-gif.jpg`（GIF），GIF 的整张下过以后另存 `<哈希>-3.gif`。动图的第一帧是空帧（视频壁纸的 GIF 预览
/// 常是全黑的第一帧）时，缩略图用后面那帧，本机的预览图也一样
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// 卡片约 260×118 点，2 倍屏要 520 像素宽
    nonisolated static let maxPixelSize = 520
    /// 磁盘上最多占多大（缩略图几十 KB 一张，整张 GIF 几百 KB 到 1 MB）：超过就删最久没用的，删到四分之三
    nonisolated static let diskByteLimit = 512 * 1024 * 1024
    private let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    /// 能动的预览（整张 GIF 的数据），鼠标停过的才有
    private let animations: NSCache<NSURL, AnimatedPreview> = {
        let cache = NSCache<NSURL, AnimatedPreview>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    /// GIF 只下了开头一段（做缩略图够了）：鼠标停上来时接着它往下下，不用从头再下
    private let gifHeads: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private var loading: [URL: Task<Still?, Never>] = [:]
    /// 预览图一页 30 张，同一台服务器多开几条连接
    private let client = URLSessionHTTPClient(connectionsPerHost: 10)
    /// 下整张动图用的：和缩略图分开，不挤占还没出图的卡片
    private let animationClient = URLSessionHTTPClient(connectionsPerHost: 4)
    private let diskDirectory: URL? = AppFolder.isActive
        ? AppFolder.cache.appendingPathComponent("Thumbnails", isDirectory: true) : nil

    /// 做好的缩略图；GIF 只下了开头一段时带上这一段
    struct Still: Sendable {
        let image: CGImage
        var gifHead: Data? = nil
    }

    private init() {
        if let diskDirectory {
            Task.detached(priority: .background) { Self.pruneDisk(diskDirectory) }
        }
    }

    func image(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let cached = images.object(forKey: url as NSURL) { return cached }
        let task: Task<Still?, Never>
        if let running = loading[url] {
            task = running
        } else {
            let client = client
            let directory = url.isFileURL ? nil : diskDirectory
            task = Task.detached(priority: .utility) { await Self.loadStill(url, client: client, directory: directory) }
            loading[url] = task
        }
        let still = await task.value
        loading[url] = nil
        guard let still else { return nil }
        if let head = still.gifHead { gifHeads.setObject(head as NSData, forKey: url as NSURL, cost: head.count) }
        if let cached = images.object(forKey: url as NSURL) { return cached }
        let image = NSImage(cgImage: still.image, size: .zero)
        images.setObject(image, forKey: url as NSURL, cost: still.image.bytesPerRow * still.image.height)
        return image
    }

    /// 内存里已经有的动图（鼠标停上来时不用等）
    func cachedAnimation(for url: URL) -> AnimatedPreview? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        return animations.object(forKey: url as NSURL)
    }

    /// 预览图是 GIF 动图时的整张数据（鼠标停在卡片上时调，在 `image(for:)` 之后）。不是动图时为 nil；
    /// 系统设置里打开了"减弱动态效果"时也是 nil。要下载的话跟着调用的任务走：鼠标移开（任务取消）就不下了
    func animation(for url: URL?) async -> AnimatedPreview? {
        guard let url, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        if let cached = animations.object(forKey: url as NSURL) { return cached }
        let head = gifHeads.object(forKey: url as NSURL).map { $0 as Data }
        guard let animation = await Self.loadAnimation(
            url, head: head, client: animationClient, directory: url.isFileURL ? nil : diskDirectory)
        else { return nil }
        gifHeads.removeObject(forKey: url as NSURL)
        animations.setObject(animation, forKey: url as NSURL, cost: animation.data.count)
        return animation
    }

    func removeAll() {
        images.removeAllObjects()
        animations.removeAllObjects()
        gifHeads.removeAllObjects()
    }

    // MARK: 加载

    /// 缩略图：本机文件直接做；创意工坊的先看磁盘缓存，没有再下（下到够做缩略图为止），按原图是什么存起来
    nonisolated static func loadStill(_ url: URL, client: any HTTPClient, directory: URL?) async -> Still? {
        if url.isFileURL {
            return CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { WorkshopPreview.thumbnail(of: $0, maxPixelSize: maxPixelSize) }
                .map { Still(image: $0) }
        }
        if let directory, let entry = diskEntry(for: url, in: directory) {
            switch entry {
            case .gif(let image), .still(let image), .unknown(let image): return Still(image: image)
            }
        }
        guard let fetched = try? await WorkshopPreview.fetch(url, client: client, maxPixelSize: maxPixelSize) else {
            return nil
        }
        guard let gif = fetched.gif else {
            if let directory { save(fetched.thumbnail, to: directory.appendingPathComponent(stillName(url))) }
            return Still(image: fetched.thumbnail)
        }
        if let directory {
            save(fetched.thumbnail, to: directory.appendingPathComponent(gifThumbnailName(url)))
            // 小 GIF 一次就下完了：整张也存上，鼠标停上来时不用再下
            if fetched.isComplete { saveGIF(gif, for: url, in: directory) }
        }
        return Still(image: fetched.thumbnail, gifHead: fetched.isComplete ? nil : gif)
    }

    /// 整张 GIF：本机文件直接读；创意工坊的先看磁盘缓存，没有就下——知道是 GIF 的（缩略图存成了 GIF 的，或者开头那段
    /// 还在手里）直接下（有开头那段就接着它下完）；以前的版本存的缩略图不知道原图是什么，先问一下是不是 GIF。
    /// 下完存进缓存。不是动图时为 nil
    nonisolated static func loadAnimation(
        _ url: URL, head: Data?, client: any HTTPClient, directory: URL?
    ) async -> AnimatedPreview? {
        if url.isFileURL {
            return (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(AnimatedPreview.init(data:))
        }
        var knownGIF = head != nil
        if let directory {
            let gif = directory.appendingPathComponent(gifName(url))
            if let data = try? Data(contentsOf: gif) {
                touch(gif)
                return AnimatedPreview(data: data)
            }
            if exists(stillName(url), in: directory) { return nil }
            knownGIF = knownGIF || exists(gifThumbnailName(url), in: directory)
        }
        let data: Data
        do {
            if let head {
                data = try await WorkshopPreview.remainder(of: head, url: url, client: client)
            } else if knownGIF {
                data = try await WorkshopPreview.download(url, client: client)
            } else {
                let isGIF = try await WorkshopPreview.isGIF(at: url, client: client)
                if let directory { settleOldThumbnail(url, in: directory, isGIF: isGIF) }
                guard isGIF else { return nil }
                data = try await WorkshopPreview.download(url, client: client)
            }
        } catch {
            return nil
        }
        if let directory { saveGIF(data, for: url, in: directory) }
        return AnimatedPreview(data: data)
    }

    // MARK: 磁盘

    /// 磁盘上存的缩略图
    enum DiskEntry {
        /// 原图是 GIF
        case gif(CGImage)
        /// 原图是静态图
        case still(CGImage)
        /// 以前的版本存的，不知道原图是什么（鼠标停上来时 `loadAnimation` 联网问一下）
        case unknown(CGImage)
    }

    nonisolated static func diskEntry(for url: URL, in directory: URL) -> DiskEntry? {
        let gifThumbnail = directory.appendingPathComponent(gifThumbnailName(url))
        if let image = decode(gifThumbnail) {
            touch(gifThumbnail)
            return .gif(image)
        }
        let still = directory.appendingPathComponent(stillName(url))
        if let image = decode(still) {
            touch(still)
            return .still(image)
        }
        // 整张 GIF 还在、缩略图被清理掉了：从整张重做
        if let data = try? Data(contentsOf: directory.appendingPathComponent(gifName(url))),
           let image = WorkshopPreview.thumbnail(of: data, maxPixelSize: maxPixelSize) {
            save(image, to: gifThumbnail)
            return .gif(image)
        }
        for old in oldNames(url).map(directory.appendingPathComponent) {
            guard let image = decode(old) else { continue }
            // 更早的版本总取第一帧：第一帧是空帧也照样存成了黑图，删掉重做（重做时会往后找看得见的帧）
            guard !WorkshopPreview.isBlank(image) else {
                try? FileManager.default.removeItem(at: old)
                continue
            }
            touch(old)
            return .unknown(image)
        }
        return nil
    }

    private nonisolated static func saveGIF(_ data: Data, for url: URL, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(gifName(url)), options: .atomic)
    }

    /// 以前的版本存的缩略图，问过以后知道原图是什么：改成现在的名字接着用
    nonisolated static func settleOldThumbnail(_ url: URL, in directory: URL, isGIF: Bool) {
        let target = directory.appendingPathComponent(isGIF ? gifThumbnailName(url) : stillName(url))
        for old in oldNames(url).map(directory.appendingPathComponent) {
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: old)
            } else {
                try? FileManager.default.moveItem(at: old, to: target)
            }
        }
    }

    private nonisolated static func exists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    /// 读存下的缩略图（在后台线程解好，不留到主线程画的时候再解）
    private nonisolated static func decode(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 碰一下修改时间：清理时按它判断最近有没有用过
    private nonisolated static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// 地址 → 文件名（Steam 的预览图地址里带着内容的哈希，图换了地址也会换）。"-3" 是现在的存法：缩略图的名字
    /// 记着原图是不是 GIF；以前的 "-2"（第一帧是空帧时往后找）和更早没有后缀的（总取第一帧）不知道原图是什么
    nonisolated static func stillName(_ url: URL) -> String { urlHash(url) + "-3.jpg" }

    nonisolated static func gifThumbnailName(_ url: URL) -> String { urlHash(url) + "-3-gif.jpg" }

    nonisolated static func gifName(_ url: URL) -> String { urlHash(url) + "-3.gif" }

    nonisolated static func oldNames(_ url: URL) -> [String] { [urlHash(url) + "-2.jpg", urlHash(url) + ".jpg"] }

    private nonisolated static func urlHash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func save(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// 超过上限时删掉最久没用过的，删到上限的四分之三
    nonisolated static func pruneDisk(_ directory: URL, limit: Int = diskByteLimit) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        let entries = files.map { file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file: file, used: values?.contentModificationDate ?? .distantPast, size: values?.totalFileAllocatedSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        for entry in entries.sorted(by: { $0.used < $1.used }) where total > limit * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.file)
            total -= entry.size
        }
    }
}
