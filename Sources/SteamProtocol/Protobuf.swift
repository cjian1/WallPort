import Foundation

/// 最小的 protobuf 读写，只覆盖 CM 消息用到的几种类型（varint、64/32 位定点、长度前缀）。
///
/// 为什么自己写：Steam 的协议消息都是 protobuf，但整个工程只用到十几条消息、几十个字段，
/// 引入 protobuf 运行时 + protoc 代码生成，比按字段手写的代价大得多；而且消息定义来自 Valve 自己
/// 随客户端发布的 `.proto`（见 REFERENCES.md），字段号是稳定的。
///
/// 字段号 → 类型（wire type）：0 varint、1 fixed64、2 长度前缀、5 fixed32。
public enum ProtoWireType: Int, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

public struct ProtoError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 一条消息里读出来的字段值
public enum ProtoValue: Equatable, Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes([UInt8])
}

/// 按字段号写 protobuf。写入顺序就是字段号顺序（proto2 不要求有序，但这样便于对照 .proto 看）
public struct ProtoWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func field(_ number: Int, varint value: UInt64) {
        key(number, .varint)
        appendVarint(value)
    }

    public mutating func field(_ number: Int, bool value: Bool) {
        field(number, varint: value ? 1 : 0)
    }

    public mutating func field(_ number: Int, int32 value: Int32) {
        field(number, varint: UInt64(bitPattern: Int64(value)))
    }

    public mutating func field(_ number: Int, fixed64 value: UInt64) {
        key(number, .fixed64)
        appendLittleEndian(value)
    }

    public mutating func field(_ number: Int, fixed32 value: UInt32) {
        key(number, .fixed32)
        appendLittleEndian(value)
    }

    public mutating func field(_ number: Int, bytes value: [UInt8]) {
        key(number, .lengthDelimited)
        appendVarint(UInt64(value.count))
        self.bytes += value
    }

    public mutating func field(_ number: Int, string value: String) {
        field(number, bytes: Array(value.utf8))
    }

    public mutating func field(_ number: Int, message value: ProtoWriter) {
        field(number, bytes: value.bytes)
    }

    private mutating func key(_ number: Int, _ wire: ProtoWireType) {
        appendVarint(UInt64(number) << 3 | UInt64(wire.rawValue))
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            let byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            bytes.append(remaining == 0 ? byte : byte | 0x80)
        } while remaining != 0
    }

    private mutating func appendLittleEndian(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8((value >> UInt64(shift)) & 0xff)) }
    }

    private mutating func appendLittleEndian(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }
}

/// 读 protobuf 消息。同一字段号出现多次时按出现顺序全部保留（repeated 字段要按顺序取）
public struct ProtoMessage: Sendable {
    public private(set) var fields: [Int: [ProtoValue]] = [:]

    /// 空消息（回包体为空时用）
    public init() {}

    public init(_ data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let (key, afterKey) = try Self.readVarint(data, offset)
            offset = afterKey
            let number = Int(key >> 3)
            guard number > 0, let wire = ProtoWireType(rawValue: Int(key & 0x7)) else {
                throw ProtoError("字段号 \(number) / 类型 \(key & 0x7) 认不出来")
            }
            let value: ProtoValue
            switch wire {
            case .varint:
                let (raw, next) = try Self.readVarint(data, offset)
                offset = next
                value = .varint(raw)
            case .fixed64:
                guard offset + 8 <= data.count else { throw ProtoError("fixed64 越界") }
                value = .fixed64(Self.littleEndian(data[offset..<offset + 8]))
                offset += 8
            case .fixed32:
                guard offset + 4 <= data.count else { throw ProtoError("fixed32 越界") }
                value = .fixed32(UInt32(Self.littleEndian(data[offset..<offset + 4])))
                offset += 4
            case .lengthDelimited:
                let (length, next) = try Self.readVarint(data, offset)
                offset = next
                // 先按 UInt64 比：数据来自网络，坏掉的长度可能大到 Int(length) 直接溢出崩溃
                guard length <= UInt64(data.count - offset) else { throw ProtoError("长度前缀越界") }
                value = .bytes(Array(data[offset..<offset + Int(length)]))
                offset += Int(length)
            }
            fields[number, default: []].append(value)
        }
    }

    public func values(_ number: Int) -> [ProtoValue] { fields[number] ?? [] }

    public func varint(_ number: Int) -> UInt64? {
        guard case .varint(let value)? = values(number).last else { return nil }
        return value
    }

    public func bool(_ number: Int) -> Bool? { varint(number).map { $0 != 0 } }

    /// int32 / int64 字段：protobuf 用补码 varint 表示负数
    public func int32(_ number: Int) -> Int32? { varint(number).map { Int32(truncatingIfNeeded: $0) } }

    public func fixed64(_ number: Int) -> UInt64? {
        guard case .fixed64(let value)? = values(number).last else { return nil }
        return value
    }

    public func fixed32(_ number: Int) -> UInt32? {
        guard case .fixed32(let value)? = values(number).last else { return nil }
        return value
    }

    public func bytes(_ number: Int) -> [UInt8]? {
        guard case .bytes(let value)? = values(number).last else { return nil }
        return value
    }

    public func string(_ number: Int) -> String? { bytes(number).map { String(decoding: $0, as: UTF8.self) } }

    public func message(_ number: Int) -> ProtoMessage? {
        guard let data = bytes(number) else { return nil }
        return try? ProtoMessage(data)
    }

    /// 认不出来的字段也留一份，方便排查（打印用）
    public var fieldNumbers: [Int] { fields.keys.sorted() }

    static func readVarint(_ data: [UInt8], _ offset: Int) throws -> (UInt64, Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = offset
        while index < data.count {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
            guard shift < 64 else { throw ProtoError("varint 太长") }
        }
        throw ProtoError("varint 读到结尾")
    }

    static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() { value |= UInt64(byte) << UInt64(index * 8) }
        return value
    }
}
