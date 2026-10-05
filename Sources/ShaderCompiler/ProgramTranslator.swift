import CryptoKit
import Foundation
import ShaderTranslation

/// 一个 WE 着色器程序（顶点 + 片段）翻译后的结果
public struct TranslatedProgram: Sendable, Codable {
    public let vertexMetal: String
    public let fragmentMetal: String
    public let vertexUniforms: UniformBlockLayout
    public let fragmentUniforms: UniformBlockLayout
    public let interface: ShaderInterface
    /// 实际使用的开关取值
    public let defines: [String: Int]
}

/// 把 WE 方言的顶点和片段着色器翻译成 Metal 源码：
/// 读接口 → 定开关 → 拼装 → 预处理 → 结构改写 → SPIR-V → Metal。
///
/// 拼装只是字符串处理，很快；之后的预处理、编译、转换才慢。所以用两个阶段拼装后的源码
/// （已经展开头文件、带上开关）加翻译器版本算缓存键，命中就直接读出结果。
public enum ProgramTranslator {
    /// 翻译逻辑改变时加一，让旧的磁盘缓存失效
    static let version = "2026-09-28.5"

    /// - Parameters:
    ///   - combos: 材质和场景显式设置的开关，优先于着色器里的默认值
    ///   - providedTextures: 给了贴图的槽；关联了开关的槽（例如 MASK）有贴图时打开对应开关
    ///   - include: 按 "shaders/<名>" 取头文件，先找场景包再找 WE 自带素材
    ///   - cacheDirectory: 翻译结果的磁盘缓存目录；nil 时不缓存
    public static func translate(
        vertex: String, fragment: String, combos: [String: Int], providedTextures: Set<Int>,
        include: (String) -> String?, cacheDirectory: URL? = nil
    ) throws -> TranslatedProgram {
        // 接口写在注释里，而材质参数和贴图槽也可能声明在被 #include 的头文件里
        // （例如 common_particles.h 的 g_RefractAmount），所以拼装完（头文件已展开）再读一遍。
        // 先按主文件里的开关拼一版，用展开后的源码读出完整接口；开关有变化时再拼一遍。
        func makeDefines(_ interface: ShaderInterface) -> [String: Int] {
            var defines = Dictionary(interface.combos.map { ($0.name, $0.defaultValue) }, uniquingKeysWith: { $1 })
            for slot in interface.textures {
                if let combo = slot.combo, providedTextures.contains(slot.index) { defines[combo] = 1 }
            }
            defines.merge(combos) { $1 }
            return defines
        }
        var defines = makeDefines(ShaderInterface(sources: [vertex, fragment]))
        var assembledVertex = try ShaderAssembler.assemble(vertex, defines: defines, include: include)
        var assembledFragment = try ShaderAssembler.assemble(fragment, defines: defines, include: include)
        let interface = ShaderInterface(sources: [assembledVertex, assembledFragment])
        let fullDefines = makeDefines(interface)
        if fullDefines != defines {
            defines = fullDefines
            assembledVertex = try ShaderAssembler.assemble(vertex, defines: defines, include: include)
            assembledFragment = try ShaderAssembler.assemble(fragment, defines: defines, include: include)
        }
        let cacheFile = cacheDirectory.map { directory in
            let digest = SHA256.hash(data: Data((version + "\n" + assembledVertex + "\n\u{0}\n" + assembledFragment).utf8))
            return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".json")
        }
        if let cacheFile, let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode(TranslatedProgram.self, from: data) {
            return cached
        }

        var rewriter = GLSLRewriter()
        var results: [ShaderStage: (metal: String, uniforms: [GLSLRewriter.Uniform])] = [:]
        for (stage, assembled) in [(ShaderStage.vertex, assembledVertex), (.fragment, assembledFragment)] {
            let preprocessed: String
            do {
                preprocessed = try ShaderCompiler.preprocess(assembled, stage: stage)
            } catch {
                dumpFailedShader(assembled, log: "\(error)", stage: stage)
                throw error
            }
            let rewritten = rewriter.rewrite(preprocessed, stage: stage)
            let spirv: [UInt32]
            do {
                spirv = try compileFixingConversions(rewritten.source, stage: stage)
            } catch {
                // 翻译失败时把改写后的源码存下来，方便对着报错行看（DUMP_FAILED_SHADERS=1）
                if ProcessInfo.processInfo.environment["DUMP_FAILED_SHADERS"] != nil {
                    let path = URL(fileURLWithPath: "/tmp/macwallpaper-shader-\(stage).glsl")
                    try? rewritten.source.write(to: path, atomically: true, encoding: .utf8)
                    FileHandle.standardError.write(Data("翻译失败，改写后的源码在 \(path.path)\n".utf8))
                }
                throw error
            }
            results[stage] = (try ShaderCompiler.metal(fromSPIRV: spirv), rewritten.uniforms)
        }
        let program = TranslatedProgram(
            vertexMetal: results[.vertex]!.metal, fragmentMetal: results[.fragment]!.metal,
            vertexUniforms: UniformBlockLayout(results[.vertex]!.uniforms),
            fragmentUniforms: UniformBlockLayout(results[.fragment]!.uniforms),
            interface: interface, defines: defines)

        if let cacheFile, let data = try? JSONEncoder().encode(program) {
            try? FileManager.default.createDirectory(
                at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return program
    }

    /// 应用默认的缓存目录：~/Library/Caches/MacWallpaper/Shaders
    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacWallpaper/Shaders", isDirectory: true)
    }

    /// 编译失败时按报错补上 HLSL 式的隐式类型转换再试，最多几轮
    private static func compileFixingConversions(_ source: String, stage: ShaderStage) throws -> [UInt32] {
        var current = source
        var lastLog = ""
        for _ in 0..<8 {
            do {
                return try ShaderCompiler.spirv(current, stage: stage)
            } catch let error as ShaderCompiler.CompileError {
                lastLog = error.log
                guard let fixed = ImplicitConversionFixer.fix(source: current, log: error.log) else {
                    dumpFailedShader(current, log: error.log, stage: stage)
                    throw error
                }
                current = fixed
            }
        }
        do {
            return try ShaderCompiler.spirv(current, stage: stage)
        } catch {
            dumpFailedShader(current, log: lastLog, stage: stage)
            throw error
        }
    }

    /// DUMP_FAILED_SHADERS=1 时把失败那一阶段（补过转换之后）的源码和报错存到 /tmp，方便对着行号看
    private static func dumpFailedShader(_ source: String, log: String, stage: ShaderStage) {
        guard ProcessInfo.processInfo.environment["DUMP_FAILED_SHADERS"] != nil else { return }
        let path = URL(fileURLWithPath: "/tmp/macwallpaper-shader-\(stage)-last.glsl")
        try? source.write(to: path, atomically: true, encoding: .utf8)
        try? log.write(to: URL(fileURLWithPath: "/tmp/macwallpaper-shader-\(stage)-last.log"),
                       atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("失败源码在 \(path.path)\n".utf8))
    }
}
