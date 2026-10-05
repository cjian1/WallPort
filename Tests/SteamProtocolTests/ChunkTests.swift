import CryptoKit
import Foundation
import Testing
@testable import SteamProtocol

/// M7.5-3：内容服务器上的分块（加密 → 容器 → zstd）和按清单拼文件。
///
/// 夹具是自造的（不是 Steam 的内容）：一段 3654 字节的文本，用 zstd 压成 82 字节，包成 `VSZa` 容器，
/// 再用下面这把测试密钥按 Steam 的方式（AES-ECB 加密 IV + AES-CBC）加密。生成命令见"夹具怎么来的"。
@Suite struct ChunkTests {
    /// 测试密钥（固定值，只在这个文件里用）
    private let key = [UInt8](hexString:
        "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
    private let iv = [UInt8](hexString: "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")

    /// zstd 压好的 82 字节（zstd 帧，magic 28 b5 2f fd）
    private let zstdFrame = [UInt8](base64:
        "KLUv/QRoLQIAokMNEaBv+OVsAytHtu3r4g4XJfEKIHd4WeldabBX1RnOnz6F79+f2aTRW6yFOV6atPzosTW3jQ"
        + "MEAPN70wNgMwAUKWYYdKPDuA==")

    private var content: Data {
        Data("{\"wallpaper\":\"MacWallpaper\",\"kind\":\"scene\",\"note\":\"".utf8)
            + Data(String(repeating: "steam-chunk-fixture ", count: 180).utf8)
            + Data("\"}\n".utf8)
    }

    /// 加密后的分块（Steam 发过来的就是这一串）
    private let encryptedChunk = [UInt8](base64:
        "meUGXw8akrlapM95TESoGal6+KpWyYgZjl+TsQUmhGWmfNsXlgLQO5qZEj5DXDWFaRbEgWR1oCgtKrbAogFuWD"
        + "rpmfZcSNuYW3UdB7hvKprHG5TooVSWy31XDqObDLvIigKzdWniWIeyk/wN4ZJlZbfdtZ3dIHlxHvmJ2W+Ab2E=")

    /// 容器（去掉加密之后应该正好是这个）
    private let expectedContainer = [UInt8](base64:
        "VlNaYa10jgMotS/9BGgtAgCiQw0RoG/45WwDK0e27eviDhcl8Qogd3hZ6V1psFfVGc6fPoXv35/ZpNFbrIU5Xp"
        + "q0/OixNbeNAwQA83vTA2AzABQpZhh0o8O4rXSOA0YOAAAAAAAAenN2")

    @Test func crc32MatchesZlib() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xcbf4_3926)
        #expect(CRC32.checksum(Array("".utf8)) == 0)
        #expect(CRC32.checksum(Array("The quick brown fox jumps over the lazy dog".utf8)) == 0x414f_a339)
    }

    /// 夹具的"内容"必须和生成时那份一致，不然下面几步都在自说自话
    @Test func fixtureContentIsStable() {
        #expect(content.count == 3654)
        let digest = Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "b38dc1221f068c9a387a0fdf22aab4b8c41fa214")
    }

    /// 加密那一步：AES-ECB 解密出 IV，再用它做 AES-CBC
    @Test func decryptsSteamStyleChunk() throws {
        let plain = try SteamChunkCipher.decrypt(encryptedChunk, key: key)
        #expect(Array(plain.prefix(4)) == ChunkContainer.zstdMagic)
        #expect(Array(plain.prefix(4)) == Array(expectedContainer.prefix(4)))
    }

    /// 加密是自洽的（测试/造夹具用）：解回来必须一模一样
    @Test func encryptRoundTrips() throws {
        let container = ChunkContainer.zstdContainer(compressed: zstdFrame, content: [UInt8](content))
        let encrypted = try SteamChunkCipher.encrypt(container, key: key, iv: iv)
        #expect(try SteamChunkCipher.decrypt(encrypted, key: key) == container)
    }

    /// 容器：把压缩数据和长度/校验和按 `VSZa` 的样子拼出来
    @Test func buildsZstdContainer() {
        let container = ChunkContainer.zstdContainer(compressed: zstdFrame, content: [UInt8](content))
        #expect(ChunkContainer.kind(of: container) == .zstd)
        #expect(container.count == 8 + zstdFrame.count + 15)
    }

    /// 整条解压链：加密分块 → 容器 → 原来的文本
    @Test func decompressesChunkEndToEnd() throws {
        let plain = try SteamChunkCipher.decrypt(encryptedChunk, key: key)
        let unpacked = try ChunkContainer.decompress(plain)
        #expect(Data(unpacked) == content)
    }

    /// 校验和对不上时必须报错，不能把坏数据当好的用
    @Test func rejectsCorruptedContainer() throws {
        let container = ChunkContainer.zstdContainer(compressed: zstdFrame, content: [UInt8](content))
        var broken = container
        broken[broken.count - 1] = 0x00                 // 尾部 magic 改坏
        #expect(throws: SteamCMError.self) { try ChunkContainer.decompress(broken) }

        var flipped = container
        flipped[flipped.count - 15] ^= 0xff             // 解压数据的 CRC32 改坏
        #expect(throws: SteamCMError.self) { try ChunkContainer.decompress(flipped) }
    }

    /// 旧内容的分块是 LZMA 的 `VZa` 容器："VZa" + 4 字节 + LZMA 参数 5 字节 + 数据 + CRC32 + 长度 + "zv"。
    /// 夹具：同一段 3654 字节的文本，用 Python 的 lzma（.lzma 格式）压好，去掉 8 字节长度头再按容器拼起来
    /// （数据末尾带结束标记——真实容器有没有都要能解）
    @Test func unpacksLZMAContainer() throws {
        let container = [UInt8](base64:
            "VlphAAAAAF0AAIAAAD2IiuZUMrwpMuvC1GMrDVTiskDZ80YYv48ydB9wKyL/ducJ3s2RtlUwra3Jxq4+tWKKEnZqE6TQQr2rq9qIKArxL6O3VRnH"
            + "Q2UTde7d2A7ydHJDLih///rgwACtdI4DRg4AAHp2")
        #expect(ChunkContainer.kind(of: container) == .lzma)
        #expect(Data(try ChunkContainer.decompress(container)) == content)
        var broken = container
        broken[broken.count - 10] ^= 0xff                  // CRC32 改坏
        #expect(throws: SteamCMError.self) { try ChunkContainer.decompress(broken) }
    }

    /// CDN 上的**清单**是 zip 容器（分块才是 VSZa）：第一个条目可能是 deflate 压的
    @Test func unpacksZipContainer() throws {
        let zip = [UInt8](base64:
            "UEsDBBQAAAAAAOKLPV2GB/UmSAAAAEgAAAAMAAAAbWFuaWZlc3QuYmluaGVsbG8temlwLXBheWxvYWQtaGVsbG8temlw"
            + "LXBheWxvYWQtaGVsbG8temlwLXBheWxvYWQtaGVsbG8temlwLXBheWxvYWQtUEsDBBQAAAAAAOKLPV1wPAJKDgAAAA4A"
            + "AAAKAAAAc3RvcmVkLmJpbnN0b3JlZC1wYXlsb2FkUEsBAhQDFAAAAAAA4os9XYYH9SZIAAAASAAAAAwAAAAAAAAA"
            + "AAAAAIABAAAAAG1hbmlmZXN0LmJpblBLAQIUAxQAAAAAAOKLPV1wPAJKDgAAAA4AAAAKAAAAAAAAAAAAAACAAXIA"
            + "AABzdG9yZWQuYmluUEsFBgAAAAACAAIAcgAAAKgAAAAAAA==")
        #expect(ChunkContainer.kind(of: zip) == .zip)
        let unpacked = try ChunkContainer.decompress(zip)
        #expect(String(decoding: unpacked, as: UTF8.self) == String(repeating: "hello-zip-payload-", count: 4))
    }

    /// CDN 清单里的**文件名是加密的**：base64 → AES（depot 密钥）→ 取第一个 0 之前的部分
    @Test func decryptsEncryptedFilenames() throws {
        let name = "生草的壁纸/preview.jpg"                    // 名字里带中文和子目录也要能解
        var padded = Array(name.utf8)
        while padded.count % 16 != 0 { padded.append(0) }      // 文件名用 0 填充到 16 字节对齐
        let encrypted = try SteamChunkCipher.encrypt(padded, key: key, iv: iv)
        var mapping = ProtoWriter()
        mapping.field(1, string: Data(encrypted).base64EncodedString())   // filename（加密时放的是 base64）
        mapping.field(2, varint: 123)
        var payload = ProtoWriter()
        payload.field(1, message: mapping)
        var metadata = ProtoWriter()
        metadata.field(1, varint: 431_960)
        metadata.field(2, varint: 42)
        metadata.field(4, bool: true)                          // filenames_encrypted
        let manifest = try ContentManifest(payload: payload.bytes, metadata: metadata.bytes)
        #expect(manifest.filenamesEncrypted)
        let decrypted = try manifest.decryptingFilenames(depotKey: key)
        #expect(decrypted.files.first?.name == name)
        #expect(decrypted.filenamesEncrypted == false)
    }

    /// 没加密的清单原样返回
    @Test func leavesPlainFilenamesAlone() throws {
        let manifest = ContentManifest(
            files: [ContentManifest.File(name: "a.bin", size: 1, chunks: [])], depotID: 1, manifestID: 2)
        #expect(try manifest.decryptingFilenames(depotKey: key).files.first?.name == "a.bin")
    }

    /// 按清单拼文件：两个文件、三个分块，走的是真的下载器（取数据这一步换成假的）
    @Test func downloaderAssemblesFilesFromManifest() async throws {
        let sha = Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let chunk = ContentManifest.Chunk(
            sha: [UInt8](hexString: sha), offset: 0, originalSize: UInt32(content.count),
            compressedSize: UInt32(encryptedChunk.count))
        let manifest = ContentManifest(
            files: [
                ContentManifest.File(name: "project.json", size: UInt64(content.count), chunks: [chunk]),
                ContentManifest.File(
                    name: "nested/blob.bin", size: UInt64(content.count * 2),
                    chunks: [chunk, ContentManifest.Chunk(
                        sha: chunk.sha, offset: UInt64(content.count),
                        originalSize: UInt32(content.count), compressedSize: UInt32(encryptedChunk.count))]),
            ],
            depotID: 431_960, manifestID: 42)

        let blob = encryptedChunk
        let downloader = UGCContentDownloader(fetch: { url in
            guard url.path.hasSuffix(sha) else { throw SteamCMError("要的分块不对：\(url.path)") }
            return blob
        })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steam-ugc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = try await downloader.download(
            manifest, to: directory, hosts: ["content.example.com"], depotKey: key)
        #expect(state.chunksDone == 3)
        #expect(state.filesDone == 2)
        #expect(state.bytesDone == UInt64(content.count * 3))
        #expect(try Data(contentsOf: directory.appendingPathComponent("project.json")) == content)
        #expect(try Data(contentsOf: directory.appendingPathComponent("nested/blob.bin"))
            == content + content)
    }

    /// 所有服务器都回 503（临时忙不过来）：等一会儿再试一轮；404 这种不是临时的，不再试
    @Test func downloaderRetriesTemporaryServerErrors() async throws {
        let manifest = ContentManifest(
            files: [ContentManifest.File(
                name: "a.bin", size: UInt64(content.count),
                chunks: [ContentManifest.Chunk(
                    sha: [UInt8](Insecure.SHA1.hash(data: Data(content))), offset: 0,
                    originalSize: UInt32(content.count), compressedSize: UInt32(encryptedChunk.count))])],
            depotID: 431_960, manifestID: 42)
        final class Attempts: @unchecked Sendable {
            let lock = NSLock()
            var hosts: [String] = []
            func record(_ host: String) -> Int { lock.withLock { hosts.append(host); return hosts.count } }
        }
        let blob = encryptedChunk
        let busy = Attempts()
        // 两台服务器、前两轮都 503，第三轮第一台成功
        let flaky = UGCContentDownloader(fetch: { url in
            let count = busy.record(url.host() ?? "")
            guard count >= 5 else { throw ContentServerError(host: url.host() ?? "", status: 503) }
            return blob
        }, retryDelay: .milliseconds(1))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steam-ugc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await flaky.download(manifest, to: directory, hosts: ["a.example.com", "b.example.com"], depotKey: key)
        #expect(state.chunksDone == 1)
        #expect(busy.hosts == ["a.example.com", "b.example.com", "a.example.com", "b.example.com", "a.example.com"])

        let missing = Attempts()
        let notFound = UGCContentDownloader(fetch: { url in
            _ = missing.record(url.host() ?? "")
            throw ContentServerError(host: url.host() ?? "", status: 404)
        }, retryDelay: .milliseconds(1))
        await #expect(throws: ContentServerError(host: "b.example.com", status: 404)) {
            try await notFound.download(manifest, to: directory, hosts: ["a.example.com", "b.example.com"], depotKey: key)
        }
        #expect(missing.hosts.count == 2, "404 不再试")
        #expect(ContentServerError(host: "x", status: 503).errorDescription?.contains("暂时忙不过来") == true)
    }

    /// 同时下好几个文件（WE 自带素材是几千个小文件）：每个文件都对、进度对得上，而且真的是并发下的
    @Test func downloaderFetchesFilesConcurrently() async throws {
        let sha = Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let chunk = ContentManifest.Chunk(
            sha: [UInt8](hexString: sha), offset: 0, originalSize: UInt32(content.count),
            compressedSize: UInt32(encryptedChunk.count))
        let files = (0..<24).map { ContentManifest.File(name: "dir\($0 % 3)/f\($0).bin", size: UInt64(content.count), chunks: [chunk]) }
        let manifest = ContentManifest(files: files, depotID: 431_961, manifestID: 7)
        final class Gauge: @unchecked Sendable {
            private let lock = NSLock()
            private var running = 0
            private(set) var peak = 0
            func enter() { lock.withLock { running += 1; peak = max(peak, running) } }
            func leave() { lock.withLock { running -= 1 } }
        }
        let gauge = Gauge()
        let blob = encryptedChunk
        let downloader = UGCContentDownloader(fetch: { _ in
            gauge.enter()
            defer { gauge.leave() }
            try await Task.sleep(for: .milliseconds(20))
            return blob
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steam-ugc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await downloader.download(
            manifest, to: directory, hosts: ["content.example.com"], depotKey: key, concurrency: 6)
        #expect(state.filesDone == 24 && state.chunksDone == 24 && state.bytesDone == UInt64(content.count * 24))
        for index in 0..<24 {
            #expect(try Data(contentsOf: directory.appendingPathComponent("dir\(index % 3)/f\(index).bin")) == content)
        }
        #expect(gauge.peak > 1 && gauge.peak <= 6, "同时下的文件数：\(gauge.peak)")
    }

    /// 拿回来的分块如果不是要的那一枚（校验和不对），要停下来
    @Test func downloaderRejectsWrongChunk() async throws {
        let manifest = ContentManifest(
            files: [ContentManifest.File(
                name: "a.bin", size: UInt64(content.count),
                chunks: [ContentManifest.Chunk(
                    sha: [UInt8](repeating: 0, count: 20), offset: 0,
                    originalSize: UInt32(content.count), compressedSize: UInt32(encryptedChunk.count))])],
            depotID: 431_960, manifestID: 42)
        let downloader = UGCContentDownloader(fetch: { _ in self.encryptedChunk })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steam-ugc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: SteamCMError.self) {
            try await downloader.download(
                manifest, to: directory, hosts: ["content.example.com"], depotKey: key)
        }
    }

    /// 内容服务器的字段号（`CContentServerDirectory_ServerInfo`）：host=8、vhost=9、https_support=12
    @Test func parsesContentServerInfo() throws {
        var server = ProtoWriter()
        server.field(1, string: "CDN")
        server.field(8, string: "cache1-lax1.steamcontent.com")
        server.field(9, string: "steamcontent.com")
        server.field(12, string: "mandatory")
        server.field(13, varint: 431_960)

        var response = ProtoWriter()
        response.field(1, message: server)
        var ignored = ProtoWriter()
        ignored.field(1, string: "SteamCache2")          // 不认识的类型要被过滤掉
        ignored.field(8, string: "x.example.com")
        response.field(1, message: ignored)

        let servers = SteamContentServer.list(from: try ProtoMessage(response.bytes))
        #expect(servers.count == 1)
        #expect(servers.first?.host == "cache1-lax1.steamcontent.com")
        #expect(servers.first?.vhost == "steamcontent.com")
        #expect(servers.first?.supportsHTTPS == true)
        #expect(servers.first?.serves(appID: 431_960) == true)
        #expect(servers.first?.serves(appID: 1) == false)
        #expect(servers.first?.chunkURL(depot: 431_960, shaHex: "AB")?.absoluteString
            == "https://cache1-lax1.steamcontent.com/depot/431960/chunk/ab")
    }

    /// depot 密钥是客户端消息（EMsg 5438 → 5439），字段号见 steammessages_clientserver_2.proto
    @Test func depotKeyRequestFields() throws {
        let body = try ProtoMessage(CMRequest.depotDecryptionKey(appID: 431_960, depotID: 431_960).bytes)
        #expect(body.varint(1) == 431_960)               // depot_id
        #expect(body.varint(2) == 431_960)               // app_id
        #expect(EMsg.clientGetDepotDecryptionKey.rawValue == 5438)
        #expect(EMsg.clientGetDepotDecryptionKeyResponse.rawValue == 5439)
    }

    /// 清单请求码是统一服务方法，字段号见 steammessages_contentsystem.steamclient.proto
    @Test func manifestRequestCodeFields() throws {
        let body = try ProtoMessage(
            SteamServiceCall.manifestRequestCode(appID: 431_960, depotID: 431_960, manifestID: 6176428963886766760)
                .bytes)
        #expect(body.varint(1) == 431_960)
        #expect(body.varint(2) == 431_960)
        #expect(body.varint(3) == 6176428963886766760)
        #expect(body.string(4) == "public")
        #expect(SteamServiceCall.method("ContentServerDirectory.GetManifestRequestCode")
            == "ContentServerDirectory.GetManifestRequestCode#1")
    }

    /// 订阅 / 取消订阅 / 我的订阅（都走 CM）：字段号见 steammessages_publishedfile.steamclient.proto
    @Test func publishedFileRequests() throws {
        // publishedfileid 在 CPublishedFile_Subscribe_Request / Unsubscribe_Request 里是 `uint64`（varint），
        // 和 GetDetails 的 `repeated fixed64` 不一样：写成 fixed64 时 Steam 会当成不认识的字段丢掉
        let subscribe = try ProtoMessage(
            SteamServiceCall.subscribeRequest(id: 3807008481, appID: 431960).bytes)
        #expect(subscribe.values(1) == [.varint(3807008481)])   // publishedfileid（uint64）
        #expect(subscribe.varint(2) == 1)                // list_type：订阅列表（不填时 Steam 回成功但什么都不改）
        #expect(subscribe.int32(3) == 431960)            // appid
        #expect(subscribe.bool(4) == true)               // notify_client
        #expect(subscribe.bool(5) == true)               // include_dependencies

        let unsubscribe = try ProtoMessage(
            SteamServiceCall.unsubscribeRequest(id: 42, appID: 431960).bytes)
        #expect(unsubscribe.values(1) == [.varint(42)])
        #expect(unsubscribe.varint(2) == 1)
        #expect(unsubscribe.bool(5) == nil)              // 取消订阅没有 include_dependencies

        // 条目详情那边才是 fixed64（两种别混）
        let details = try ProtoMessage(SteamServiceCall.publishedFileDetails(ids: [7], appID: 431960).bytes)
        #expect(details.values(1) == [.fixed64(7)])

        // 我的订阅：type = mysubscriptions（实测只有这个能列出订阅，myfiles 是"我发布的"）
        let files = try ProtoMessage(SteamServiceCall.userFilesRequest(
            appID: 431960, steamID: 76_561_198_419_273_616, page: 2).bytes)
        #expect(files.fixed64(1) == 76_561_198_419_273_616)
        #expect(files.varint(2) == 431960)
        #expect(files.varint(4) == 2)
        #expect(files.varint(5) == 100)
        #expect(files.string(6) == "mysubscriptions")
    }

    /// 清单里的目录条目、Windows 路径分隔符、符号链接（WE 的创意工坊内容是在 Windows 上传的）
    @Test func downloaderHandlesDirectoriesAndWindowsPaths() async throws {
        let sha = Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let chunk = ContentManifest.Chunk(
            sha: [UInt8](hexString: sha), offset: 0, originalSize: UInt32(content.count),
            compressedSize: UInt32(encryptedChunk.count))
        let manifest = ContentManifest(
            files: [
                ContentManifest.File(name: "web", size: 0, chunks: [], flags: ContentManifest.File.directoryFlag),
                ContentManifest.File(name: "web\\empty", size: 0, chunks: [], flags: ContentManifest.File.directoryFlag),
                ContentManifest.File(name: "web\\js\\app.js", size: UInt64(content.count), chunks: [chunk]),
                ContentManifest.File(
                    name: "escape", size: 0, chunks: [], flags: ContentManifest.File.symlinkFlag,
                    linkTarget: "/etc/passwd"),
            ],
            depotID: 431_960, manifestID: 42)
        // 清单写成磁盘格式再读回来，flags / linktarget 不能丢
        let reparsed = try ContentManifest(data: manifest.encoded())
        #expect(reparsed.files.map(\.flags) == [64, 64, 0, 512])
        #expect(reparsed.files.last?.linkTarget == "/etc/passwd")
        #expect(reparsed.totalBytes == UInt64(content.count))

        let blob = encryptedChunk
        let downloader = UGCContentDownloader(fetch: { _ in blob })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steam-ugc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await downloader.download(
            reparsed, to: directory, hosts: ["content.example.com"], depotKey: key)
        #expect(state.filesDone == 1)
        #expect(try Data(contentsOf: directory.appendingPathComponent("web/js/app.js")) == content)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("web/empty").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        // 符号链接不在本机建；也不能出现名字里带反斜杠的文件
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape").path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.sorted() == ["web"])
    }

    /// 整件下载失败时原来的目录原样不动，也不留临时目录（壁纸库不能扫到半截的项目）
    @Test func installLeavesTargetUntouchedOnFailure() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("steam-ugc-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("3807008481")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("project.json"))

        let manifest = ContentManifest(
            files: [ContentManifest.File(
                name: "project.json", size: UInt64(content.count),
                chunks: [ContentManifest.Chunk(
                    sha: [UInt8](repeating: 0, count: 20), offset: 0,
                    originalSize: UInt32(content.count), compressedSize: UInt32(encryptedChunk.count))])],
            depotID: 431_960, manifestID: 42)
        let blob = encryptedChunk
        let downloader = UGCContentDownloader(fetch: { _ in blob })
        await #expect(throws: SteamCMError.self) {
            try await downloader.install(manifest, at: target, hosts: ["content.example.com"], depotKey: key)
        }
        #expect(try Data(contentsOf: target.appendingPathComponent("project.json")) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["3807008481"])
    }

    /// 更新：整件换进去，旧版本多出来的文件不残留
    @Test func installReplacesThePreviousVersion() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("steam-ugc-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("3807008481")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: target.appendingPathComponent("old-video.mp4"))

        let sha = Insecure.SHA1.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let manifest = ContentManifest(
            files: [ContentManifest.File(
                name: "project.json", size: UInt64(content.count),
                chunks: [ContentManifest.Chunk(
                    sha: [UInt8](hexString: sha), offset: 0, originalSize: UInt32(content.count),
                    compressedSize: UInt32(encryptedChunk.count))])],
            depotID: 431_960, manifestID: 42)
        let blob = encryptedChunk
        let downloader = UGCContentDownloader(fetch: { _ in blob })
        try await downloader.install(manifest, at: target, hosts: ["content.example.com"], depotKey: key)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["project.json"])
        #expect(try Data(contentsOf: target.appendingPathComponent("project.json")) == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["3807008481"])
    }

    /// 清单来自网络：里面的文件名可以带子目录，但不许写到输出目录外面
    @Test func outputPathsCannotEscapeTheDirectory() throws {
        let directory = URL(fileURLWithPath: "/tmp/steam-ugc-root")
        #expect(try UGCContentDownloader.outputURL(for: "assets/a.png", in: directory).path
            == "/tmp/steam-ugc-root/assets/a.png")
        #expect(throws: SteamCMError.self) {
            try UGCContentDownloader.outputURL(for: "../evil.bin", in: directory)
        }
        #expect(throws: SteamCMError.self) {
            try UGCContentDownloader.outputURL(for: "a/../../evil.bin", in: directory)
        }
        #expect(throws: SteamCMError.self) {
            try UGCContentDownloader.outputURL(for: "", in: directory)
        }
    }
}

extension Array where Element == UInt8 {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }

    init(base64: String) {
        self = [UInt8](Data(base64Encoded: base64)!)
    }
}
