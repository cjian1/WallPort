import CoreImage
import DesktopHost
import Foundation
import ImageIO
import SteamProtocol

/// 创意工坊的**原生会话**：登录、订阅、我的订阅、下载都走 Steam 的客户端协议（CM），
/// 不需要 SteamCMD，也不需要 Steam 社区的网页会话。
///
/// 登录两种方式都支持：
/// - 账号密码（`BeginAuthSessionViaCredentials`，要验证码就在同一个登录框里填）；
/// - 扫码（`BeginAuthSessionViaQR`，手机上确认，不用输密码）。
///
/// 登录成功后 refresh token 由调用方存进本机加密文件（`SteamCMSessionStore`），之后启动直接复用（"一次确认"）。
public struct SteamCMSession: Codable, Equatable, Sendable {
    public var accountName: String
    public var steamID: String
    /// 登 CM 用的长期令牌（约 200 天）
    public var refreshToken: String
    /// 短期访问令牌（约一天），现在只留作显示/排查
    public var accessToken: String?

    public init(accountName: String, steamID: String, refreshToken: String, accessToken: String? = nil) {
        self.accountName = accountName
        self.steamID = steamID
        self.refreshToken = refreshToken
        self.accessToken = accessToken
    }
}

/// 扫码登录时把 challenge_url 画成二维码（手机 Steam App 扫）
public enum SteamLoginQRCode {
    public static func imageData(for text: String, scale: CGFloat = 10) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension WorkshopItem {
    /// 从 CM 的条目详情转成界面用的条目（浏览页那份是网页 JSON，字段不同）
    public init(details: PublishedFileInfo, appID: UInt32) {
        self.init(
            id: String(details.id),
            title: details.title.isEmpty ? String(details.id) : details.title,
            previewURL: details.previewURL.flatMap { URL(string: $0) },
            subscriptions: Int(details.subscriptions), favorited: Int(details.favorited),
            fileSize: Int64(details.fileSize),
            updated: details.timeUpdated > 0
                ? Date(timeIntervalSince1970: TimeInterval(details.timeUpdated)) : nil,
            tags: details.tags,
            subscribedAt: details.timeSubscribed > 0
                ? Date(timeIntervalSince1970: TimeInterval(details.timeSubscribed)) : nil)
    }
}

/// 一次会话里的所有创意工坊操作。
///
/// 会话（账号 + refresh token）由调用方持有并在每个操作里传进来：应用启动时从本机加密文件里同步读出，
/// 所以"后台还在连 CM"的时候点订阅 / 下载也不会被当成没登录。
///
/// 连接的管理（应用里一条已登录连接会用很久）：
/// - 登录后的连接会按 Steam 给的间隔发心跳；真断了（换网络、睡眠、被 CM 回收）也没关系——
///   每个操作发现连接断了会**用会话里的 refresh token 重新登一次 CM、再试一次**，用户不用重新登录；
/// - 只有 Steam 明确不认这个令牌（过期、被撤销）才报 `notLoggedIn`，界面据此让用户重新登录；
/// - 登录过程（认证会话）用单独的一条未登录连接，不会顶掉已经登录的那一条。
public actor WorkshopNative {
    public enum Failure: Error, LocalizedError, Equatable {
        /// 没有会话，或者 Steam 不认存着的会话了（要重新登录）
        case notLoggedIn
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notLoggedIn: String(localized: "要先登录 Steam")
            case .failed(let reason): reason
            }
        }
    }

    /// 启动时用存下来的会话连 CM 的结果
    public enum RestoreResult: Sendable, Equatable {
        case connected(SteamCMSession)
        /// Steam 不认这个会话了（令牌过期 / 被撤销）：要重新登录
        case expired
        /// 暂时连不上（没网、Steam 维护）：会话留着，之后的操作会自己重连
        case unreachable(String)
    }

    /// 扫码登录：把 `challengeURL` 画成二维码让用户扫，然后 `waitForLogin` 等确认
    public struct QRPending: Sendable {
        public let challengeURL: String
        let pending: CMAuthSession.Pending
    }

    /// 账号密码登录：要验证码 / 手机确认时交给界面
    public struct PasswordPending: Sendable {
        public let accountName: String
        /// 可以填验证码（邮件 / 手机令牌）
        public let needsCode: CMAuthSession.Guard?
        /// 可以在手机上点确认
        public let needsConfirmation: CMAuthSession.Guard?
        let pending: CMAuthSession.Pending
    }

    public static let appID: UInt32 = 431_960

    private let serverList: @Sendable () async throws -> [URL]
    private let makeConnection: @Sendable () -> SteamCMConnection
    private var servers: [URL] = []
    /// 已登录的连接（订阅、下载都用它）和它是用哪枚 refresh token 登的
    private var connection: SteamCMConnection?
    private var connectionToken: String?
    private var cellID: UInt32 = 0
    /// 正在登 CM（几个操作同时发现要重连时共用同一次）
    private var connecting: Task<SteamCMConnection, any Error>?
    private var connectingToken: String?
    /// 登录过程（认证会话）用的未登录连接
    private var authConnection: SteamCMConnection?

    public init() {
        self.init(
            servers: { try await SteamCMConnection.webSocketServers() },
            makeConnection: { SteamCMConnection() })
    }

    /// 测试用：换掉服务器列表和连接（假的 CM），不联网
    public init(
        servers: @escaping @Sendable () async throws -> [URL],
        makeConnection: @escaping @Sendable () -> SteamCMConnection
    ) {
        serverList = servers
        self.makeConnection = makeConnection
    }

    // MARK: - 会话

    /// 启动时：用存下来的会话连上 CM。连不上（没网）时调用方把会话留着就行，之后的操作会自己重连
    public func restore(_ stored: SteamCMSession) async -> RestoreResult {
        do {
            _ = try await loggedInConnection(for: stored)
            return .connected(stored)
        } catch Failure.notLoggedIn {
            return .expired
        } catch {
            return .unreachable(Self.describe(error))
        }
    }

    /// 退出登录：关掉已登录的连接
    public func logOut() async {
        connecting?.cancel()
        connecting = nil
        connectingToken = nil
        await connection?.close()
        connection = nil
        connectionToken = nil
    }

    // MARK: - 登录

    /// 扫码登录第一步：拿到二维码地址
    public func beginQRLogin() async throws -> QRPending {
        let connection = try await newAuthConnection()
        do {
            let (pending, url) = try await connection.beginAuthSessionViaQR()
            return QRPending(challengeURL: url, pending: pending)
        } catch {
            await dropAuthConnection(connection)
            throw Failure.failed(Self.describe(error))
        }
    }

    /// 扫码登录第二步：等手机上确认。二维码过期换新时 `onNewChallenge` 收到新地址（界面要跟着换图）
    public func waitForLogin(
        _ qr: QRPending, onNewChallenge: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SteamCMSession {
        let tokens = try await pollForTokens(qr.pending, timeout: .seconds(300), onNewChallenge: onNewChallenge)
        return try await finishLogin(tokens)
    }

    /// 账号密码登录第一步
    public func beginPasswordLogin(account: String, password: String) async throws -> PasswordPending {
        let connection = try await newAuthConnection()
        do {
            let key = try await connection.passwordRSAPublicKey(accountName: account)
            let encrypted = try SteamRSA.encrypt(
                password: password, modulusHex: key.modulus, exponentHex: key.exponent)
            let pending = try await connection.beginAuthSession(
                accountName: account, encryptedPassword: encrypted, timestamp: key.timestamp,
                machineID: CMRequest.machineID(accountName: account))
            return PasswordPending(
                accountName: account,
                needsCode: pending.guards.first(where: \.needsCode),
                needsConfirmation: pending.guards.first(where: \.isConfirmation),
                pending: pending)
        } catch {
            await dropAuthConnection(connection)
            throw Failure.failed(Self.describeLogin(error))
        }
    }

    /// 账号密码登录第二步（要验证码时）：交验证码。填错了抛错，可以再填
    public func submitCode(_ code: String, to login: PasswordPending) async throws {
        guard let guardType = login.needsCode?.type else { throw Failure.failed(String(localized: "这次登录不用填验证码")) }
        do {
            // 未登录的连接大约一分钟就会被 CM 回收（等邮件的工夫就可能断了）：断了就换一条再交
            do {
                try await currentAuthConnection().submitGuardCode(code, type: guardType, to: login.pending)
            } catch where Self.isConnectionProblem(error) {
                await dropAuthConnection()
                try await currentAuthConnection().submitGuardCode(code, type: guardType, to: login.pending)
            }
        } catch {
            throw Failure.failed(Self.describeLogin(error))
        }
    }

    /// 账号密码登录第三步：等令牌（手机上确认 / 验证码提交之后）
    public func waitForLogin(_ login: PasswordPending) async throws -> SteamCMSession {
        let tokens = try await pollForTokens(login.pending, timeout: .seconds(600), onNewChallenge: { _ in })
        return try await finishLogin(tokens)
    }

    /// 放弃正在进行的登录（关掉认证用的连接）
    public func cancelLogin() async {
        await authConnection?.close()
        authConnection = nil
    }

    /// 轮询到令牌为止。认证会话按 `client_id` / `request_id` 走、不绑连接：连接断了就换一条接着等。
    /// 调用方取消（用户点了"取消"）时立刻停下
    private func pollForTokens(
        _ start: CMAuthSession.Pending, timeout: Duration,
        onNewChallenge: @Sendable (String) -> Void
    ) async throws -> CMAuthSession.Tokens {
        var pending = start
        let deadline = ContinuousClock.now + timeout
        var failures = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let connection = try await currentAuthConnection()
                let before = pending.challengeURL
                if let tokens = try await connection.pollAuthSession(&pending) { return tokens }
                if let url = pending.challengeURL, url != before { onNewChallenge(url) }
                failures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where error is Failure || Self.isConnectionProblem(error) {
                // 连接断了 / 暂时连不上：换一条接着等
                failures += 1
                guard failures <= 10 else { throw Failure.failed(String(localized: "连不上 Steam（\(Self.describe(error))）")) }
                await dropAuthConnection()
            } catch {
                // Steam 明确回了失败（会话过期、在手机上点了拒绝…）：不再等
                throw Failure.failed(String(localized: "登录没有完成：\(Self.describeLogin(error))"))
            }
            try await Task.sleep(for: .seconds(max(2, pending.interval)))
        }
        throw Failure.failed(String(localized: "等确认超时，请重新登录"))
    }

    /// 拿到令牌之后**用一条新连接登 CM**（和命令行里实测通过的做法一样），认证用的连接关掉
    private func finishLogin(_ tokens: CMAuthSession.Tokens) async throws -> SteamCMSession {
        await dropAuthConnection()
        let refresh = tokens.refreshToken ?? tokens.accessToken
        let result: (connection: SteamCMConnection, steamID: UInt64, cellID: UInt32)
        do {
            result = try await connectAndLogOn(refreshToken: refresh, accountName: tokens.accountName)
        } catch Failure.notLoggedIn {
            throw Failure.failed(String(localized: "Steam 不认这次登录拿到的令牌，请再试一次"))
        }
        connecting?.cancel()
        connecting = nil
        connectingToken = nil
        await adopt(result, token: refresh)
        return SteamCMSession(
            accountName: tokens.accountName, steamID: String(result.steamID),
            refreshToken: refresh, accessToken: tokens.accessToken)
    }

    // MARK: - 订阅 / 我的订阅

    public func subscribedFiles(session: SteamCMSession, includeTags: Bool = false) async throws -> [WorkshopItem] {
        let steamID = UInt64(session.steamID) ?? SteamJWT.steamID(session.refreshToken) ?? 0
        let files = try await withConnection(session) { connection in
            try await connection.subscribedFiles(appID: Self.appID, steamID: steamID, includeTags: includeTags)
        }
        return files.map { WorkshopItem(details: $0, appID: Self.appID) }
    }

    public func setSubscribed(_ subscribed: Bool, id: String, session: SteamCMSession) async throws {
        guard let itemID = UInt64(id) else { throw Failure.failed(String(localized: "编号不对")) }
        try await withConnection(session) { connection in
            try await connection.setSubscribed(subscribed, id: itemID, appID: Self.appID)
        }
    }

    /// 下载一件创意工坊内容到 `directory/<编号>`。整件下完才换进去：失败时原来的（或者什么都没有）保持不变
    public func download(
        id: String, to directory: URL, session: SteamCMSession, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let itemID = UInt64(id) else { throw Failure.failed(String(localized: "编号不对")) }
        let appID = Self.appID
        // 1. CM 上的几步（条目详情 → depot 密钥 → 内容服务器 → 清单请求码），连接断了会重连重试
        let plan = try await withConnection(session) { [cellID] connection in
            let details = try await connection.call(
                SteamServiceCall.method("PublishedFile.GetDetails"),
                request: SteamServiceCall.publishedFileDetails(ids: [itemID], appID: appID))
            let items = details.values(1).compactMap { value -> PublishedFileInfo? in
                guard case .bytes(let data) = value, let message = try? ProtoMessage(data) else { return nil }
                return PublishedFileInfo(message)
            }
            guard let item = items.first, item.result == 1, item.contentHandle != 0 else {
                throw Failure.failed(Self.describeItemResult(items.first?.result ?? 0))
            }
            let depotKey = try await connection.depotDecryptionKey(appID: appID, depotID: appID)
            let serversBody = try await connection.call(
                SteamServiceCall.method("ContentServerDirectory.GetServersForSteamPipe"),
                request: SteamServiceCall.contentServers(cellID: cellID))
            let hosts = SteamContentServer.list(from: serversBody)
                .filter { $0.supportsHTTPS && $0.serves(appID: appID) }.map(\.host)
                + ["steampipe.akamaized.net", "cache1-lax1.steamcontent.com"]
            let requestCode = try await connection.manifestRequestCode(
                appID: appID, depotID: appID, manifestID: item.contentHandle)
            return (manifestID: item.contentHandle, depotKey: depotKey, hosts: hosts, requestCode: requestCode)
        }
        // 2. 内容服务器上的几步（清单 → 分块），不需要 CM 连接
        do {
            let downloader = UGCContentDownloader()
            let manifest = try await downloader.manifest(
                depot: appID, manifestID: plan.manifestID, requestCode: plan.requestCode,
                hosts: plan.hosts, depotKey: plan.depotKey)
            let target = directory.appendingPathComponent(id, isDirectory: true)
            let total = max(1, manifest.totalBytes)
            try await downloader.install(manifest, at: target, hosts: plan.hosts, depotKey: plan.depotKey) { state in
                progress?(Double(state.bytesDone) / Double(total))
            }
            return target
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Failure.failed(Self.describe(error))
        }
    }

    // MARK: - 连接

    /// 在已登录的连接上做一件事；连接断了（或等回包超时）就重新登一次 CM 再试一次
    private func withConnection<T: Sendable>(
        _ session: SteamCMSession, _ body: @Sendable (SteamCMConnection) async throws -> T
    ) async throws -> T {
        let first = try await loggedInConnection(for: session)
        do {
            return try await body(first)
        } catch where Self.isConnectionProblem(error) {
            await first.close()
            if connection === first {
                connection = nil
                connectionToken = nil
            }
            do {
                return try await body(try await loggedInConnection(for: session))
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.failed(Self.describe(error))
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(Self.describe(error))
        }
    }

    /// 已登录的连接：还连着、而且是这个会话登的就直接用；否则用会话里的 refresh token 重新登一次
    /// （几个操作同时发现要重连时共用同一次登录）
    private func loggedInConnection(for session: SteamCMSession) async throws -> SteamCMConnection {
        let token = session.refreshToken
        if let current = connection {
            if connectionToken == token, await current.isConnected { return current }
            connection = nil
            connectionToken = nil
            await current.close()
        }
        if let connecting, connectingToken == token { return try await connecting.value }
        let task = Task { () async throws -> SteamCMConnection in
            let result = try await self.connectAndLogOn(refreshToken: token, accountName: session.accountName)
            await self.adopt(result, token: token)
            return result.connection
        }
        connecting = task
        connectingToken = token
        defer {
            if connecting == task {
                connecting = nil
                connectingToken = nil
            }
        }
        return try await task.value
    }

    /// 登好的连接收下来（换掉原来那条）
    private func adopt(_ result: (connection: SteamCMConnection, steamID: UInt64, cellID: UInt32), token: String) async {
        if let old = connection, old !== result.connection { await old.close() }
        connection = result.connection
        connectionToken = token
        cellID = result.cellID
    }

    /// 连一台 CM 并用 refresh token 登录。Steam 明确不认令牌 → `notLoggedIn`；
    /// 连不上 / 这台 CM 忙 → 换下一台；都不行 → `failed`
    private func connectAndLogOn(
        refreshToken: String, accountName: String
    ) async throws -> (connection: SteamCMConnection, steamID: UInt64, cellID: UInt32) {
        let servers = Self.preferring(Self.lastGoodServer, in: try await serverCandidates())
        let steamID = SteamJWT.steamID(refreshToken) ?? 0
        var lastError = String(localized: "没有可用的 CM")
        for (attempt, server) in servers.prefix(6).enumerated() {
            try Task.checkCancellation()
            let connection = makeConnection()
            await connection.connect(to: server)
            do {
                // 正常不到 1 秒就登上了：前两台等 8 秒就换，连不上的服务器不用干等 15 秒
                let result = try await connection.logOn(
                    accessToken: refreshToken, accountName: accountName, steamID: steamID,
                    timeout: .seconds(attempt < 2 ? 8 : 15))
                if result.isOK {
                    Self.lastGoodServer = server
                    return (connection, result.steamID, result.cellID)
                }
                await connection.close()
                if Self.tokenRejected(result.eresult) { throw Failure.notLoggedIn }
                lastError = result.describe
                if !Self.tryAnotherServer(result.eresult) { throw Failure.failed(String(localized: "登录 Steam 失败：\(lastError)")) }
            } catch let failure as Failure {
                throw failure
            } catch {
                await connection.close()
                lastError = Self.describe(error)
            }
        }
        throw Failure.failed(String(localized: "连不上 Steam（\(lastError)）"))
    }

    /// 上次登上的那台 CM：下次先试它（App 里存在设置里；测试和工具不存）
    nonisolated static var lastGoodServer: URL? {
        get {
            guard AppFolder.isActive else { return nil }
            return AppFolder.settings.string(forKey: "workshop.lastCMServer").flatMap(URL.init(string:))
        }
        set {
            guard AppFolder.isActive else { return }
            AppFolder.settings.set(newValue?.absoluteString, forKey: "workshop.lastCMServer")
        }
    }

    /// 把上次登上的那台挪到最前面（它还在列表里时）
    static func preferring(_ server: URL?, in servers: [URL]) -> [URL] {
        guard let server, let index = servers.firstIndex(of: server) else { return servers }
        var ordered = servers
        ordered.remove(at: index)
        return [server] + ordered
    }

    /// 服务器列表只取一次；取不到就是没网
    private func serverCandidates() async throws -> [URL] {
        if servers.isEmpty {
            do {
                servers = try await serverList()
            } catch {
                throw Failure.failed(String(localized: "连不上 Steam（\(Self.describe(error))）"))
            }
        }
        guard !servers.isEmpty else { throw Failure.failed(String(localized: "连不上 Steam（没有可用的 CM）")) }
        return servers
    }

    /// 登录用的未登录连接（前几台里挑一台真的会回应服务调用的）
    private func currentAuthConnection() async throws -> SteamCMConnection {
        if let authConnection, await authConnection.isConnected { return authConnection }
        return try await newAuthConnection()
    }

    private func newAuthConnection() async throws -> SteamCMConnection {
        await cancelLogin()
        var lastError = String(localized: "没有可用的 CM")
        for server in try await serverCandidates().prefix(6) {
            try Task.checkCancellation()
            let connection = makeConnection()
            await connection.connect(to: server)
            do {
                // 用一次未登录服务调用确认这台真的在服务（有的 CM 只握手不干活）
                _ = try await connection.callUnauthenticated(
                    SteamServiceCall.method("Authentication.GetPasswordRSAPublicKey"),
                    request: CMAuthSession.passwordRSAPublicKeyRequest(accountName: "probe"),
                    timeout: .seconds(8))
                authConnection = connection
                return connection
            } catch {
                lastError = Self.describe(error)
                await connection.close()
            }
        }
        throw Failure.failed(String(localized: "连不上 Steam（\(lastError)）"))
    }

    private func dropAuthConnection(_ which: SteamCMConnection? = nil) async {
        guard let current = authConnection, which == nil || which === current else {
            await which?.close()
            return
        }
        await current.close()
        authConnection = nil
    }

    // MARK: - 错误

    /// 换条连接可能就好的错误（断线、超时、网络层错误）；Steam 明确回的失败不算
    static func isConnectionProblem(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, is Failure: false
        case let error as SteamCMError: error.isConnectionLoss
        case is URLError: true
        default: (error as NSError).domain == NSURLErrorDomain || (error as NSError).domain == NSPOSIXErrorDomain
        }
    }

    /// CM 不认令牌（过期、被撤销、账号密码类错误）：要重新登录
    static func tokenRejected(_ eresult: Int32) -> Bool {
        [5, 15, 18, 19, 26, 27, 63, 85].contains(eresult)
    }

    /// 这台 CM 暂时不行，换一台（NoConnection / Busy / Timeout / ServiceUnavailable / TryAnotherCM）
    static func tryAnotherServer(_ eresult: Int32) -> Bool {
        [3, 10, 16, 20, 48].contains(eresult)
    }

    private static func describe(_ error: any Error) -> String {
        if let failure = error as? Failure { return failure.errorDescription ?? String(localized: "失败") }
        if let cmError = error as? SteamCMError { return cmError.message }
        if let serverError = error as? ContentServerError { return serverError.errorDescription ?? String(localized: "下载失败") }
        return error.localizedDescription
    }

    /// 登录过程里常见的 EResult 翻成人话
    private static func describeLogin(_ error: any Error) -> String {
        switch (error as? SteamCMError)?.eresult {
        case 5?: String(localized: "账号或密码不对")
        case 65?, 88?: String(localized: "验证码不对，请再看一下")
        case 84?: String(localized: "登录太频繁，Steam 暂时拒绝了，请过一会儿再试")
        case 9?, 27?: String(localized: "这次登录已经过期，请重新登录")
        default: describe(error)
        }
    }

    /// 条目详情的 result（EResult）翻成人话
    private static func describeItemResult(_ result: UInt32) -> String {
        switch result {
        case 9: String(localized: "找不到这个条目（可能已被删除）")
        case 15: String(localized: "没有权限（这个账号可能没买 Wallpaper Engine，或者条目已被作者设为不公开）")
        default: String(localized: "读不到条目详情（Steam 返回 \(result)）")
        }
    }
}
