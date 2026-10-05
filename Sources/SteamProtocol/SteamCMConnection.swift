import Foundation

/// CM 连接底下的一帧：协议消息都是二进制，文本帧（比如限流提示）只记下来
public enum CMFrame: Sendable, Equatable {
    case binary([UInt8])
    case text(String)
}

/// CM 连接底下的收发通道。真实连接是 `URLSessionWebSocketTask`（`WebSocketCMTransport`）；
/// 测试里换成假的，就能不联网地验证"回包按 job 编号分发""断线后调用方立刻知道"这些行为
public protocol CMTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// 等下一帧；连接断了（包括自己 `close()`）就抛错
    func receive() async throws -> CMFrame
    func close()
}

/// CM（Steam 客户端协议）的 WebSocket 连接。
///
/// 为什么走 WebSocket 而不是 TCP：TCP 传输要先做 Diffie–Hellman 握手、再对每条消息加密和压缩；
/// WebSocket 传输跑在 TLS 之上、消息就是明文 protobuf，实现量小一个数量级，能力一样
/// （订阅、列订阅、拿 UGC 清单、下载都走同一套消息）。服务器列表由公开的
/// `ISteamDirectory/GetCMListForConnect`（cmtype=websocket）给出，形如
/// `wss://cmp2-lax1.steamserver.net:27018/cmsocket/`。
///
/// 收发模型：每个请求先登记"在等什么"（服务方法按 `jobid`，老式消息按消息号），再发出去；
/// 收到的消息按这个登记分给对应的调用方。**同一条连接上可以同时有好几个请求**（应用里读订阅列表、
/// 下载、取消订阅会并发），谁的回包归谁，互不吞掉。连接断了、被 Steam 下线时，所有在等的请求
/// 立刻失败（`SteamCMError.isConnectionLoss`），上层据此换一条连接重试。
public actor SteamCMConnection {
    public typealias TransportFactory = @Sendable (URL, @escaping @Sendable (String) -> Void) -> any CMTransport

    private let makeTransport: TransportFactory
    private var transport: (any CMTransport)?
    private var heartbeatTask: Task<Void, Never>?
    /// 正在等回应的请求（键是自增编号，超时 / 取消时按编号摘掉）
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiterID = 1
    private var receivedTypes: [UInt32] = []
    /// 连接层的错误（断开、被下线）。保留下来，后面的调用要能立刻看到
    private var connectionError: (any Error)?
    /// 登录后的 SteamID（服务方法的头部要带）
    private var steamID: UInt64 = 0
    /// 调试用：握手、断开这类连接级事件，以及收到的每一帧
    private var events: [String] = []

    private struct Waiter {
        let key: Key
        let continuation: CheckedContinuation<CMEnvelope.Decoded, any Error>
    }

    /// 在等什么：服务方法的回包按 `jobid_target`，老式消息（登录回应、depot 密钥）按消息号
    private enum Key: Equatable {
        case job(UInt64)
        case type(UInt32)
    }

    public init() {
        self.init(transportFactory: { url, note in WebSocketCMTransport(url: url, note: note) })
    }

    public init(transportFactory: @escaping TransportFactory) {
        makeTransport = transportFactory
    }

    /// 公开的 CM 服务器列表（按负载排序）
    public static func webSocketServers(using session: URLSession = .shared) async throws -> [URL] {
        var components = URLComponents(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/")!
        components.queryItems = [
            URLQueryItem(name: "cellid", value: "0"),
            URLQueryItem(name: "cmtype", value: "websocket"),
        ]
        let (data, _) = try await session.data(from: components.url!)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let servers = response["serverlist"] as? [[String: Any]]
        else { throw SteamCMError("CM 服务器列表读不出来") }
        return servers.compactMap { entry in
            guard let endpoint = entry["endpoint"] as? String else { return nil }
            // 参考实现只连 steamglobal 这个 realm 的服务器；别的 realm 上服务方法可能不被受理
            if let realm = entry["realm"] as? String, realm != "steamglobal" { return nil }
            if let type = entry["type"] as? String, type != "websockets" { return nil }
            return URL(string: "wss://\(endpoint)/cmsocket/")
        }
    }

    /// 连接并**先发一条 ClientHello**：CM 要先知道协议版本，不然接下来的登录会被当成没凭据
    public func connect(to url: URL) async {
        close()
        connectionError = nil
        let transport = makeTransport(url) { [weak self] text in Task { await self?.note(event: text) } }
        self.transport = transport
        startReceiving(transport)
        try? await transmit(
            CMEnvelope.encode(.clientHello, header: CMRequest.header(jobID: 0), body: CMRequest.clientHello()))
    }

    /// 连着、而且没断（断了之后要换一条新连接，这一条不会自己恢复）
    public var isConnected: Bool { transport != nil && connectionError == nil }

    public func close() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard let transport else { return }
        self.transport = nil
        transport.close()
        failAll(SteamCMError(String(localized: "连接已关闭"), connectionLoss: true))
    }

    /// 登录。`accessToken` 为 nil 时是匿名登录（用来验证协议本身，不需要任何凭据）
    public func logOn(
        accessToken: String? = nil, accountName: String = "", steamID: UInt64 = 0,
        framing: CMEnvelope.Framing = .plain,
        sendAccountName: Bool = false,
        includeMachineID: Bool = true, machineID: [UInt8]? = nil,
        headerSteamID: UInt64? = nil,
        timeout: Duration = .seconds(20)
    ) async throws -> CMLogOnResult {
        // **2026-09-29 实测的关键点**：带令牌登录时，消息头部的 steamid 必须是这个账号的 SteamID
        // （不是 0）。发 0 时 CM 一律回 EResult 5（"账号或密码不对"），发对了立刻成功——
        // 参考实现（steam-user）也是从令牌的 `sub` 里取 SteamID 放进头部。这里默认自动取。
        let effectiveSteamID = headerSteamID
            ?? (accessToken.flatMap { SteamJWT.steamID($0) } ?? (steamID != 0 ? steamID : 0))
        let body = accessToken.map {
            CMRequest.tokenLogon(
                accessToken: $0, accountName: accountName, steamID: steamID,
                sendAccountName: sendAccountName, includeMachineID: includeMachineID, machineID: machineID)
        }
            ?? CMRequest.anonymousLogon()
        let frame = CMEnvelope.encode(
            .clientLogon, header: CMRequest.header(jobID: 0, steamID: effectiveSteamID), body: body,
            framing: framing)
        let decoded: CMEnvelope.Decoded
        do {
            decoded = try await request(frame, awaiting: .type(EMsg.clientLogOnResponse.rawValue), timeout: timeout)
        } catch let error as SteamCMError where error.isConnectionLoss && error.message == Self.timedOut {
            let seen = receivedTypes.map(String.init).joined(separator: "、")
            throw SteamCMError("等登录回应超时（收到过这些消息：\(seen.isEmpty ? "没有" : seen)）", connectionLoss: true)
        }
        let result = Self.logOnResult(decoded.body, header: decoded.header)
        if result.isOK {
            self.steamID = result.steamID
            startHeartbeat(seconds: result.heartbeatSeconds)
        }
        return result
    }

    /// 调试用：这次连接里收到过的消息编号
    public func seenMessageTypes() -> [UInt32] { receivedTypes }

    /// 调一个 Steam 服务方法（EMsg 151 → 147）。方法名形如 `PublishedFile.GetDetails#1`，
    /// 请求是它的 request protobuf，回包是 response protobuf
    public func call(_ method: String, request: ProtoWriter, timeout: Duration = .seconds(20))
        async throws -> ProtoMessage
    {
        try await call(method, request: request, authenticated: true, timeout: timeout)
    }

    /// 还没登录时调服务方法（EMsg 9804）。认证服务就是这么用的——参考实现里，SteamClient 平台的
    /// 认证会话整个走 CM，而不是 Web API
    public func callUnauthenticated(
        _ method: String, request: ProtoWriter, timeout: Duration = .seconds(20)
    ) async throws -> ProtoMessage {
        try await call(method, request: request, authenticated: false, timeout: timeout)
    }

    private func call(
        _ method: String, request body: ProtoWriter, authenticated: Bool, timeout: Duration
    ) async throws -> ProtoMessage {
        let jobID = UInt64.random(in: 1...(UInt64.max / 2))
        let frame = CMEnvelope.encode(
            authenticated ? .serviceMethodCallFromClient : .serviceMethodCallFromClientNonAuthed,
            header: CMRequest.serviceHeader(jobID: jobID, method: method, steamID: steamID), body: body)
        let decoded: CMEnvelope.Decoded
        do {
            decoded = try await request(frame, awaiting: .job(jobID), timeout: timeout)
        } catch let error as SteamCMError where error.message == Self.timedOut {
            throw SteamCMError("\(method) 等回包超时", connectionLoss: true)
        }
        let eresult = decoded.header.int32(13) ?? 1
        guard eresult == 1 else {
            throw SteamCMError(
                "\(method) 返回 EResult \(eresult)" + (decoded.header.string(14).map { "（\($0)）" } ?? ""),
                eresult: eresult)
        }
        return decoded.body
    }

    /// 发一条普通的客户端消息，等指定类型的回应（EMsg 5438 → 5439 这种）。
    /// 统一服务方法走 `call`，这条是给"老式"的客户端消息用的
    public func send(
        _ type: EMsg, body: ProtoWriter, expecting response: EMsg, timeout: Duration = .seconds(20)
    ) async throws -> ProtoMessage {
        // 和登录一样用极简头部（steamid + client_sessionid），只是登录后再发就带上真实 steamid
        let frame = CMEnvelope.encode(type, header: CMRequest.header(jobID: 0, steamID: steamID), body: body)
        do {
            return try await request(frame, awaiting: .type(response.rawValue), timeout: timeout).body
        } catch let error as SteamCMError where error.message == Self.timedOut {
            throw SteamCMError("等 \(response) 回应超时", connectionLoss: true)
        }
    }

    /// 要某个 depot 的解密密钥（下载内容用）。密钥是内容密钥，不是账号凭据
    public func depotDecryptionKey(
        appID: UInt32, depotID: UInt32, timeout: Duration = .seconds(20)
    ) async throws -> [UInt8] {
        let body = try await send(
            .clientGetDepotDecryptionKey, body: CMRequest.depotDecryptionKey(appID: appID, depotID: depotID),
            expecting: .clientGetDepotDecryptionKeyResponse, timeout: timeout)
        let eresult = body.int32(1) ?? 2
        guard eresult == 1 else {
            throw SteamCMError("取 depot \(depotID) 的密钥失败（EResult \(eresult)）", eresult: eresult)
        }
        guard UInt32(truncatingIfNeeded: body.varint(2) ?? 0) == depotID else {
            throw SteamCMError("Steam 回的不是 depot \(depotID) 的密钥")
        }
        guard let key = body.bytes(3), !key.isEmpty else { throw SteamCMError("回包里没有密钥") }
        return key
    }

    /// 清单地址里的请求码（`GetManifestRequestCode#1`）。取清单不带它会 401
    public func manifestRequestCode(
        appID: UInt32, depotID: UInt32, manifestID: UInt64, branch: String = "public",
        timeout: Duration = .seconds(20)
    ) async throws -> UInt64 {
        let body = try await call(
            SteamServiceCall.method("ContentServerDirectory.GetManifestRequestCode"),
            request: SteamServiceCall.manifestRequestCode(
                appID: appID, depotID: depotID, manifestID: manifestID, branch: branch),
            timeout: timeout)
        guard let code = body.varint(1), code != 0 else { throw SteamCMError("回包里没有请求码") }
        return code
    }

    // MARK: - 收发

    private static let timedOut = "等消息超时"

    /// 先登记"在等什么"，再发出去，然后等分发过来的回应（登记在前：回包可能比 send 返回还快）
    private func request(
        _ frame: [UInt8], awaiting key: Key, timeout: Duration
    ) async throws -> CMEnvelope.Decoded {
        if let connectionError { throw Self.lost(connectionError) }
        guard let transport else { throw SteamCMError("还没有连接", connectionLoss: true) }
        let id = nextWaiterID
        nextWaiterID += 1
        // 超时用单独的定时任务来"叫醒"等待者（不能把等待放进 task group：超时后子任务被取消
        // 却永远不会结束，整个 group 会一直等它）
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.finish(id, throwing: SteamCMError(Self.timedOut, connectionLoss: true))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(key: key, continuation: continuation)
                Task { await self.transmit(frame, via: transport) }
            }
        } onCancel: {
            Task { await self.finish(id, throwing: CancellationError()) }
        }
    }

    private func transmit(_ frame: [UInt8]) async throws {
        guard let transport else { throw SteamCMError("还没有连接", connectionLoss: true) }
        try await transport.send(frame)
    }

    /// 发不出去就说明连接已经坏了：整条连接标记为断开（所有在等的请求一起失败）
    private func transmit(_ frame: [UInt8], via transport: any CMTransport) async {
        do {
            try await transport.send(frame)
        } catch {
            markDead(error)
        }
    }

    /// 收帧循环只弱引用连接：没人再用这条连接时（没 close 就被丢掉）它能被释放，释放时关掉通道，
    /// 不会靠收帧循环和心跳一直吊着一条没人管的已登录连接
    private func startReceiving(_ transport: any CMTransport) {
        Task.detached { [weak self] in
            while true {
                let frame: CMFrame
                do {
                    frame = try await transport.receive()
                } catch {
                    await self?.transportFailed(transport, error)
                    return
                }
                guard let self else {
                    transport.close()
                    return
                }
                await self.handle(frame)
            }
        }
    }

    private func handle(_ frame: CMFrame) {
        switch frame {
        case .binary(let bytes): deliver(bytes)
        case .text(let text):
            // CM 的协议消息都是二进制；文本帧（比如限流提示）不能当信封去解
            note("收到一条文本帧（\(text.count) 字符）：\(text.prefix(80))")
        }
    }

    /// 只处理当前这条通道的断开：`connect` 换了新通道之后，旧通道的收尾不能把新连接标成断开
    private func transportFailed(_ failed: any CMTransport, _ error: any Error) {
        guard let transport, transport === failed else { return }
        markDead(error)
    }

    deinit {
        transport?.close()
    }

    private func deliver(_ bytes: [UInt8]) {
        guard let decoded = try? CMEnvelope.decode(bytes) else {
            note("帧 \(bytes.count) 字节：解不开")
            return
        }
        // CM 会把好几条消息打包成一条 `CMsgMulti` 发（可能还 gzip 压过）：先拆开，再按普通消息派发。
        // 未登录的服务调用（EMsg 9804）的回包就是这么来的（2026-09-29 实测）
        if decoded.type == .multi {
            let inner = CMEnvelope.multiMessages(decoded.bodyBytes)
            note("帧 \(bytes.count) 字节：Multi → \(inner.count) 条")
            if inner.isEmpty {
                note("Multi 拆不开：\(CMEnvelope.describeMulti(decoded.bodyBytes))")
            }
            for message in inner { deliver(message) }
            return
        }
        note("帧 \(bytes.count) 字节：EMsg \(decoded.rawType)")
        if receivedTypes.count < 500 { receivedTypes.append(decoded.rawType) }

        switch decoded.type {
        case .clientLoggedOff?:
            // 被 Steam 下线：这条连接上的登录状态没了，在等的请求都不会有回应了
            let eresult = decoded.body.int32(1) ?? 0
            markDead(SteamCMError("被 Steam 下线了（EResult \(eresult)）", connectionLoss: true))
        case .serviceMethodResponse?:
            // 回包的 jobid_target 对上发出去的 jobid_source 才是那个请求的结果；
            // 没带 jobid_target 的（不该出现）交给最早在等的服务调用
            let id: Int?
            if let target = decoded.header.fixed64(11) {
                id = waiterID { $0 == .job(target) }
            } else {
                id = waiterID { if case .job = $0 { true } else { false } }
            }
            if let id { finish(id, returning: decoded) }
        default:
            // 老式消息按消息号给最早在等它的请求；没人等的（登录后 Steam 主动推的通知）不用管
            if let id = waiterID({ $0 == .type(decoded.rawType) }) { finish(id, returning: decoded) }
        }
    }

    /// 最早登记、而且在等这一类消息的请求
    private func waiterID(_ matches: (Key) -> Bool) -> Int? {
        waiters.filter { matches($0.value.key) }.keys.min()
    }

    private func finish(_ id: Int, returning decoded: CMEnvelope.Decoded) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: decoded)
    }

    private func finish(_ id: Int, throwing error: any Error) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    /// 连接断了 / 被下线：记下原因，在等的全部失败，停掉心跳
    private func markDead(_ error: any Error) {
        guard connectionError == nil else { return }
        connectionError = error
        heartbeatTask?.cancel()
        heartbeatTask = nil
        note("连接断开：\(error.localizedDescription)")
        failAll(Self.lost(error))
    }

    private func failAll(_ error: any Error) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.continuation.resume(throwing: error) }
    }

    /// 连接层的错误统一包成"连接断了"，上层据此决定换连接重试
    private static func lost(_ error: any Error) -> SteamCMError {
        if let error = error as? SteamCMError, error.isConnectionLoss { return error }
        return SteamCMError(String(localized: "和 Steam 的连接断了（\(error.localizedDescription)）"), connectionLoss: true)
    }

    /// 登录成功后按 Steam 给的间隔发心跳（`CMsgClientHeartBeat`，EMsg 703）。不发的话 CM 过一阵
    /// 会把连接当掉线回收，应用里下一次订阅 / 下载就会先失败一次
    private func startHeartbeat(seconds: Int32) {
        heartbeatTask?.cancel()
        let interval = Duration.seconds(Int(seconds > 0 ? seconds : 9))
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, await self.sendHeartbeat() else { return }
            }
        }
    }

    private func sendHeartbeat() async -> Bool {
        guard let transport, connectionError == nil else { return false }
        let frame = CMEnvelope.encode(
            .clientHeartBeat, header: CMRequest.header(jobID: 0, steamID: steamID), body: ProtoWriter())
        do {
            try await transport.send(frame)
            return true
        } catch {
            markDead(error)
            return false
        }
    }

    /// 调试用：连接级事件（握手成功、断开）和收到的帧
    public func connectionEvents() -> [String] { events }

    func note(event: String) { note(event) }

    private func note(_ text: String) { if events.count < 300 { events.append(text) } }

    /// 登录回应。SteamID 优先取回应**头部**的 steamid（CM 分配给这次登录的身份）；
    /// 没有时退回消息体里回显的 `client_supplied_steamid`（字段 20）
    static func logOnResult(_ body: ProtoMessage, header: ProtoMessage = ProtoMessage()) -> CMLogOnResult {
        let headerSteamID = header.fixed64(1) ?? 0
        return CMLogOnResult(
            eresult: body.int32(1) ?? 2,
            eresultExtended: body.int32(10) ?? 0,
            heartbeatSeconds: body.int32(3) ?? 0,
            steamID: headerSteamID != 0 ? headerSteamID : (body.fixed64(20) ?? 0),
            cellID: UInt32(truncatingIfNeeded: body.varint(7) ?? 0),
            vanityURL: body.string(14))
    }
}

/// 真实的 CM 通道：`URLSessionWebSocketTask`（每条连接自己一个 URLSession，关的时候一起释放）
final class WebSocketCMTransport: CMTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL, note: @escaping @Sendable (String) -> Void) {
        session = URLSession(
            configuration: .ephemeral, delegate: WebSocketObserver(note: note), delegateQueue: nil)
        task = session.webSocketTask(with: url)
        // 默认一帧最多 1 MB，超过整条连接直接报错断开；订阅列表一页 100 条带标签时不算小，放宽一些
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    func send(_ bytes: [UInt8]) async throws {
        try await task.send(.data(Data(bytes)))
    }

    func receive() async throws -> CMFrame {
        switch try await task.receive() {
        case .data(let data): .binary([UInt8](data))
        case .string(let text): .text(text)
        @unknown default: .text("")
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        // URLSession 会一直强引用它的 delegate，不 invalidate 的话每条连接都漏一个 session
        session.finishTasksAndInvalidate()
    }
}

/// `URLSessionWebSocketTask` 的握手 / 断开事件
final class WebSocketObserver: NSObject, URLSessionWebSocketDelegate, Sendable {
    let note: @Sendable (String) -> Void

    init(note: @escaping @Sendable (String) -> Void) {
        self.note = note
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        note("WebSocket 握手成功（子协议 \(`protocol` ?? "无")）")
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        note("WebSocket 关闭 code=\(closeCode.rawValue)"
            + " reason=\(reason.map { String(decoding: $0, as: UTF8.self) } ?? "无")")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { note("WebSocket 出错 \(error.localizedDescription)") }
    }
}
