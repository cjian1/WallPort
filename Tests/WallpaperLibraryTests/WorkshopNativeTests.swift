import Foundation
import SteamProtocol
import Testing
@testable import WallpaperLibrary

/// 假的 CM：每条连接一个假通道，按消息号 / 方法名回应。`dropFirstServiceCall` 时第一条已登录连接
/// 在第一次服务调用时断开（模拟睡眠、换网络、被 CM 回收），用来验证"自己重连再试一次"
private final class FakeCM: @unchecked Sendable {
    private let lock = NSLock()
    private var logons = 0
    private var connections = 0
    private var subscribeRequests: [ProtoMessage] = []
    var acceptToken = true
    var dropFirstServiceCall = false

    var logOnCount: Int { lock.withLock { logons } }
    var connectionCount: Int { lock.withLock { connections } }
    var subscribes: [ProtoMessage] { lock.withLock { subscribeRequests } }

    func makeConnection() -> SteamCMConnection {
        let index = lock.withLock { () -> Int in
            connections += 1
            return connections
        }
        return SteamCMConnection(transportFactory: { _, _ in
            let transport = Transport()
            transport.onSend = { [self] transport, bytes in self.respond(transport, bytes, connection: index) }
            return transport
        })
    }

    private func respond(_ transport: Transport, _ bytes: [UInt8], connection index: Int) {
        guard let request = try? CMEnvelope.decode(bytes) else { return }
        switch request.rawType {
        case EMsg.clientLogon.rawValue:
            lock.withLock { logons += 1 }
            var header = ProtoWriter()
            header.field(1, fixed64: 76_561_198_000_000_001)
            var body = ProtoWriter()
            body.field(1, int32: acceptToken ? 1 : 5)
            body.field(7, varint: 4)
            transport.push(CMEnvelope.encode(.clientLogOnResponse, header: header, body: body))
        case EMsg.serviceMethodCallFromClient.rawValue:
            if dropFirstServiceCall, index == 1 {
                transport.fail(URLError(.networkConnectionLost))
                return
            }
            var body = ProtoWriter()
            switch request.header.string(12) {
            case "PublishedFile.GetUserFiles#1":
                var item = ProtoWriter()
                item.field(1, varint: 1)
                item.field(2, varint: 3_807_008_481)
                item.field(16, string: "Ronova")
                body.field(3, message: item)
            case "PublishedFile.Subscribe#1":
                if let message = try? ProtoMessage(request.bodyBytes) {
                    lock.withLock { subscribeRequests.append(message) }
                }
            default:
                break
            }
            var header = ProtoWriter()
            header.field(11, fixed64: request.header.fixed64(10) ?? 0)
            header.field(13, int32: 1)
            transport.push(CMEnvelope.encode(.serviceMethodResponse, header: header, body: body))
        default:
            break
        }
    }

    final class Transport: CMTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var inbox: [CMFrame] = []
        private var receivers: [CheckedContinuation<CMFrame, any Error>] = []
        private var closedError: (any Error)?
        var onSend: (@Sendable (Transport, [UInt8]) -> Void)?

        func send(_ bytes: [UInt8]) async throws {
            try lock.withLock { if let closedError { throw closedError } }
            onSend?(self, bytes)
        }

        func receive() async throws -> CMFrame {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if !inbox.isEmpty { continuation.resume(returning: inbox.removeFirst()) }
                    else if let closedError { continuation.resume(throwing: closedError) }
                    else { receivers.append(continuation) }
                }
            }
        }

        func push(_ bytes: [UInt8]) {
            lock.withLock {
                if receivers.isEmpty { inbox.append(.binary(bytes)) } else { receivers.removeFirst().resume(returning: .binary(bytes)) }
            }
        }

        func fail(_ error: any Error) {
            lock.withLock {
                guard closedError == nil else { return }
                closedError = error
                let waiting = receivers
                receivers = []
                waiting.forEach { $0.resume(throwing: error) }
            }
        }

        func close() { fail(URLError(.cancelled)) }
    }
}

@Suite struct WorkshopNativeTests {
    /// 上次登上的那台 CM 下次先试；它不在新列表里就按列表原来的顺序
    @Test func lastGoodServerIsTriedFirst() {
        let servers = ["a", "b", "c"].map { URL(string: "wss://\($0).example/cmsocket/")! }
        #expect(WorkshopNative.preferring(servers[2], in: servers) == [servers[2], servers[0], servers[1]])
        #expect(WorkshopNative.preferring(URL(string: "wss://gone.example/cmsocket/"), in: servers) == servers)
        #expect(WorkshopNative.preferring(nil, in: servers) == servers)
    }

    private let session = SteamCMSession(
        accountName: "someone", steamID: "76561198000000001", refreshToken: "header.payload.signature")

    private func native(_ cm: FakeCM) -> WorkshopNative {
        WorkshopNative(
            servers: { [URL(string: "wss://cm1.example.com/cmsocket/")!, URL(string: "wss://cm2.example.com/cmsocket/")!] },
            makeConnection: { cm.makeConnection() })
    }

    /// 已登录的连接断了（睡眠、换网络）：用会话里的令牌重新登一次、再试一次，用户不用重新登录
    @Test func reconnectsWhenTheConnectionDropped() async throws {
        let cm = FakeCM()
        cm.dropFirstServiceCall = true
        let native = native(cm)
        let files = try await native.subscribedFiles(session: session)
        #expect(files.map(\.id) == ["3807008481"])
        #expect(cm.logOnCount == 2)
    }

    /// 几个操作同时要连接：只登一次 CM，之后复用同一条
    @Test func concurrentOperationsShareOneLogin() async throws {
        let cm = FakeCM()
        let native = native(cm)
        async let first = native.subscribedFiles(session: session)
        async let second = native.subscribedFiles(session: session)
        async let third = native.setSubscribed(true, id: "3807008481", session: session)
        _ = try await (first, second, third)
        #expect(cm.logOnCount == 1)
        // 订阅请求里的编号是 varint（uint64），不是 fixed64
        #expect(cm.subscribes.first?.values(1) == [.varint(3_807_008_481)])
        #expect(cm.subscribes.first?.varint(2) == 1)   // list_type = 订阅列表
    }

    /// Steam 不认存着的令牌（过期 / 被撤销）：报"没登录"，界面据此让用户重新登录
    @Test func rejectedTokenMeansNotLoggedIn() async throws {
        let cm = FakeCM()
        cm.acceptToken = false
        let native = native(cm)
        #expect(await native.restore(session) == .expired)
        await #expect(throws: WorkshopNative.Failure.notLoggedIn) {
            try await native.setSubscribed(false, id: "3807008481", session: session)
        }
        // 明确被拒就不再一台台换着试
        #expect(cm.connectionCount == 2)
    }

    /// 空闲时断开（心跳不再定时唤醒网络）：会话不动，下一次操作自己重新登一次 CM
    @Test func idleConnectionCanBeClosedAndComesBackOnDemand() async throws {
        let cm = FakeCM()
        let native = native(cm)
        #expect(await native.restore(session) == .connected(session))
        #expect(cm.logOnCount == 1)
        #expect(await native.closeIdleConnection())
        #expect(await !native.closeIdleConnection(), "已经断开了，再断一次什么也不做")
        let files = try await native.subscribedFiles(session: session)
        #expect(files.map(\.id) == ["3807008481"])
        #expect(cm.logOnCount == 2, "要用时自动重连")
    }

    /// 没网：会话不能被当成过期（不然每次断网都要重新登录）
    @Test func unreachableSteamKeepsTheSession() async throws {
        let native = WorkshopNative(
            servers: { throw URLError(.notConnectedToInternet) },
            makeConnection: { SteamCMConnection() })
        guard case .unreachable = await native.restore(session) else {
            Issue.record("没网时应该是 unreachable")
            return
        }
    }
}
