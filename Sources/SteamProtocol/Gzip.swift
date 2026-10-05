import Foundation
import zlib

/// gzip / zlib 解压（系统自带的 libz）。Steam 用 `CMsgMulti` 打包消息时会 gzip 压一层
enum Gzip {
    /// 解开 gzip 或 zlib 流（靠 `inflateInit2` 的 15 + 32：自动识别两种头）
    static func decompress(_ data: [UInt8]) throws -> [UInt8] {
        // 先按"自动识别 gzip/zlib"，不行再按裸 deflate 试一遍
        if let output = try? inflateData(data, windowBits: 15 + 32) { return output }
        return try inflateData(data, windowBits: -15)
    }

    private static func inflateData(_ data: [UInt8], windowBits: Int32) throws -> [UInt8] {
        var stream = z_stream()
        // 15 位窗口 + 32 = 自动识别 gzip/zlib 头
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SteamCMError("zlib 初始化失败")
        }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        var input = data
        var chunk = [UInt8](repeating: 0, count: 65536)
        let status: Int32 = input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = uInt(source.count)
            var result: Int32 = Z_OK
            repeat {
                let produced: Int = chunk.withUnsafeMutableBufferPointer { destination in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(destination.count)
                    result = inflate(&stream, Z_NO_FLUSH)
                    return destination.count - Int(stream.avail_out)
                }
                if produced > 0 { output += chunk[0..<produced] }
                // 输入用完还没结束就说明数据不全，交给调用方报错；Z_BUF_ERROR 是"这次没前进"，
                // 但下一轮有输出缓冲就还能继续，所以按"有没有进展"判断
                if result == Z_STREAM_END { break }
                if stream.avail_in == 0 && produced == 0 { break }
                if result != Z_OK && result != Z_BUF_ERROR { break }
            } while true
            return result
        }
        guard status == Z_STREAM_END else { throw SteamCMError("解压失败（zlib 状态 \(status)）") }
        return output
    }
}
