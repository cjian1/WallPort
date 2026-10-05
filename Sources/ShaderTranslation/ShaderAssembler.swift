import Foundation

public enum ShaderStage: String, Sendable {
    case vertex = "vert"
    case fragment = "frag"
}

/// 把 WE 方言的着色器拼成一份可以交给 glslang 预处理的完整 GLSL 源码：
/// 版本头 + 方言宏 + 开关的 #define + 展开后的 #include。
///
/// WE 的着色器是"GLSL 的声明写法 + HLSL 的函数名"（mul、frac、saturate、lerp……），
/// 这些函数名和辅助宏（texSample2D、CAST4……）不在任何文件里，是 WE 编译前注入的。
/// 这里按它们在 HLSL 里的语义映射到 GLSL；映射表对照 WE 自带着色器的用法逐项确认。
public enum ShaderAssembler {
    /// 方言宏。WE 的着色器按 HLSL 的习惯写矩阵：m[i][j] 是第 i 行，mat3(…) 按行填，mul(v, M) 是行向量 × 矩阵。
    /// 同样的源码在 GLSL 里 m[i][j] 是第 i 列、构造按列填，得到的是 HLSL 那个矩阵的转置 Mᵀ；
    /// 要算出和 HLSL 一样的 v·M，就得写成 Mᵀ·v，所以 mul(a, b) 映射成 b * a。
    /// （WE 自带的 common_perspective.h 只在 HLSL 分支里自己实现 inverse，GLSL 分支直接用内置的，
    /// 说明它的 GLSL 路径就是这样理解下标的。）uniform 矩阵照常按列主序上传。
    /// sample 在 HLSL 里是普通标识符，在 GLSL 450 里是保留字，改名避开
    static let prelude = """
    #define GLSL 1
    // HLSL 的向量/矩阵类型名：WE 的编译器认，GLSL 不认（语料里有只写 float2 的着色器）
    #define float2 vec2
    #define float3 vec3
    #define float4 vec4
    #define float2x2 mat2
    #define float3x3 mat3
    #define float4x4 mat4
    #define half float
    #define half2 vec2
    #define half3 vec3
    #define half4 vec4
    #define int2 ivec2
    #define int3 ivec3
    #define int4 ivec4
    #define uint2 uvec2
    #define uint3 uvec3
    #define uint4 uvec4
    #define bool2 bvec2
    #define bool3 bvec3
    #define bool4 bvec4
    #define texSample2D texture
    #define texSample2DLod textureLod
    #define mul(a, b) ((b) * (a))
    #define frac fract
    #define saturate(x) clamp((x), 0.0, 1.0)
    #define lerp mix
    #define atan2 atan
    #define ddx dFdx
    #define ddy dFdy
    #define rsqrt inversesqrt
    #define CAST2(x) vec2(x)
    #define CAST3(x) vec3(x)
    #define CAST4(x) vec4(x)
    #define CAST3X3(x) mat3(x)
    #define CASTU(x) uint(x)
    #define fmod(x, y) ((x) - (y) * trunc((x) / (y)))
    #define sample sample_
    """

    public enum AssemblyError: Error, LocalizedError, Equatable {
        case missingInclude(String)

        public var errorDescription: String? {
            switch self {
            case .missingInclude(let name): return "找不到头文件 \(name)"
            }
        }
    }

    /// - Parameters:
    ///   - source: 着色器正文（.vert 或 .frag）
    ///   - defines: 开关和引擎常量，例如 ["MASK": 1]
    ///   - include: 按 "shaders/<名>" 取头文件内容，先找场景包再找 WE 自带素材
    public static func assemble(
        _ source: String, defines: [String: Int], include: (String) -> String?
    ) throws -> String {
        var included = Set<String>()
        let expanded = try expandIncludes(source, include: include, included: &included, depth: 0)
        let defineLines = defines.sorted { $0.key < $1.key }.map { "#define \($0.key) \($0.value)" }
        let body = allowingRedefinitions(
            balancingConditionals(expanded), predefined: Set(defines.keys).union(macroNames(in: prelude)))
        return (["#version 450", prelude] + defineLines + ["#line 1", body]).joined(separator: "\n")
    }

    /// WE 走 HLSL 编译器：同一个宏换了内容再 #define 只是警告，后面的定义生效（3795078488 的音频特效
    /// 自己又定义了一遍 M_PI_2，和 common.h 的不一样）。glslang 把它当错误、整个特效编不出来。
    /// 已经定义过的名字再 #define 时先 #undef，效果和 HLSL 一样。在没生效的 #if 分支里多一句 #undef 也没关系
    static func allowingRedefinitions(_ body: String, predefined: Set<String>) -> String {
        var defined = predefined
        var output: [String] = []
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let name = definedName(line) {
                if defined.contains(name), !name.hasPrefix("GL_"), !name.hasPrefix("__") { output.append("#undef \(name)") }
                defined.insert(name)
            }
            output.append(String(line))
        }
        return output.joined(separator: "\n")
    }

    /// `#define NAME …` / `#define NAME(…) …` 里的 NAME；不是 #define 时为 nil
    static func definedName<S: StringProtocol>(_ line: S) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("#") else { return nil }
        let directive = trimmed.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard directive.hasPrefix("define") else { return nil }
        let rest = directive.dropFirst("define".count)
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        let name = rest.drop { $0 == " " || $0 == "\t" }.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    private static func macroNames(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { definedName($0) })
    }

    /// WE 的编译器容忍收尾处多出来的 #endif，glslang 会直接报 "mismatched statements"
    /// （真实语料里有一例：workshop/2973943998 的 iris_movement__.vert 结尾多写了一个 #endif）。
    /// 拼装后按行统计条件编译深度，把深度已经归零时多出来的 #endif 丢掉，其余原样保留。
    /// 注意只处理 #if/#ifdef/#ifndef/#endif：#elif 和 #else 不改变深度。
    static func balancingConditionals(_ body: String) -> String {
        var depth = 0
        var output: [Substring] = []
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let directive = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if directive.hasPrefix("endif") {
                    if depth == 0 { continue }
                    depth -= 1
                } else if directive.hasPrefix("if") {  // #if / #ifdef / #ifndef
                    depth += 1
                }
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    /// 同一个头文件只展开一次：WE 的头文件没有防重复包含的保护，展开两次会重复定义函数
    private static func expandIncludes(
        _ source: String, include: (String) -> String?, included: inout Set<String>, depth: Int
    ) throws -> String {
        var output: [Substring] = []
        for line in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // #require 引入的是 WE 引擎内部的函数库（例如 LightingV1 提供 PerformLighting_V1），
            // 不在任何素材文件里。只有打开 LIGHTING 等开关时才会用到，先去掉；到时候要自己实现
            if trimmed.hasPrefix("#require") {
                output.append("// \(trimmed)")
                continue
            }
            guard trimmed.hasPrefix("#include"), let name = includeName(trimmed) else {
                output.append(line)
                continue
            }
            guard included.insert(name).inserted, depth < 16 else { continue }
            guard let contents = include("shaders/\(name)") else { throw AssemblyError.missingInclude(name) }
            output.append(Substring(try expandIncludes(contents, include: include, included: &included, depth: depth + 1)))
        }
        return output.joined(separator: "\n")
    }

    static func includeName(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\""),
              let close = line[line.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return String(line[line.index(after: open)..<close])
    }
}
