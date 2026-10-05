import CLzma
import CZstd
import Foundation

/// 内容服务器上的分块/清单外面还包了一层"压缩容器"。本机把真实分块解开、和 SteamCMD 下好的内容
/// 逐字节比对之后，容器长这样（`VSZa`，现在 Valve 主要用它）：
///
///     "VSZa"                        4 字节
///     [解压数据的 CRC32]             4 字节，小端（和尾部那个一样，实测两个都对得上）
///     zstd 数据                      …
///     [解压数据的 CRC32]             4 字节，小端
///     [解压后的长度]                 4 字节，小端
///     0 填充                        4 字节
///     "zsv"                         3 字节
///
/// 旧内容的分块是 LZMA 的 `VZa` 容器（2026-09-29 用户下载 3781567628 时遇到）：
///
///     "VZa"                         3 字节
///     [时间戳或校验，不用]            4 字节
///     [LZMA 参数]                    5 字节（lc/lp/pb + 字典大小）
///     LZMA 数据                      …（没有 .lzma 文件那 8 字节长度头）
///     [解压数据的 CRC32][解压后长度]   各 4 字节，小端
///     "zv"                          2 字节
///
/// 布局按 MIT 许可的 node-steam-user（`components/cdn_compression.js`，只读、未复制代码）；解码器是
/// LZMA SDK 的 `LzmaDec.c`（公有领域，随项目编译，见 Vendor/README.md）。CDN 上的清单是 zip（`PK\x03\x04`）。
public enum ChunkContainer {
    public static let zstdMagic: [UInt8] = Array("VSZa".utf8)
    public static let lzmaMagic: [UInt8] = Array("VZa".utf8)
    public static let zipMagic: [UInt8] = [0x50, 0x4b, 0x03, 0x04]
    public static let zstdFooter: [UInt8] = Array("zsv".utf8)

    /// 容器里的压缩方式
    public enum Kind: String, Sendable, Equatable {
        case zstd = "VSZa（zstd）"
        case lzma = "VZa（LZMA）"
        case zip = "PK（zip）"
    }

    public static func kind(of data: [UInt8]) -> Kind? {
        guard data.count >= 4 else { return nil }
        let head = Array(data[0..<4])
        if head == zstdMagic { return .zstd }
        if Array(head[0..<3]) == lzmaMagic { return .lzma }
        if head == zipMagic { return .zip }
        return nil
    }

    /// 解开容器，拿到里面的原始字节（分块就是文件的一段，清单就是 `ContentManifest` 的字节）
    public static func decompress(_ data: [UInt8]) throws -> [UInt8] {
        guard let kind = kind(of: data) else {
            let head = data.prefix(4).map { String(format: "%02x", $0) }.joined()
            throw SteamCMError("认不出的容器（开头 \(head.isEmpty ? "空" : head)）")
        }
        switch kind {
        case .zstd: return try decompressZstd(data)
        case .zip: return try decompressZip(data)
        case .lzma: return try decompressLZMA(data)
        }
    }

    /// `PK\x03\x04`：内容服务器上的**清单**是用 zip 包的（分块才是 VSZa，2026-09-29 实测）。
    /// 只取第一个条目：按中央目录找到它，再按本地头部的偏移和压缩方式取出内容（stored / deflate）
    private static func decompressZip(_ data: [UInt8]) throws -> [UInt8] {
        // 从尾部往回找中央目录结尾（EOCD 后面最多还有 65535 字节的注释）
        var eocd = -1
        var index = data.count - 22
        while index >= max(0, data.count - 66000) {
            if data[index] == 0x50, data[index + 1] == 0x4b, data[index + 2] == 0x05, data[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard eocd >= 0 else { throw SteamCMError("zip：找不到中央目录结尾") }
        let centralOffset = Int(littleEndian(data, eocd + 16))
        guard centralOffset >= 0, centralOffset + 46 <= data.count,
              Array(data[centralOffset..<(centralOffset + 4)]) == [0x50, 0x4b, 0x01, 0x02]
        else { throw SteamCMError("zip：第一个中央目录条目读不出来") }
        let method = Int(UInt16(littleEndian16(data, centralOffset + 10)))
        let compressedSize = Int(littleEndian(data, centralOffset + 20))
        let uncompressedSize = Int(littleEndian(data, centralOffset + 24))
        let localOffset = Int(littleEndian(data, centralOffset + 42))
        guard localOffset + 30 <= data.count,
              Array(data[localOffset..<(localOffset + 4)]) == [0x50, 0x4b, 0x03, 0x04]
        else { throw SteamCMError("zip：本地文件头读不出来") }
        let nameLength = Int(UInt16(littleEndian16(data, localOffset + 26)))
        let extraLength = Int(UInt16(littleEndian16(data, localOffset + 28)))
        let start = localOffset + 30 + nameLength + extraLength
        guard start >= 0, start + compressedSize <= data.count else {
            throw SteamCMError("zip：条目内容越界")
        }
        let payload = Array(data[start..<(start + compressedSize)])
        switch method {
        case 0: return payload                                  // 不压缩
        case 8:                                                 // deflate
            let unpacked = try Gzip.decompress(payload)
            guard unpacked.count == uncompressedSize else {
                throw SteamCMError("zip：deflate 解出来 \(unpacked.count) 字节，头部说 \(uncompressedSize)")
            }
            return unpacked
        default: throw SteamCMError("zip：不认的压缩方式 \(method)")
        }
    }

    private static func decompressZstd(_ data: [UInt8]) throws -> [UInt8] {
        let footerLength = 15
        guard data.count > zstdMagic.count + footerLength else {
            throw SteamCMError("VSZa 容器太短（\(data.count) 字节）")
        }
        let body = 8                    // "VSZa" + 解压数据的 CRC32
        let end = data.count - footerLength
        let compressed = Array(data[body..<end])
        let headerCRC = littleEndian(data, 4)
        let contentCRC = littleEndian(data, end)
        let contentSize = Int(littleEndian(data, end + 4))
        guard Array(data[(end + 8)...(end + 11)]) == [0, 0, 0, 0] else {
            throw SteamCMError("VSZa 容器尾部的填充不是 0")
        }
        guard Array(data[(end + 12)...]) == zstdFooter else {
            throw SteamCMError("VSZa 容器尾部没有 \"zsv\"")
        }
        var output = [UInt8](repeating: 0, count: contentSize)
        let written = compressed.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                ZSTD_decompress(destination.baseAddress, destination.count, source.baseAddress, source.count)
            }
        }
        guard ZSTD_isError(written) == 0 else {
            throw SteamCMError("zstd 解压失败：\(String(cString: ZSTD_getErrorName(written)))")
        }
        guard written == contentSize else {
            throw SteamCMError("zstd 解出来 \(written) 字节，容器说应该有 \(contentSize)")
        }
        guard CRC32.checksum(output) == contentCRC, headerCRC == contentCRC else {
            throw SteamCMError("解压数据的 CRC32 对不上")
        }
        return output
    }

    private static func decompressLZMA(_ data: [UInt8]) throws -> [UInt8] {
        let header = 3 + 4 + 5
        let footer = 10
        guard data.count > header + footer else { throw SteamCMError("VZa 容器太短（\(data.count) 字节）") }
        guard Array(data[(data.count - 2)...]) == Array("zv".utf8) else {
            throw SteamCMError("VZa 容器尾部没有 \"zv\"")
        }
        let properties = Array(data[7..<12])
        let compressed = Array(data[header..<(data.count - footer)])
        let expectedCRC = littleEndian(data, data.count - footer)
        let size = Int(littleEndian(data, data.count - footer + 4))
        // 分块最大 1 MB 左右；清单也不会太大。长度字段坏了的话别按它去分配几个 GB
        guard size <= 256 << 20 else { throw SteamCMError("VZa 容器说解压后有 \(size) 字节，不合理") }
        var output = [UInt8](repeating: 0, count: size)
        var outputLength = size
        var inputLength = compressed.count
        var status = LZMA_STATUS_NOT_SPECIFIED
        var allocator = ISzAlloc(Alloc: { _, size in malloc(size) }, Free: { _, address in free(address) })
        let result = output.withUnsafeMutableBufferPointer { destination in
            compressed.withUnsafeBufferPointer { source in
                properties.withUnsafeBufferPointer { props in
                    withUnsafePointer(to: &allocator) { alloc in
                        // 只解出容器说的那么多字节（数据末尾可能有也可能没有结束标记），再用 CRC32 核对
                        LzmaDecode(
                            destination.baseAddress, &outputLength, source.baseAddress, &inputLength,
                            props.baseAddress, UInt32(props.count), LZMA_FINISH_ANY, &status, alloc)
                    }
                }
            }
        }
        guard result == SZ_OK else { throw SteamCMError("LZMA 解压失败（错误码 \(result)）") }
        guard outputLength == size else {
            throw SteamCMError("LZMA 解出来 \(outputLength) 字节，容器说应该有 \(size)")
        }
        guard CRC32.checksum(output) == expectedCRC else { throw SteamCMError("LZMA 解压数据的 CRC32 对不上") }
        return output
    }

    private static func littleEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func littleEndian16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /// 组装一个 `VSZa` 容器（测试和造夹具用；Steam 那边只发不让我们发）
    static func zstdContainer(compressed: [UInt8], content: [UInt8]) -> [UInt8] {
        var out = zstdMagic
        CRC32.appendLittleEndian(CRC32.checksum(content), to: &out)
        out += compressed
        CRC32.appendLittleEndian(CRC32.checksum(content), to: &out)
        CRC32.appendLittleEndian(UInt32(content.count), to: &out)
        out += [0, 0, 0, 0]
        out += zstdFooter
        return out
    }
}
