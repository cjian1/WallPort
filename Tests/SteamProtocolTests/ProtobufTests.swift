import Foundation
import Testing
@testable import SteamProtocol

/// M7.5 的地基：protobuf 编解码、CM 消息信封、登录消息的字段。都是自写夹具，不联网
@Suite struct ProtobufTests {
    @Test func varintRoundTrip() throws {
        for value in [UInt64(0), 1, 127, 128, 300, 65535, 1 << 20, UInt64.max] {
            var writer = ProtoWriter()
            writer.field(1, varint: value)
            let message = try ProtoMessage(writer.bytes)
            #expect(message.varint(1) == value, "\(value) 没有原样读回来")
            #expect(message.bytes(1) == nil)
        }
    }

    @Test func fixedAndLengthDelimited() throws {
        var inner = ProtoWriter()
        inner.field(1, string: "inner")
        var writer = ProtoWriter()
        writer.field(10, fixed64: 0x1122_3344_5566_7788)
        writer.field(2, fixed32: 0xdead_beef)
        writer.field(3, string: "hello")
        writer.field(4, message: inner)
        writer.field(5, bool: true)

        let message = try ProtoMessage(writer.bytes)
        #expect(message.fixed64(10) == 0x1122_3344_5566_7788)
        #expect(message.fixed32(2) == 0xdead_beef)
        #expect(message.string(3) == "hello")
        #expect(message.message(4)?.string(1) == "inner")
        #expect(message.bool(5) == true)
        #expect(message.values(99).isEmpty)
    }

    /// fixed64 是小端：SteamID 76561198419273616 的字节序要和协议一致
    @Test func fixed64IsLittleEndian() throws {
        var writer = ProtoWriter()
        writer.field(20, fixed64: 76_561_198_419_273_616)
        // 字段 20、类型 1 → key = (20 << 3) | 1 = 161，key 自己是 varint 所以占两字节；
        // 后面是 SteamID 的小端 8 字节
        #expect(writer.bytes == [0xa1, 0x01, 0x90, 0xe7, 0x5b, 0x1b, 0x01, 0x00, 0x10, 0x01])
        let message = try ProtoMessage(writer.bytes)
        #expect(message.fixed64(20) == 76_561_198_419_273_616)
    }

    @Test func negativeInt32UsesTwosComplement() throws {
        var writer = ProtoWriter()
        writer.field(1, int32: -1)
        let message = try ProtoMessage(writer.bytes)
        #expect(message.int32(1) == -1)
    }

    @Test func truncatedInputThrows() {
        #expect(throws: ProtoError.self) { _ = try ProtoMessage([0x08, 0x80]) }      // varint 没读完
        #expect(throws: ProtoError.self) { _ = try ProtoMessage([0x0a, 0x05, 0x01]) } // 长度前缀越界
    }
}

@Suite struct CMEnvelopeTests {
    @Test func roundTrip() throws {
        var header = ProtoWriter()
        header.field(10, fixed64: 12345)
        var body = ProtoWriter()
        body.field(1, varint: 42)
        let frame = CMEnvelope.encode(.clientLogon, header: header, body: body)

        let decoded = try CMEnvelope.decode(frame)
        #expect(decoded.type == .clientLogon)
        #expect(decoded.header.fixed64(10) == 12345)
        #expect(decoded.body.varint(1) == 42)
    }

    @Test func unknownMessageTypeIsKept() throws {
        var frame = CMEnvelope.encode(.multi, header: ProtoWriter(), body: ProtoWriter())
        frame[0] = 0xff // 编一个我们不认识的消息编号
        let decoded = try CMEnvelope.decode(frame)
        #expect(decoded.type == nil)
        #expect(decoded.rawType == 0xff)
    }

    @Test func shortFrameThrows() {
        #expect(throws: SteamCMError.self) { _ = try CMEnvelope.decode([1, 2, 3]) }
    }
}

/// UGC 清单：容器是"每段带自己的 magic"，载荷和元数据各一段
@Suite struct ContentManifestTests {
    private func sample() -> ContentManifest {
        ContentManifest(
            files: [
                ContentManifest.File(
                    name: "a/b.json", size: 5,
                    chunks: [
                        ContentManifest.Chunk(sha: [1, 2, 3], offset: 0, originalSize: 5, compressedSize: 9)
                    ]),
                ContentManifest.File(name: "preview.jpg", size: 100, chunks: []),
            ],
            depotID: 431_960, manifestID: 42)
    }

    @Test func roundTrip() throws {
        let parsed = try ContentManifest(data: sample().encoded())
        #expect(parsed.files == sample().files)
        #expect(parsed.depotID == 431_960)
        #expect(parsed.manifestID == 42)
        #expect(parsed.chunkCount == 1)
        #expect(parsed.totalBytes == 105)
        #expect(parsed.files[0].chunks[0].isCompressed)
        #expect(parsed.files[0].chunks[0].shaHex == "010203")
    }

    @Test func wrongMagicIsRejected() {
        var data = sample().encoded()
        data[0] = 0xff
        #expect(throws: SteamCMError.self) { _ = try ContentManifest(data: data) }
    }

    @Test func truncatedSectionIsRejected() {
        let data = sample().encoded().prefix(20)
        #expect(throws: SteamCMError.self) { _ = try ContentManifest(data: data) }
    }
}

@Suite struct CMLogonTests {
    @Test func anonymousLogonCarriesProtocolVersion() throws {
        let body = try ProtoMessage(CMRequest.anonymousLogon().bytes)
        #expect(body.varint(1) == UInt64(CMRequest.protocolVersion))
        #expect(body.string(6) == "english")
        #expect(body.string(50) == "anonymous", "匿名登录用 Steam 自己的字面量 anonymous")
        #expect(body.string(108) == nil, "匿名登录不该带访问令牌")
    }

    /// 带令牌登录：`access_token` 字段填 refresh token；**默认不带 `account_name`**
    /// （参考实现 steam-user 明说"带令牌登录时不能再带 account_name"），SteamID 放进
    /// `client_supplied_steam_id`（字段 22）
    @Test func tokenLogonCarriesAccessToken() throws {
        let body = try ProtoMessage(CMRequest.tokenLogon(
            accessToken: "tok123", accountName: "someone", steamID: 76_561_198_419_273_616).bytes)
        #expect(body.string(108) == "tok123")
        #expect(body.bool(8) == true, "should_remember_password：让 CM 缓存凭据")
        #expect(body.fixed64(22) == 76_561_198_419_273_616)
        #expect(body.string(50) == nil, "默认不带账号名（带了 CM 会当成账号密码登录）")
        #expect(body.varint(7) == 16, "client_os_type：macOS 10.15+")
        #expect(body.bytes(30) != nil, "非匿名登录要带 machine_id")

        // 排查用：显式要求时才带账号名
        let withName = try ProtoMessage(CMRequest.tokenLogon(
            accessToken: "tok123", accountName: "someone", sendAccountName: true).bytes)
        #expect(withName.string(50) == "someone")
    }

    /// 回包按 Valve 的 `CMsgClientLogonResponse` 字段号解码
    @Test func logOnResponseDecoding() throws {
        var body = ProtoWriter()
        body.field(1, int32: 1)                      // eresult
        body.field(3, int32: 30)                     // heartbeat_seconds
        body.field(7, varint: 64)                    // cell_id
        body.field(14, string: "someone")            // vanity_url
        body.field(20, fixed64: 76_561_198_419_273_616)  // client_supplied_steamid
        let result = SteamCMConnection.logOnResult(try ProtoMessage(body.bytes))
        #expect(result.isOK)
        #expect(result.heartbeatSeconds == 30)
        #expect(result.cellID == 64)
        #expect(result.vanityURL == "someone")
        #expect(result.steamID == 76_561_198_419_273_616)
    }

    @Test func failedLogOnIsNotOK() throws {
        var body = ProtoWriter()
        body.field(1, int32: 5)
        let result = SteamCMConnection.logOnResult(try ProtoMessage(body.bytes))
        #expect(!result.isOK)
        #expect(result.describe.contains("账号或密码"))
    }
}

/// 服务方法：方法名在头部的 target_job_name，请求/回包各是一条 protobuf
@Suite struct SteamServiceTests {
    @Test func serviceHeaderCarriesMethodAndJobID() throws {
        let header = try ProtoMessage(CMRequest.serviceHeader(jobID: 4242, method: "PublishedFile.GetDetails#1").bytes)
        #expect(header.string(12) == "PublishedFile.GetDetails#1")
        #expect(header.fixed64(10) == 4242)
    }

    @Test func getDetailsRequestFields() throws {
        let body = try ProtoMessage(
            SteamServiceCall.publishedFileDetails(ids: [3807008481, 3169364633], appID: 431_960).bytes)
        let ids = body.values(1).compactMap { value -> UInt64? in
            guard case .fixed64(let raw) = value else { return nil }
            return raw
        }
        #expect(ids == [3807008481, 3169364633])
        #expect(body.bool(2) == true)
        #expect(body.varint(14) == 431_960)
    }

    /// 按 Valve 的 `PublishedFileDetails` 字段号解析（result=1、id=2、size=8、hcontent_file=14、title=16…）
    @Test func publishedFileInfoParsing() throws {
        var tag = ProtoWriter()
        tag.field(1, string: "Scene")
        var item = ProtoWriter()
        item.field(1, varint: 1)                       // result = OK
        item.field(2, varint: 3807008481)              // publishedfileid
        item.field(8, varint: 94_680_570)              // file_size
        item.field(14, fixed64: 6_176_428_963_886_766_760)  // hcontent_file
        item.field(16, string: "Ronova - Face Check")  // title
        item.field(20, varint: 1_790_205_877)          // time_updated
        item.field(52, message: tag)                   // tags[]

        let info = try #require(PublishedFileInfo(try ProtoMessage(item.bytes)))
        #expect(info.id == 3807008481)
        #expect(info.result == 1)
        #expect(info.title == "Ronova - Face Check")
        #expect(info.fileSize == 94_680_570)
        #expect(info.contentHandle == 6_176_428_963_886_766_760)
        #expect(info.timeUpdated == 1_790_205_877)
        #expect(info.tags == ["Scene"])
    }

    /// `CPublishedFile_GetDetails_Response`：条目详情是字段 1 的 repeated 子消息
    @Test func getDetailsResponseUnwrapping() throws {
        var item = ProtoWriter()
        item.field(2, varint: 123)
        item.field(16, string: "标题")
        var response = ProtoWriter()
        response.field(1, message: item)
        let body = try ProtoMessage(response.bytes)
        let items = body.values(1).compactMap { value -> PublishedFileInfo? in
            guard case .bytes(let data) = value, let message = try? ProtoMessage(data) else { return nil }
            return PublishedFileInfo(message)
        }
        #expect(items.count == 1)
        #expect(items.first?.id == 123)
        #expect(items.first?.title == "标题")
    }

    @Test func contentServerRequestFields() throws {
        let body = try ProtoMessage(SteamServiceCall.contentServers(cellID: 64, maxServers: 20).bytes)
        #expect(body.varint(1) == 64)
        #expect(body.varint(2) == 20)
    }
}
