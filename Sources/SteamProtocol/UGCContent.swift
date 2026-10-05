import CryptoKit
import Foundation

/// 内容服务器（CDN）上的一个服务器。`ContentServerDirectory.GetServersForSteamPipe#1` 的回应里
/// 每台机器就是一条 `CContentServerDirectory_ServerInfo`（字段号见 Valve 的
/// `steammessages_contentsystem.steamclient.proto`）
public struct SteamContentServer: Sendable {
    /// `CDN` / `SteamCache`
    public let type: String
    /// 真正连的主机名（可能带端口），例如 `cache1-lax1.steamcontent.com`
    public let host: String
    /// TLS 上要发的 Host 头（有的 CDN 按 vhost 分流）；我们没有自己发 Host 头的接口，留作对照用
    public let vhost: String
    /// `https_support`：`mandatory`（只能 HTTPS）/ `optional` / `none`
    public let httpsSupport: String
    /// 只有这些 app 能用它（空表示都行）
    public let allowedAppIDs: [UInt32]

    /// 我们只走 HTTPS，`https_support` 明确写 `none` 的服务器跳过
    public var supportsHTTPS: Bool { httpsSupport != "none" }

    public init?(_ message: ProtoMessage) {
        guard let host = message.string(8), !host.isEmpty else { return nil }
        type = message.string(1) ?? ""
        self.host = host
        vhost = message.string(9) ?? host
        httpsSupport = message.string(12) ?? "optional"
        allowedAppIDs = message.values(13).compactMap { value in
            guard case .varint(let raw) = value else { return nil }
            return UInt32(truncatingIfNeeded: raw)
        }
    }

    /// 能不能给这个 app 用（`allowed_app_ids` 空表示不限）
    public func serves(appID: UInt32) -> Bool {
        allowedAppIDs.isEmpty || allowedAppIDs.contains(appID)
    }

    /// 按这台服务器拼分块地址：`https://<主机>/depot/<depot>/chunk/<sha 十六进制>`
    /// （`ServerInfo` 里没有"要不要 CDN 访问令牌"这个字段了，参考实现也只在有它时才调
    /// `GetCDNAuthToken`，所以这里不拼令牌）
    public func chunkURL(depot: UInt32, shaHex: String) -> URL? {
        URL(string: "https://\(host)/depot/\(depot)/chunk/\(shaHex.lowercased())")
    }

    /// `GetServersForSteamPipe#1` 的回包 → 服务器列表（只留 CDN / SteamCache）
    public static func list(from response: ProtoMessage) -> [SteamContentServer] {
        response.values(1).compactMap { value -> SteamContentServer? in
            guard case .bytes(let data) = value, let message = try? ProtoMessage(data),
                  let server = SteamContentServer(message)
            else { return nil }
            return server.type == "CDN" || server.type == "SteamCache" ? server : nil
        }
    }
}

/// 从内容服务器下载创意工坊内容：清单 → 分块 → 解密（depot 密钥）→ 解压 → 按偏移拼成文件。
///
/// 这是 M7.5-3 的核心：整条路走通之后就不需要 SteamCMD 了。每一步都用真实数据核对过：
/// 分块解密/解压的结果和 SteamCMD 下好的内容逐字节一致（`WallpaperTool steam-ugc`）。
public struct UGCContentDownloader: Sendable {
    /// 下载进度（文件数、分块数、字节数）
    public struct Progress: Sendable, Equatable {
        public var filesDone = 0
        public var filesTotal = 0
        public var chunksDone = 0
        public var chunksTotal = 0
        public var bytesDone: UInt64 = 0
        public var bytesTotal: UInt64 = 0

        public init() {}
    }

    /// 取一个地址的字节。真正联网时是 URLSession；测试里换成假的分块，就不需要网络
    public typealias Fetch = @Sendable (URL) async throws -> [UInt8]

    private let fetch: Fetch
    /// 所有服务器都临时失败时，第一轮重试前等多久（之后每轮加倍）
    private let retryDelay: Duration

    public init(session: URLSession = .shared) {
        self.init(fetch: { url in
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw ContentServerError(host: url.host() ?? "?", status: status) }
            return [UInt8](data)
        })
    }

    public init(fetch: @escaping Fetch, retryDelay: Duration = .seconds(1)) {
        self.fetch = fetch
        self.retryDelay = retryDelay
    }

    /// 取一枚分块并解成原始字节。分块编号（sha）就是它在 CDN 上的名字，也是解开之后的校验和
    public func chunk(
        shaHex: String, depot: UInt32, hosts: [String], depotKey: [UInt8]
    ) async throws -> [UInt8] {
        let data = try await fetch(path: "/depot/\(depot)/chunk/\(shaHex.lowercased())", hosts: hosts)
        let plain = try SteamChunkCipher.decrypt(data, key: depotKey)
        let content = try ChunkContainer.decompress(plain)
        let digest = Insecure.SHA1.hash(data: Data(content))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == shaHex.lowercased() else {
            throw SteamCMError("分块 \(shaHex.prefix(12))… 校验和对不上（拿到的是 \(actual.prefix(12))…）")
        }
        return content
    }

    /// 从 CDN 取清单。清单地址里的"请求码"要先用 CM 调
    /// `ContentServerDirectory.GetManifestRequestCode#1` 换（见 `SteamServiceCall.manifestRequestCode`）。
    /// 清单在 CDN 上是 zip 容器，而且**文件名是加密的**（用 depot 密钥解开）
    public func manifest(
        depot: UInt32, manifestID: UInt64, requestCode: UInt64, hosts: [String], depotKey: [UInt8]
    ) async throws -> ContentManifest {
        let data = try await fetch(path: "/depot/\(depot)/manifest/\(manifestID)/5/\(requestCode)",
                                   hosts: hosts)
        let parsed = try ContentManifest(data: Data(try ChunkContainer.decompress(data)))
        return try parsed.decryptingFilenames(depotKey: depotKey)
    }

    /// 按清单把整份内容下下来，写到 `directory` 里（文件名就是清单里的名字，可能带子目录）。
    ///
    /// - 目录条目（`EDepotFileFlag` 64）建成目录；符号链接条目跳过（清单来自网络，不在本机建链接）；
    /// - 每个文件的分块**直接写到文件里对应的偏移**，不把整个文件攒在内存里（视频壁纸常有几百 MB）；
    ///   先写到旁边的 `.<名字>.partial`，整个文件写完才改名成正式的名字。
    ///
    /// 应用里用 `install(_:at:…)`：它在这个基础上保证失败时不留下半截的项目。
    ///
    /// - Parameter concurrency: 同时下几个文件。创意工坊的壁纸文件少、个头大，一个个来就行（默认 1）；
    ///   WE 自带素材是几千个小文件，一个个来光等网络来回就要好几分钟
    @discardableResult
    public func download(
        _ manifest: ContentManifest, to directory: URL, hosts: [String], depotKey: [UInt8], concurrency: Int = 1,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Progress {
        guard !hosts.isEmpty else { throw SteamCMError(String(localized: "没有可用的内容服务器")) }
        let fileManager = FileManager.default
        let regularFiles = manifest.files.filter { !$0.isDirectory && !$0.isSymlink }
        var initial = Progress()
        initial.filesTotal = regularFiles.count
        initial.chunksTotal = regularFiles.reduce(0) { $0 + $1.chunks.count }
        initial.bytesTotal = regularFiles.reduce(0) { $0 + $1.size }
        let tracker = ProgressTracker(initial)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for entry in manifest.files where entry.isDirectory {
            let folder = try Self.outputURL(for: entry.relativePath, in: directory)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let depot = manifest.depotID
        let writeOne: @Sendable (ContentManifest.File) async throws -> Void = { file in
            let fileManager = FileManager.default
            let target = try Self.outputURL(for: file.relativePath, in: directory)
            let folder = target.deletingLastPathComponent()
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let partial = folder.appendingPathComponent(".\(target.lastPathComponent).partial")
            do {
                try await write(file, to: partial, hosts: hosts, depot: depot, depotKey: depotKey) { bytes in
                    // 先记上再回调（写成 progress?(tracker.update…) 的话，没给回调时连记都不记）
                    let state = tracker.update { $0.chunksDone += 1; $0.bytesDone += UInt64(bytes) }
                    progress?(state)
                }
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.moveItem(at: partial, to: target)
            } catch {
                try? fileManager.removeItem(at: partial)
                throw error
            }
            let state = tracker.update { $0.filesDone += 1 }
            progress?(state)
        }
        if concurrency <= 1 {
            for file in regularFiles {
                try Task.checkCancellation()
                try await writeOne(file)
            }
        } else {
            // 最多同时 `concurrency` 个；有一个失败就整体失败（其余的会被取消）
            try await withThrowingTaskGroup(of: Void.self) { group in
                var running = 0
                for file in regularFiles {
                    try Task.checkCancellation()
                    if running >= concurrency {
                        try await group.next()
                        running -= 1
                    }
                    group.addTask { try await writeOne(file) }
                    running += 1
                }
                try await group.waitForAll()
            }
        }
        return tracker.update { _ in }
    }

    /// 并发下载时各个文件一起更新进度
    private final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var state: Progress

        init(_ state: Progress) { self.state = state }

        /// 改一下，返回改完的样子
        func update(_ change: (inout Progress) -> Void) -> Progress {
            lock.withLock {
                change(&state)
                return state
            }
        }
    }

    /// 下载并**整体换进** `target`：先下到旁边的 `.downloading-<名字>`，全部成功后再替换原来的目录。
    /// 失败时 `target` 原样不动（壁纸库不会扫到只下了一半的项目），更新时旧版本多出来的文件也不会残留。
    /// 临时目录以 `.` 开头，壁纸库扫描时会跳过
    @discardableResult
    public func install(
        _ manifest: ContentManifest, at target: URL, hosts: [String], depotKey: [UInt8], concurrency: Int = 1,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Progress {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".downloading-\(target.lastPathComponent)", isDirectory: true)
        let previous = parent.appendingPathComponent(".replaced-\(target.lastPathComponent)", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        let state: Progress
        do {
            state = try await download(
                manifest, to: staging, hosts: hosts, depotKey: depotKey, concurrency: concurrency, progress: progress)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        try? fileManager.removeItem(at: previous)
        let hadPrevious = fileManager.fileExists(atPath: target.path)
        do {
            if hadPrevious { try fileManager.moveItem(at: target, to: previous) }
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            if hadPrevious, !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: previous, to: target)
            }
            try? fileManager.removeItem(at: staging)
            throw error
        }
        try? fileManager.removeItem(at: previous)
        return state
    }

    /// 把一个文件的分块按偏移写进 `url`（先按清单里的大小建好文件，再一块块填）
    private func write(
        _ file: ContentManifest.File, to url: URL, hosts: [String], depot: UInt32, depotKey: [UInt8],
        chunkWritten: (Int) -> Void
    ) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SteamCMError("建不了文件 \(url.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: file.size)
        for chunk in file.chunks.sorted(by: { $0.offset < $1.offset }) {
            try Task.checkCancellation()
            let data = try await self.chunk(shaHex: chunk.shaHex, depot: depot, hosts: hosts, depotKey: depotKey)
            guard data.count == Int(chunk.originalSize) else {
                throw SteamCMError("分块 \(chunk.shaHex.prefix(12))… 解出来 \(data.count) 字节，"
                    + "清单说 \(chunk.originalSize)")
            }
            guard chunk.offset <= file.size, UInt64(data.count) <= file.size - chunk.offset else {
                throw SteamCMError("分块 \(chunk.shaHex.prefix(12))… 的偏移越出文件")
            }
            try handle.seek(toOffset: chunk.offset)
            try handle.write(contentsOf: data)
            chunkWritten(data.count)
        }
        try handle.synchronize()
    }

    // MARK: - 细节

    /// 清单里的文件名可能带子目录，但不许写到目标目录外面（清单来自网络，别顺着它走）
    static func outputURL(for name: String, in directory: URL) throws -> URL {
        let root = directory.standardizedFileURL
        let target = root.appendingPathComponent(name).standardizedFileURL
        guard !name.isEmpty, target.path.hasPrefix(root.path + "/") else {
            throw SteamCMError("清单里的文件名越出了输出目录：\(name)")
        }
        return target
    }

    /// 依次试 `hosts` 里的服务器；哪台先成功算哪台（CDN 的分流和临时故障都靠它兜）。
    /// 一轮都失败、而且是临时性的（服务器忙不过来的 503 / 429、超时、断网）：等一会儿再试，最多再试两轮
    private func fetch(path: String, hosts: [String]) async throws -> [UInt8] {
        var lastError: (any Error)?
        for round in 0..<3 {
            if round > 0 {
                guard let lastError, Self.isTemporary(lastError) else { break }
                try await Task.sleep(for: retryDelay * (1 << (round - 1)))
            }
            for host in hosts {
                guard let url = URL(string: "https://\(host)\(path)") else {
                    lastError = SteamCMError("内容服务器地址不对：\(host)")
                    continue
                }
                do {
                    return try await fetch(url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? SteamCMError("取 \(path) 失败：没有可用的内容服务器")
    }

    /// 过一会儿再试多半就好的错误
    static func isTemporary(_ error: any Error) -> Bool {
        if let error = error as? ContentServerError { return error.isTemporary }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed].contains(error.code)
        }
        return false
    }
}

/// 内容服务器回的不是 200
public struct ContentServerError: LocalizedError, Sendable, Equatable {
    public let host: String
    public let status: Int

    public init(host: String, status: Int) {
        self.host = host
        self.status = status
    }

    /// 服务器临时忙不过来（5xx、429）：过一会儿再试多半就好
    public var isTemporary: Bool { status == 429 || (500...599).contains(status) }

    public var errorDescription: String? {
        isTemporary
            ? String(localized: "Steam 的内容服务器暂时忙不过来（\(host) 返回 HTTP \(status)），过一会儿点「重试」")
            : String(localized: "\(host) 返回 HTTP \(status)")
    }
}
