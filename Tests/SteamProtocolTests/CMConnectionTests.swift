import Foundation
import Testing
@testable import SteamProtocol

/// 假的 CM 通道：记下发出去的帧，由测试决定什么时候推回什么（不联网）
final class FakeCMTransport: CMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [CMFrame] = []
    private var receivers: [CheckedContinuation<CMFrame, any Error>] = []
    private var closedError: (any Error)?
    private var sentFrames: [[UInt8]] = []
    /// 每发一帧调一次（在这里模拟 CM 的回应）
    var onSend: (@Sendable (FakeCMTransport, CMEnvelope.Decoded) -> Void)?

    var sent: [CMEnvelope.Decoded] { lock.withLock { sentFrames }.compactMap { try? CMEnvelope.decode($0) } }

    func send(_ bytes: [UInt8]) async throws {
        try lock.withLock {
            if let closedError { throw closedError }
            sentFrames.append(bytes)
        }
        if let decoded = try? CMEnvelope.decode(bytes) { onSend?(self, decoded) }
    }

    func receive() async throws -> CMFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if !inbox.isEmpty {
                    continuation.resume(returning: inbox.removeFirst())
                } else if let closedError {
                    continuation.resume(throwing: closedError)
                } else {
                    receivers.append(continuation)
                }
            }
        }
    }

    func push(_ bytes: [UInt8]) {
        lock.withLock {
            if receivers.isEmpty { inbox.append(.binary(bytes)) } else { receivers.removeFirst().resume(returning: .binary(bytes)) }
        }
    }

    /// 模拟连接断开
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

    /// 服务方法的回包（`jobid_target` 对上请求的 `jobid_source`）
    static func serviceResponse(to request: CMEnvelope.Decoded, body: ProtoWriter, eresult: Int32 = 1) -> [UInt8] {
        var header = ProtoWriter()
        header.field(11, fixed64: request.header.fixed64(10) ?? 0)
        header.field(13, int32: eresult)
        return CMEnvelope.encode(.serviceMethodResponse, header: header, body: body)
    }

    /// 方法名在请求头部的 `target_job_name`（字段 12）
    static func method(of request: CMEnvelope.Decoded) -> String? { request.header.string(12) }
}

private let fakeServer = URL(string: "wss://cm.example.com/cmsocket/")!

private func connected(_ transport: FakeCMTransport) async -> SteamCMConnection {
    let connection = SteamCMConnection(transportFactory: { _, _ in transport })
    await connection.connect(to: fakeServer)
    return connection
}

/// 等某个条件成立（假通道是异步推的，给一点时间）
private func eventually(_ timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite struct CMConnectionTests {
    /// 同一条连接上同时有两个请求：回包倒着回来，也要各归各的（应用里读订阅和下载会并发）
    @Test func concurrentCallsGetTheirOwnResponses() async throws {
        let transport = FakeCMTransport()
        let requests = LockedBox<[CMEnvelope.Decoded]>([])
        transport.onSend = { transport, decoded in
            guard decoded.rawType == EMsg.serviceMethodCallFromClient.rawValue else { return }
            let all = requests.mutate { $0.append(decoded); return $0 }
            guard all.count == 2 else { return }
            for request in all.reversed() {
                var body = ProtoWriter()
                body.field(1, string: FakeCMTransport.method(of: request) ?? "")
                transport.push(FakeCMTransport.serviceResponse(to: request, body: body))
            }
        }
        let connection = await connected(transport)
        async let first = connection.call("First.Method#1", request: ProtoWriter())
        async let second = connection.call("Second.Method#1", request: ProtoWriter())
        let (a, b) = try await (first, second)
        #expect(a.string(1) == "First.Method#1")
        #expect(b.string(1) == "Second.Method#1")
    }

    /// 回包裹在 CMsgMulti 里（CM 常这么发）也要按 job 分发到
    @Test func responsesInsideMultiAreRouted() async throws {
        let transport = FakeCMTransport()
        transport.onSend = { transport, decoded in
            guard decoded.rawType == EMsg.serviceMethodCallFromClientNonAuthed.rawValue else { return }
            var body = ProtoWriter()
            body.field(1, string: "ok")
            let inner = FakeCMTransport.serviceResponse(to: decoded, body: body)
            var payload: [UInt8] = []
            CRC32.appendLittleEndian(UInt32(inner.count), to: &payload)
            payload += inner
            var multi = ProtoWriter()
            multi.field(2, bytes: payload)
            transport.push(CMEnvelope.encode(.multi, header: ProtoWriter(), body: multi))
        }
        let connection = await connected(transport)
        let reply = try await connection.callUnauthenticated("Authentication.Probe#1", request: ProtoWriter())
        #expect(reply.string(1) == "ok")
    }

    /// Steam 明确回的失败带着 EResult，而且**不算**连接问题（不该拿去重连重试）
    @Test func steamFailuresCarryTheirResult() async throws {
        let transport = FakeCMTransport()
        transport.onSend = { transport, decoded in
            guard decoded.rawType == EMsg.serviceMethodCallFromClient.rawValue else { return }
            transport.push(FakeCMTransport.serviceResponse(to: decoded, body: ProtoWriter(), eresult: 15))
        }
        let connection = await connected(transport)
        do {
            _ = try await connection.call("PublishedFile.Subscribe#1", request: ProtoWriter())
            Issue.record("应该失败")
        } catch let error as SteamCMError {
            #expect(error.eresult == 15)
            #expect(!error.isConnectionLoss)
        }
    }

    /// 连接断了：在等的请求立刻失败（不是等到超时），连接标成断开
    @Test func droppedConnectionFailsPendingCallsImmediately() async throws {
        let transport = FakeCMTransport()
        let connection = await connected(transport)
        let started = ContinuousClock.now
        async let call = connection.call("PublishedFile.GetDetails#1", request: ProtoWriter(), timeout: .seconds(20))
        #expect(await eventually { transport.sent.contains { $0.rawType == EMsg.serviceMethodCallFromClient.rawValue } })
        transport.fail(URLError(.networkConnectionLost))
        do {
            _ = try await call
            Issue.record("应该失败")
        } catch let error as SteamCMError {
            #expect(error.isConnectionLoss)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await connection.isConnected == false)
        // 断了之后再调也立刻失败（上层据此换连接）
        await #expect(throws: SteamCMError.self) {
            _ = try await connection.call("PublishedFile.GetDetails#1", request: ProtoWriter())
        }
    }

    /// 被 Steam 下线（ClientLoggedOff）：等着的请求失败，连接不能再用
    @Test func loggedOffEndsTheConnection() async throws {
        let transport = FakeCMTransport()
        let connection = await connected(transport)
        async let call = connection.call("PublishedFile.GetUserFiles#1", request: ProtoWriter())
        #expect(await eventually { transport.sent.contains { $0.rawType == EMsg.serviceMethodCallFromClient.rawValue } })
        var body = ProtoWriter()
        body.field(1, int32: 6)
        transport.push(CMEnvelope.encode(.clientLoggedOff, header: ProtoWriter(), body: body))
        do {
            _ = try await call
            Issue.record("应该失败")
        } catch let error as SteamCMError {
            #expect(error.isConnectionLoss)
        }
        #expect(await connection.isConnected == false)
    }

    /// 没有回应：按超时失败，并且算"连接问题"（换一条可能就好）
    @Test func unansweredCallTimesOut() async throws {
        let transport = FakeCMTransport()
        let connection = await connected(transport)
        do {
            _ = try await connection.call("PublishedFile.GetDetails#1", request: ProtoWriter(), timeout: .milliseconds(200))
            Issue.record("应该超时")
        } catch let error as SteamCMError {
            #expect(error.isConnectionLoss)
            #expect(error.message.contains("PublishedFile.GetDetails#1"))
        }
    }

    /// 登录：SteamID 取回应头部的；登录后按 heartbeat_seconds 发心跳（EMsg 703）
    @Test func logOnReadsSteamIDAndStartsHeartbeat() async throws {
        let transport = FakeCMTransport()
        transport.onSend = { transport, decoded in
            guard decoded.rawType == EMsg.clientLogon.rawValue else { return }
            var header = ProtoWriter()
            header.field(1, fixed64: 76_561_198_000_000_042)
            header.field(2, int32: 1234)
            var body = ProtoWriter()
            body.field(1, int32: 1)                   // eresult
            body.field(3, int32: 1)                   // heartbeat_seconds
            body.field(7, varint: 64)                 // cell_id
            transport.push(CMEnvelope.encode(.clientLogOnResponse, header: header, body: body))
        }
        let connection = await connected(transport)
        let result = try await connection.logOn(accessToken: "not.a.jwt", accountName: "someone")
        #expect(result.isOK)
        #expect(result.steamID == 76_561_198_000_000_042)
        #expect(result.cellID == 64)
        #expect(await eventually(.seconds(3)) {
            transport.sent.contains { $0.rawType == EMsg.clientHeartBeat.rawValue }
        })
        // 心跳头部带的是登录后的 SteamID
        let heartbeat = transport.sent.first { $0.rawType == EMsg.clientHeartBeat.rawValue }
        #expect(heartbeat?.header.fixed64(1) == 76_561_198_000_000_042)
        await connection.close()
    }

    /// 取消等待中的请求：立刻结束（登录框里点"取消"时轮询要马上停）
    @Test func cancellingAWaitingCallEndsIt() async throws {
        let transport = FakeCMTransport()
        let connection = await connected(transport)
        let task = Task { try await connection.call("Authentication.PollAuthSessionStatus#1", request: ProtoWriter()) }
        #expect(await eventually { transport.sent.contains { $0.rawType == EMsg.serviceMethodCallFromClient.rawValue } })
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

/// 测试里跨线程收集东西用
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
    var current: Value { lock.withLock { value } }
}
