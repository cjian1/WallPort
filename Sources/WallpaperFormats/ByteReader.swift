import Foundation

/// 格式文件读到一半出了问题
public struct FormatError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 按顺序读取小端整数和字符串。所有读取都做边界检查，越界抛错而不是崩溃：
/// 这些文件来自创意工坊，必须当作不可信输入
struct ByteReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    /// 跳到文件里的绝对位置（从数据开头算）
    mutating func seek(to position: Int) throws {
        guard position >= 0, position <= data.count else {
            throw FormatError("要跳到偏移 \(position)，文件只有 \(data.count) 字节")
        }
        offset = position
    }

    /// 从当前位置往后找一段字节，返回它的绝对位置
    func find(_ pattern: Data) -> Int? {
        let start = data.startIndex + offset
        return data[start...].range(of: pattern).map { $0.lowerBound - data.startIndex }
    }

    mutating func uint32() throws -> UInt32 {
        let bytes = try self.bytes(4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    mutating func uint16() throws -> UInt16 {
        let bytes = try self.bytes(2)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    mutating func int32() throws -> Int32 {
        Int32(bitPattern: try uint32())
    }

    mutating func float32() throws -> Float {
        Float(bitPattern: try uint32())
    }

    /// 读一个长度不超过 limit 的非负整数，用作后续读取的长度或个数
    mutating func count(limit: Int, what: String) throws -> Int {
        let value = Int(try uint32())
        guard value <= limit else { throw FormatError("\(what) 为 \(value)，超过上限 \(limit)，文件可能已损坏") }
        return value
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw FormatError("在偏移 \(offset) 处需要 \(count) 字节，只剩 \(remaining) 字节")
        }
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start..<(start + count))
    }

    mutating func string(_ length: Int) throws -> String {
        let raw = try bytes(length)
        guard let text = String(data: raw, encoding: .utf8) else {
            throw FormatError("偏移 \(offset - length) 处的字符串不是有效的 UTF-8")
        }
        return text
    }

    /// 看一眼接下来的 length 字节（按 UTF-8 解释），不移动位置
    func peekString(_ length: Int) throws -> String {
        guard length <= remaining else { throw FormatError("在偏移 \(offset) 处需要 \(length) 字节，只剩 \(remaining) 字节") }
        let start = data.startIndex + offset
        return String(decoding: data[start..<(start + length)], as: UTF8.self)
    }

    /// 以 NUL 结尾的字符串，最长 limit 字节（不含 NUL）
    mutating func cString(limit: Int) throws -> String {
        let start = data.startIndex + offset
        let end = min(data.endIndex, start + limit + 1)
        guard let terminator = data[start..<end].firstIndex(of: 0) else {
            throw FormatError("偏移 \(offset) 处没有在 \(limit) 字节内找到字符串结尾")
        }
        let text = String(decoding: data[start..<terminator], as: UTF8.self)
        offset += terminator - start + 1
        return text
    }
}
