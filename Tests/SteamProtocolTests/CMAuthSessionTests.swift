import Foundation
import Testing
@testable import SteamProtocol

/// M7.5 的登录那一段：整条认证会话都在 CM 上跑（`Authentication.*` 走未登录服务调用）。
/// 字段号来自 Valve 随客户端发布的 `steam/steammessages_auth.steamclient.proto`，
/// 参考实现是 MIT 许可的 node-steam-session（`src/AuthenticationClient.ts` + `WebSocketCMTransport.ts`）
@Suite struct CMAuthSessionTests {
    /// 一张 2048 位的测试公钥（只在测试里用，私钥没进仓库）
    private let modulus = "a1fdff4173f1814e6d545b8b9d6503939f1b458276aa9d6a17440d784c8fe7bfe4fd90d279ee69cf91dc78ec"
        + "b703a33bba06eab368aa2ed9cbcec349d9b4b52abec55f98091c97a483c01db0990dd98046fa0bdca664f9b5"
        + "52c6b28652b2662da1845c545e6de2b8ac35eefc65d62916e5b58b2b0d49d87f80a71a1c6277b3bb8b2263f3"
        + "babd7109cd4c5bb41afac4ed1ec1d4340c5ba46f1e77f09d1ba729072184a502a01d05a0fee846e734d12bbd"
        + "c9942ffa314d0acc816785d5d5fd041d22fd22e7f9658c61ba8094dce35a02add9f7871f8eadbdafe527e9c3"
        + "83435720f1a04e7801a8d0ca6183f793d25a2ac49de5fd2a91be0c275b437ae03ac4452b"

    @Test func beginAuthSessionFields() throws {
        let machineID = Array("BB3".utf8) + Array(repeating: 0x41, count: 40)
        let body = try ProtoMessage(CMAuthSession.beginAuthSessionRequest(
            accountName: "someone", encryptedPassword: "ENCRYPTED", timestamp: 1_700_000_000,
            platformType: 1, websiteID: "Unknown", machineID: machineID).bytes)

        #expect(body.string(1) == "WallPort (Mac)")        // device_friendly_name
        #expect(body.string(2) == "someone")               // account_name
        #expect(body.string(3) == "ENCRYPTED")             // encrypted_password
        #expect(body.varint(4) == 1_700_000_000)           // encryption_timestamp
        #expect(body.bool(5) == true)                      // remember_login
        #expect(body.varint(6) == 1)                       // platform_type = SteamClient
        #expect(body.varint(7) == 1)                       // persistence = 长期
        #expect(body.string(8) == "Unknown")               // website_id（参考实现给 SteamClient 的就是这个）

        let device = try #require(body.message(9))         // device_details
        #expect(device.string(1) == "WallPort (Mac)")
        #expect(device.varint(2) == 1)
        #expect(device.int32(3) == 16)                     // os_type：macOS 10.15+
        #expect(device.varint(4) == 1)                     // gaming_device_type：桌面
        #expect(device.bytes(6) == machineID)              // machine_id
    }

    @Test func parsesBeginAuthSessionResponse() throws {
        var confirmation = ProtoWriter()
        confirmation.field(1, varint: 4)                   // k_EAuthSessionGuardType_DeviceConfirmation
        confirmation.field(2, string: "请确认")
        var body = ProtoWriter()
        body.field(1, varint: 1234)                        // client_id
        body.field(2, bytes: [1, 2, 3, 4, 5, 6, 7, 8])     // request_id（bytes）
        body.field(3, fixed32: Float(5).bitPattern)        // interval
        body.field(4, message: confirmation)
        body.field(5, varint: 76_561_198_419_273_616)      // steamid（.proto 里是 uint64，不是 fixed64）

        let pending = try #require(
            CMAuthSession.pending(from: try ProtoMessage(body.bytes), accountName: "someone"))
        #expect(pending.clientID == 1234)
        #expect(pending.requestID == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(pending.interval == 5)
        #expect(pending.steamID == 76_561_198_419_273_616)
        #expect(pending.accountName == "someone")
        #expect(pending.guards.count == 1)
        #expect(pending.guards.first?.type == 4)
        #expect(pending.guards.first?.isConfirmation == true)
        #expect(pending.guards.first?.needsCode == false)
        #expect(pending.guards.first?.describe == "手机 App 上确认")
    }

    /// 邮件/手机令牌验证码要走提交那一步，回包里的新 client_id 要跟走
    @Test func guardCodeAndPollFields() throws {
        let guardBody = try ProtoMessage(CMAuthSession.guardCodeRequest(
            clientID: 99, steamID: 76_561_198_419_273_616, code: "ABCDE", codeType: 3).bytes)
        #expect(guardBody.varint(1) == 99)
        #expect(guardBody.fixed64(2) == 76_561_198_419_273_616)
        #expect(guardBody.string(3) == "ABCDE")
        #expect(guardBody.varint(4) == 3)

        let pollBody = try ProtoMessage(CMAuthSession.pollRequest(clientID: 99, requestID: [9, 9]).bytes)
        #expect(pollBody.varint(1) == 99)
        #expect(pollBody.bytes(2) == [9, 9])

        var tokens = ProtoWriter()
        tokens.field(3, string: "REFRESH")
        tokens.field(4, string: "ACCESS")
        tokens.field(6, string: "someone")
        let parsed = try #require(CMAuthSession.tokens(from: try ProtoMessage(tokens.bytes), accountName: "x"))
        #expect(parsed.accessToken == "ACCESS")
        #expect(parsed.refreshToken == "REFRESH")
        #expect(parsed.accountName == "someone")

        // 还没好（没有 access_token）时返回 nil，不能把空令牌当成登录成功
        #expect(CMAuthSession.tokens(from: ProtoMessage(), accountName: "x") == nil)
        var onlyRefresh = ProtoWriter()
        onlyRefresh.field(3, string: "REFRESH")
        #expect(CMAuthSession.tokens(from: try ProtoMessage(onlyRefresh.bytes), accountName: "x") == nil)

        var newClient = ProtoWriter()
        newClient.field(1, varint: 4321)
        #expect(CMAuthSession.newClientID(from: try ProtoMessage(newClient.bytes)) == 4321)

        // 扫码会话的二维码会过期换新（new_challenge_url = 2）
        var newURL = ProtoWriter()
        newURL.field(2, string: "https://s.team/q/1/999")
        #expect(CMAuthSession.newChallengeURL(from: try ProtoMessage(newURL.bytes)) == "https://s.team/q/1/999")
        #expect(CMAuthSession.newChallengeURL(from: ProtoMessage()) == nil)
    }

    /// RSA：结果长度必须等于模长（2048 位 → 256 字节），而且每次都不一样（PKCS#1 v1.5 的随机填充）。
    /// 加密的正确性在开发时用 openssl 私钥解回过原文核对过。
    @Test func rsaEncryptsToModulusSize() throws {
        let first = try SteamRSA.encrypt(password: "correct horse", modulusHex: modulus, exponentHex: "010001")
        let second = try SteamRSA.encrypt(password: "correct horse", modulusHex: modulus, exponentHex: "010001")
        #expect(Data(base64Encoded: first)?.count == 256)
        #expect(first != second)
        #expect(throws: SteamCMError.self) {
            try SteamRSA.encrypt(password: "x", modulusHex: "zz", exponentHex: "010001")
        }
    }

    /// 扫码登录（`BeginAuthSessionViaQR#1`）：不用密码，手机上确认
    @Test func qrAuthSessionFields() throws {
        let body = try ProtoMessage(CMAuthSession.qrAuthSessionRequest(
            platformType: 1, websiteID: "Unknown").bytes)
        #expect(body.string(1) == "WallPort (Mac)")        // device_friendly_name
        #expect(body.varint(2) == 1)                       // platform_type
        #expect(body.string(4) == "Unknown")               // website_id
        let device = try #require(body.message(3))         // device_details
        #expect(device.string(1) == "WallPort (Mac)")
        #expect(device.varint(4) == 1)

        var confirmation = ProtoWriter()
        confirmation.field(1, varint: 4)                   // 手机 App 上确认
        var response = ProtoWriter()
        response.field(1, varint: 777)                     // client_id
        response.field(2, string: "https://s.team/q/1/777")  // challenge_url
        response.field(3, bytes: [7, 7, 7])                // request_id
        response.field(4, fixed32: Float(5).bitPattern)    // interval
        response.field(5, message: confirmation)

        let parsed = try #require(CMAuthSession.qrPending(from: try ProtoMessage(response.bytes)))
        #expect(parsed.challengeURL == "https://s.team/q/1/777")
        #expect(parsed.pending.clientID == 777)
        #expect(parsed.pending.requestID == [7, 7, 7])
        #expect(parsed.pending.interval == 5)
        #expect(parsed.pending.guards.first?.isConfirmation == true)
    }

    /// `CMsgMulti`（EMsg 1）：CM 把好几条消息（gzip 压过）打包成一条发。
    /// 2026-09-29 实测：**未登录服务调用的回包就是这么回来的**，不拆这层就看着像"没回应"。
    @Test func unwrapsGzippedMultiMessages() throws {
        // 里面两条真实的信封：147（服务方法回包，body 是 0a 02 6f 6b）和 751（eresult = 1）
        let first = Array(CMEnvelope.encode(
            .serviceMethodResponse, header: ProtoWriter(), body: {
                var body = ProtoWriter()
                body.field(1, string: "ok")
                return body
            }()))
        let second = Array(CMEnvelope.encode(
            .clientLogOnResponse, header: ProtoWriter(), body: {
                var body = ProtoWriter()
                body.field(1, int32: 1)
                return body
            }()))
        let gzipped = [UInt8](base64:
            "H4sIAAAAAAAC/+NhYGCYzMDQAKQYuJjys7mA9HsmCJ+DEQAWSJ0oHgAAAA==")
        var multi = ProtoWriter()
        multi.field(1, varint: 30)                         // size_unzipped
        multi.field(2, bytes: gzipped)                     // message_body

        let messages = CMEnvelope.multiMessages(multi.bytes)
        #expect(messages.count == 2)
        #expect(messages.first == first)
        #expect(messages.last == second)

        // 没压过的 Multi 也要能拆（同一段载荷，不压缩）
        let plainPayload = [UInt8](base64: "DAAAAJMAAIAAAAAACgJvawoAAADvAgCAAAAAAAgB")
        var plain = ProtoWriter()
        plain.field(2, bytes: plainPayload)
        #expect(CMEnvelope.multiMessages(plain.bytes) == [first, second])
        #expect(CMEnvelope.multiMessages([]).isEmpty)
        // 切出来不是信封的载荷要整条丢掉，不能把压缩数据当消息用
        var garbage = ProtoWriter()
        garbage.field(2, bytes: [0xaa, 0xbb, 0xcc])
        #expect(CMEnvelope.multiMessages(garbage.bytes).isEmpty)
    }
}
