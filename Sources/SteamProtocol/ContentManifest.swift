import Foundation

/// UGC（创意工坊）的清单：告诉客户端这个条目有哪些文件、每个文件由哪些分块拼成。
///
/// 磁盘上的 `.manifest` 文件结构（2026-09-29 对着本机 SteamCMD 下载时缓存的
/// `depotcache/431960_6176428963886766760.manifest` 逐字节核对）：
///
///     [magic 0x71F617D0][长度][ContentManifestPayload]
///     [magic 0x1F4812BE][长度][ContentManifestMetadata]
///     [magic 0x1B81B817][长度][ContentManifestSignature]
///     [magic 0x32C415AB]
///
/// 每一段都有自己的 magic，别按"连续的长度前缀"去读（本机那份清单里四个 magic 正好都在，
/// 可以对照）。SteamCMD 留在 depotcache 里的那份文件名是明文；**CDN 上取的清单文件名是加密的**
/// （`filenames_encrypted`，用 depot 密钥解，见 `decryptingFilenames`）。消息字段号见 Valve 的
/// `content_manifest.proto`。
public struct ContentManifest: Sendable {
    public static let payloadMagic: UInt32 = 0x71F6_17D0
    public static let metadataMagic: UInt32 = 0x1F48_12BE
    public static let signatureMagic: UInt32 = 0x1B81_B817
    public static let endMagic: UInt32 = 0x32C4_15AB

    public struct Chunk: Sendable, Equatable {
        /// 分块的 SHA-1，下载地址就是 `/depot/<depot>/chunk/<十六进制>`
        public let sha: [UInt8]
        public let offset: UInt64
        /// 解压后 / 压缩后的字节数；两者不同说明分块是压缩过的
        public let originalSize: UInt32
        public let compressedSize: UInt32

        public var shaHex: String { sha.map { String(format: "%02x", $0) }.joined() }
        public var isCompressed: Bool { compressedSize != 0 && compressedSize != originalSize }
    }

    public struct File: Sendable, Equatable {
        public let name: String
        public let size: UInt64
        public let chunks: [Chunk]
        /// `FileMapping.flags`（EDepotFileFlag）：64 = 目录、512 = 符号链接
        public let flags: UInt32
        /// 符号链接指向哪里（`FileMapping.linktarget`）
        public let linkTarget: String?

        public init(name: String, size: UInt64, chunks: [Chunk], flags: UInt32 = 0, linkTarget: String? = nil) {
            self.name = name
            self.size = size
            self.chunks = chunks
            self.flags = flags
            self.linkTarget = linkTarget
        }

        public static let directoryFlag: UInt32 = 64
        public static let symlinkFlag: UInt32 = 512

        /// 清单里的目录条目（没有内容，只是让空目录也能建出来）
        public var isDirectory: Bool { flags & Self.directoryFlag != 0 }
        public var isSymlink: Bool { flags & Self.symlinkFlag != 0 || !(linkTarget ?? "").isEmpty }

        /// 相对路径：WE 的创意工坊内容都是在 Windows 上传的，路径分隔符可能是 `\`；统一换成 `/`，
        /// 不然子目录里的文件会变成根目录下一个名字里带反斜杠的文件（Windows 文件名里本来就不能有 `\`）
        public var relativePath: String { name.replacingOccurrences(of: "\\", with: "/") }
    }

    public private(set) var files: [File]
    /// 元数据（depot 编号、清单编号、总字节数…）
    public let depotID: UInt32
    public let manifestID: UInt64
    /// 清单里的**文件名是加密的**（CDN 上取的清单就是这样，SteamCMD 留在 depotcache 里的那份已经解开了）
    public private(set) var filenamesEncrypted: Bool

    public var totalBytes: UInt64 { files.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } }
    public var chunkCount: Int { files.reduce(0) { $0 + $1.chunks.count } }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw SteamCMError("清单太短（\(bytes.count) 字节）") }
        var offset = 0
        let payload = try Self.section(bytes, at: &offset, expecting: Self.payloadMagic)
        let metadata = try Self.section(bytes, at: &offset, expecting: Self.metadataMagic)
        _ = try? Self.section(bytes, at: &offset, expecting: Self.signatureMagic)
        try self.init(payload: payload, metadata: metadata)
    }

    /// 从载荷段和元数据段的字节装出清单（`init(data:)` 和测试都用它）
    init(payload: [UInt8], metadata: [UInt8]) throws {
        let payloadMessage = try ProtoMessage(payload)
        let metadataMessage = metadata.isEmpty ? ProtoMessage() : (try? ProtoMessage(metadata)) ?? ProtoMessage()
        depotID = UInt32(truncatingIfNeeded: metadataMessage.varint(1) ?? 0)
        manifestID = metadataMessage.varint(2) ?? 0
        filenamesEncrypted = (metadataMessage.varint(4) ?? 0) != 0
        files = payloadMessage.values(1).compactMap { value -> File? in
            guard case .bytes(let data) = value, let mapping = try? ProtoMessage(data) else { return nil }
            guard let name = mapping.string(1) else { return nil }
            let chunks = mapping.values(6).compactMap { chunk -> Chunk? in
                guard case .bytes(let data) = chunk, let message = try? ProtoMessage(data),
                      let sha = message.bytes(1)
                else { return nil }
                return Chunk(
                    sha: sha, offset: message.varint(3) ?? 0,
                    originalSize: UInt32(truncatingIfNeeded: message.varint(4) ?? 0),
                    compressedSize: UInt32(truncatingIfNeeded: message.varint(5) ?? 0))
            }
            return File(
                name: name, size: mapping.varint(2) ?? 0, chunks: chunks,
                flags: UInt32(truncatingIfNeeded: mapping.varint(3) ?? 0), linkTarget: mapping.string(7))
        }
    }

    /// 从内存里拼出完整的 manifest 文件（测试和离线工具用）
    public init(files: [File], depotID: UInt32, manifestID: UInt64) {
        self.files = files
        self.depotID = depotID
        self.manifestID = manifestID
        filenamesEncrypted = false
    }

    /// 用 depot 密钥把文件名解开（CDN 上的清单文件名是加密的：base64 → AES（ECB 解出 IV + CBC）
    /// → 取第一个 0 字节之前的部分当 UTF-8）。没加密就原样返回
    public func decryptingFilenames(depotKey: [UInt8]) throws -> ContentManifest {
        guard filenamesEncrypted else { return self }
        let decrypted = try files.map { file -> File in
            let bytes = Self.base64Bytes(file.name)
            guard let bytes, !bytes.isEmpty else {
                throw SteamCMError("加密的文件名不是 base64（\(file.name.utf8.count) 字节）：\(file.name)")
            }
            let plain = try SteamChunkCipher.decrypt(bytes, key: depotKey)
            let name = String(decoding: plain.prefix { $0 != 0 }, as: UTF8.self)
            guard !name.isEmpty else { throw SteamCMError("文件名解出来是空的") }
            return File(
                name: name, size: file.size, chunks: file.chunks, flags: file.flags, linkTarget: file.linkTarget)
        }
        var copy = self
        copy.files = decrypted
        copy.filenamesEncrypted = false
        return copy
    }

    /// 清单里的文件名是 base64（标准或 URL-safe，可能少了 `=` 填充）
    static func base64Bytes(_ text: String) -> [UInt8]? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value.removeAll { $0 == "\n" || $0 == "\r" }
        while value.count % 4 != 0 { value += "=" }
        guard let data = Data(base64Encoded: value) else { return nil }
        return [UInt8](data)
    }

    /// 把清单写成磁盘上的样子
    public func encoded() -> Data {
        var payload = ProtoWriter()
        for file in files {
            var mapping = ProtoWriter()
            mapping.field(1, string: file.name)
            mapping.field(2, varint: file.size)
            if file.flags != 0 { mapping.field(3, varint: UInt64(file.flags)) }
            if let target = file.linkTarget { mapping.field(7, string: target) }
            for chunk in file.chunks {
                var encoded = ProtoWriter()
                encoded.field(1, bytes: chunk.sha)
                encoded.field(3, varint: chunk.offset)
                encoded.field(4, varint: UInt64(chunk.originalSize))
                encoded.field(5, varint: UInt64(chunk.compressedSize))
                mapping.field(6, message: encoded)
            }
            payload.field(1, message: mapping)
        }
        var metadata = ProtoWriter()
        metadata.field(1, varint: UInt64(depotID))
        metadata.field(2, varint: manifestID)
        var out = Data()
        out.append(contentsOf: Self.section(payload.bytes, magic: Self.payloadMagic))
        out.append(contentsOf: Self.section(metadata.bytes, magic: Self.metadataMagic))
        out.append(contentsOf: Self.section([], magic: Self.signatureMagic))   // 还没有签名
        out.append(contentsOf: Self.uint32Bytes(Self.endMagic))
        return out
    }

    // MARK: - 细节

    private static func section(_ data: [UInt8], at offset: inout Int, expecting magic: UInt32) throws -> [UInt8] {
        guard offset + 8 <= data.count else { throw SteamCMError("清单在段落头处就结束了") }
        let found = uint32(data, offset)
        guard found == magic else {
            throw SteamCMError(String(format: "清单段落的 magic 不对：期望 0x%08X，读到 0x%08X", magic, found))
        }
        let length = Int(uint32(data, offset + 4))
        let start = offset + 8
        guard start + length <= data.count else { throw SteamCMError("清单的段落长度越界") }
        offset = start + length
        return Array(data[start..<start + length])
    }

    private static func section(_ bytes: [UInt8], magic: UInt32) -> Data {
        Data(uint32Bytes(magic) + uint32Bytes(UInt32(bytes.count)) + bytes)
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func uint32Bytes(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> UInt32($0 * 8)) & 0xff) }
    }
}
