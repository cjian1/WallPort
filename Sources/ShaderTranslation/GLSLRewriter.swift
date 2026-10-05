import Foundation

/// 把预处理之后的 WE 方言（已经没有 #if、宏和注释）改写成 glslang 能编成 Vulkan SPIR-V 的 GLSL 450：
///
/// - `attribute` → 带 location 的顶点输入；
/// - `varying` → 带 location 的输出（顶点）或输入（片段）。两个阶段用同一张按名字分配的表，
///   这样同名的 varying 一定对得上（之前的验证里，按声明顺序分别计数会让两边错位）；
/// - 普通 uniform 收进一个 `layout(scalar)` 的 uniform 块，成员紧密排列，原生一侧按声明顺序就能算出偏移；
/// - 所有声明都提到文件开头：WE 的头文件里会用到主文件在 #include 之后才声明的贴图，
///   HLSL 那边不在乎顺序，GLSL 要求先声明后使用。预处理之后已经没有条件编译，提前是安全的；
/// - `int x = 表达式;` 包一层 int()：HLSL 允许浮点隐式转整数（截断），GLSL 不允许，int() 的结果相同；
/// - `g_TextureN` 贴图绑定到 N + 1（0 留给 uniform 块），其他贴图从 32 起编号；
/// - `gl_FragColor` → 片段输出变量；
/// - 片段着色器里同名 varying 的类型比顶点输出的少分量时（D3D 允许只读一部分分量，Metal 要求类型一致），
///   按顶点的类型接收、换个名字，再在 main 开头截断赋给原名的普通变量；
///   片段读了顶点没有输出的 varying 时，改成值为 0 的普通变量。
public struct GLSLRewriter {
    /// 两个阶段共用的 varying 编号表
    public private(set) var varyingLocations: [String: Int] = [:]
    /// 顶点着色器输出的 varying 类型，改写片段着色器时用来对齐
    private var vertexVaryingTypes: [String: String] = [:]
    /// 下一个可用的 varying location（数组 varying 会占连续多个位置）
    private var nextVaryingLocation = 0
    /// 顶点阶段每个 varying 的元素个数（数组 varying 对齐用）
    private var vertexVaryingCounts: [String: Int] = [:]
    /// 是否已经改写过顶点阶段；单独改写片段着色器时不做对齐
    private var hasVertexStage = false

    public struct Result: Equatable, Sendable {
        public let source: String
        /// uniform 块里的成员，按声明顺序
        public let uniforms: [Uniform]
    }

    public struct Uniform: Equatable, Sendable, Codable {
        public let name: String
        public let type: String
        /// 数组长度；不是数组时为 nil
        public let count: Int?
    }

    public init() {}

    public mutating func rewrite(_ preprocessed: String, stage: ShaderStage) -> Result {
        var declarations: [String] = []
        var lines: [String] = []
        var uniforms: [Uniform] = []
        var seenUniforms = Set<String>()
        var seenDeclarations = Set<String>()
        var nextAttribute = 0
        var nextOtherSampler = 32
        var mainPrologue: [String] = []
        if stage == .vertex { hasVertexStage = true }

        for raw in preprocessed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#version") || trimmed.hasPrefix("#line") { continue }

            if let declaration = Self.declaration(trimmed, keyword: "attribute") {
                guard seenDeclarations.insert(declaration.name).inserted else { continue }
                declarations.append("layout(location = \(nextAttribute)) in \(declaration.type) \(declaration.name);")
                nextAttribute += 1
            } else if let declaration = Self.declaration(trimmed, keyword: "varying") {
                guard seenDeclarations.insert(declaration.name).inserted else { continue }
                let name = declaration.name
                if stage == .vertex {
                    vertexVaryingTypes[name] = declaration.type
                    vertexVaryingCounts[name] = declaration.count ?? 1
                } else if declaration.suffix.isEmpty, hasVertexStage {
                    guard let vertexType = vertexVaryingTypes[name] else {
                        // 顶点没有输出它：D3D 里读到的是 0
                        declarations.append("\(declaration.type) \(name) = \(declaration.type)(0);")
                        continue
                    }
                    if vertexType != declaration.type {
                        let location = varyingLocation(name, count: vertexVaryingCounts[name] ?? 1)
                        declarations.append("layout(location = \(location)) in \(vertexType) _varying_\(name);")
                        declarations.append("\(declaration.type) \(name);")
                        mainPrologue.append("\(name) = \(declaration.type)(_varying_\(name));")
                        continue
                    }
                }
                let location = varyingLocation(name, count: declaration.count ?? 1)
                let direction = stage == .vertex ? "out" : "in"
                declarations.append("layout(location = \(location)) \(direction) \(declaration.type) \(name)\(declaration.suffix);")
            } else if let declaration = Self.declaration(trimmed, keyword: "uniform") {
                if declaration.type.hasPrefix("sampler") {
                    let type = declaration.type == "sampler2DComparison" ? "sampler2DShadow" : declaration.type
                    let binding: Int
                    if declaration.name.hasPrefix("g_Texture"), let index = Int(declaration.name.dropFirst(9)) {
                        binding = index + 1
                    } else {
                        binding = nextOtherSampler
                        nextOtherSampler += 1
                    }
                    guard seenDeclarations.insert(declaration.name).inserted else { continue }
                    declarations.append("layout(binding = \(binding)) uniform \(type) \(declaration.name);")
                } else {
                    if seenUniforms.insert(declaration.name).inserted {
                        uniforms.append(Uniform(name: declaration.name, type: declaration.type, count: declaration.count))
                    }
                }
            } else {
                lines.append(Self.castIntegerInitializer(line).replacingOccurrences(of: "gl_FragColor", with: "_fragColor"))
            }
        }

        if !mainPrologue.isEmpty, let main = lines.firstIndex(where: { $0.contains("void main") }),
           let brace = lines[main...].firstIndex(where: { $0.contains("{") }) {
            let line = lines[brace]
            let open = line.firstIndex(of: "{")!
            lines[brace] = String(line[...open]) + " " + mainPrologue.joined(separator: " ") + String(line[line.index(after: open)...])
        }

        var header = ["#version 450", "#extension GL_EXT_scalar_block_layout : require"]
        if stage == .fragment { header.append("layout(location = 0) out vec4 _fragColor;") }
        if !uniforms.isEmpty {
            let members = uniforms.map { "    \($0.type) \($0.name)\($0.count.map { "[\($0)]" } ?? "");" }
            header += ["layout(scalar, binding = 0) uniform WallpaperUniforms {"] + members + ["};"]
        }
        return Result(source: (header + declarations + lines).joined(separator: "\n"), uniforms: uniforms)
    }

    /// `int x = 表达式;` → `int x = int(表达式);`。一行里声明多个变量的不处理
    static func castIntegerInitializer(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("int "), trimmed.hasSuffix(";"), !trimmed.contains(","),
              let equals = trimmed.firstIndex(of: "=")
        else { return line }
        let name = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return line }
        let value = trimmed[trimmed.index(after: equals)...].dropLast().trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return "\(indent)int \(name) = int(\(value));"
    }

    /// varying 的 location。数组 varying 会占连续多个 location，所以计数器要按元素个数往前推，
    /// 不然下一个 varying 会拿到被数组占掉的位置（glslang 报 "overlapping use of location N"）
    private mutating func varyingLocation(_ name: String, count: Int = 1) -> Int {
        if let location = varyingLocations[name] { return location }
        let location = nextVaryingLocation
        varyingLocations[name] = location
        nextVaryingLocation += max(1, count)
        return location
    }

    /// `<关键字> [精度] <类型> <名字>[数组];`
    static func declaration(_ line: String, keyword: String) -> (type: String, name: String, suffix: String, count: Int?)? {
        guard line.hasPrefix(keyword + " "), line.hasSuffix(";") else { return nil }
        let precisions: Set<String> = ["highp", "mediump", "lowp", "flat"]
        let words = line.dropFirst(keyword.count).dropLast().split(separator: " ").map(String.init)
            .filter { !precisions.contains($0) }
        guard words.count == 2 else { return nil }
        let nameAndArray = words[1]
        guard let bracket = nameAndArray.firstIndex(of: "[") else {
            return (words[0], nameAndArray, "", nil)
        }
        let name = String(nameAndArray[..<bracket])
        let suffix = String(nameAndArray[bracket...])
        let count = Int(suffix.dropFirst().dropLast().trimmingCharacters(in: .whitespaces))
        return (words[0], name, suffix, count)
    }
}
