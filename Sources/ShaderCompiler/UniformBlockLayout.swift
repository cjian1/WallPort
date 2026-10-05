import Foundation
import ShaderTranslation
import simd

/// uniform 块的内存布局。改写时用的是 `layout(scalar)`：成员按声明顺序紧密排列，
/// 每个分量 4 字节，没有 std140 那种按 16 字节对齐的填充；矩阵按列存放。
public struct UniformBlockLayout: Sendable, Codable {
    public struct Member: Sendable {
        public let name: String
        public let type: String
        public let offset: Int
        /// 每个元素占的字节数
        public let elementSize: Int
        public let count: Int
    }

    public let members: [Member]
    public let size: Int
    private let byName: [String: Int]
    private let uniforms: [GLSLRewriter.Uniform]

    public init(from decoder: any Decoder) throws {
        self.init(try [GLSLRewriter.Uniform](from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try uniforms.encode(to: encoder)
    }

    public init(_ uniforms: [GLSLRewriter.Uniform]) {
        self.uniforms = uniforms
        var offset = 0
        var members: [Member] = []
        for uniform in uniforms {
            let elementSize = Self.componentCount(uniform.type) * 4
            let count = uniform.count ?? 1
            members.append(Member(name: uniform.name, type: uniform.type, offset: offset, elementSize: elementSize, count: count))
            offset += elementSize * count
        }
        self.members = members
        size = offset
        byName = Dictionary(members.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func member(_ name: String) -> Member? {
        byName[name].map { members[$0] }
    }

    /// 类型占几个 4 字节分量。矩阵 matCxR 是 C 列、每列 R 个分量
    static func componentCount(_ type: String) -> Int {
        switch type {
        case "float", "int", "uint", "bool": return 1
        case "vec2", "ivec2", "uvec2", "bvec2": return 2
        case "vec3", "ivec3", "uvec3", "bvec3": return 3
        case "vec4", "ivec4", "uvec4", "bvec4": return 4
        case "mat2", "mat2x2": return 4
        case "mat3", "mat3x3": return 9
        case "mat4", "mat4x4": return 16
        case "mat2x3": return 6
        case "mat2x4": return 8
        case "mat3x2": return 6
        case "mat3x4": return 12
        case "mat4x2": return 8
        case "mat4x3": return 12
        default: return 4
        }
    }
}

/// 按布局往 uniform 块里写值。没写的成员保持 0
public struct UniformBuffer {
    public let layout: UniformBlockLayout
    public private(set) var bytes: [UInt8]

    public init(layout: UniformBlockLayout) {
        self.layout = layout
        bytes = [UInt8](repeating: 0, count: max(layout.size, 16))
    }

    /// 写浮点分量。整数类型的成员会转换成整数再写；超出成员大小的部分丢弃
    public mutating func set(_ name: String, _ values: [Float]) {
        guard let member = layout.member(name) else { return }
        let isInteger = member.type.hasPrefix("int") || member.type.hasPrefix("ivec")
            || member.type.hasPrefix("uint") || member.type.hasPrefix("uvec") || member.type.hasPrefix("bool")
        let capacity = member.elementSize / 4 * member.count
        for (index, value) in values.prefix(capacity).enumerated() {
            let bits = isInteger ? UInt32(bitPattern: Int32(value)) : value.bitPattern
            let offset = member.offset + index * 4
            withUnsafeBytes(of: bits.littleEndian) { raw in
                for byte in 0..<4 { bytes[offset + byte] = raw[byte] }
            }
        }
    }

    /// 写矩阵，按列主序。WE 着色器里的 mul(v, M) 翻译成 GLSL 的 M * v（见 ShaderAssembler.prelude），
    /// 所以传常规的"列向量"矩阵即可
    public mutating func setMatrix(_ name: String, _ matrix: simd_float4x4) {
        let columns = (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
        set(name, columns)
    }

    public func has(_ name: String) -> Bool {
        layout.member(name) != nil
    }

    /// 读回某个成员现在的值（整数类型换回浮点）；没有这个成员时为 nil
    public func values(_ name: String) -> [Float]? {
        guard let member = layout.member(name) else { return nil }
        let isInteger = member.type.hasPrefix("int") || member.type.hasPrefix("ivec")
            || member.type.hasPrefix("uint") || member.type.hasPrefix("uvec") || member.type.hasPrefix("bool")
        let capacity = member.elementSize / 4 * member.count
        return (0..<capacity).map { index in
            let offset = member.offset + index * 4
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            return isInteger ? Float(Int32(bitPattern: bits)) : Float(bitPattern: bits)
        }
    }
}
