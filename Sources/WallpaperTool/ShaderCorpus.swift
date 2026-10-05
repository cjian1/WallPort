import Foundation
import Metal
import ShaderCompiler
import ShaderTranslation
import WallpaperFormats
import WallpaperLibrary

/// 着色器翻译的对照实验：找出目录下全部场景实际用到的着色器组合（着色器 + 开关），
/// 逐个走完整条流水线，统计每一步的通过率和失败原因。
///
/// 流水线：拼装（方言宏、开关、头文件）→ glslang 预处理 → 结构改写 → glslang 编成 SPIR-V
/// （失败时按报错补隐式类型转换）→ SPIRV-Cross 转 Metal → Metal 编译两个阶段并连成管线。
func shaderCorpus(in directory: String, assets: URL, output: String) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    let workRoot = URL(fileURLWithPath: output, isDirectory: true)
    try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)

    var programs: [String: CorpusProgram] = [:]
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for folder in folders {
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene,
              let package = try? ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))
        else { continue }
        let files = CorpusFiles(package: package, assets: assets)
        for program in collectPrograms(files: files) {
            let key = program.key
            if programs[key] == nil {
                programs[key] = program
            } else {
                programs[key]?.useCount += 1
            }
        }
    }

    print("场景里用到的着色器组合：\(programs.count) 个（按着色器 + 开关去重）")
    var stageFailures: [String: Int] = [:]
    var reasons: [String: [String]] = [:]
    var passed = 0
    for (index, program) in programs.values.sorted(by: { $0.key < $1.key }).enumerated() {
        let directory = workRoot.appendingPathComponent(String(format: "%03d-", index) + program.shader.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch translate(program, device: device, directory: directory) {
        case .success:
            passed += 1
        case .failure(let failure):
            stageFailures[failure.stage, default: 0] += 1
            reasons[failure.stage + "：" + failure.summary, default: []].append(program.label)
        }
    }

    print(String(format: "\n完整通过（连成 Metal 管线）：%d / %d（%.1f%%）", passed, programs.count,
                 Double(passed) / Double(max(programs.count, 1)) * 100))
    for (stage, count) in stageFailures.sorted(by: { $0.value > $1.value }) {
        print("  卡在\(stage)：\(count)")
    }
    if !reasons.isEmpty {
        print("\n失败原因（每类列出前 3 个组合）：")
        for (reason, labels) in reasons.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(labels.count) × \(reason)")
            labels.prefix(3).forEach { print("      \($0)") }
        }
    }
    print("\n中间文件在 \(workRoot.path)（含 WE 和壁纸作者的着色器，不要放进仓库）")
    return passed == programs.count ? 0 : 1
}

// MARK: - 收集场景里的着色器组合

struct CorpusFiles {
    let package: ScenePackage
    let assets: URL

    func text(_ path: String) -> String? {
        let data = package.contents(of: path) ?? (try? Data(contentsOf: assets.appendingPathComponent(path)))
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    func json(_ path: String) -> [String: Any]? {
        text(path).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}

struct CorpusProgram {
    let shader: String
    /// 材质和场景显式设置的开关
    let combos: [String: Int]
    /// 有贴图的槽（材质或场景给了非空贴图）
    let providedTextures: Set<Int>
    let files: CorpusFiles
    let source: String
    var useCount = 1

    var key: String {
        shader + "|" + combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            + "|" + providedTextures.sorted().map(String.init).joined(separator: ",")
    }

    var label: String {
        let combosText = combos.isEmpty ? "" : " " + combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(shader)\(combosText)（\(source)）"
    }
}

func collectPrograms(files: CorpusFiles) -> [CorpusProgram] {
    guard let scene = files.json("scene.json") else { return [] }
    var programs: [CorpusProgram] = []

    func combos(_ value: Any?) -> [String: Int] {
        (value as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
    }
    func textures(_ value: Any?) -> Set<Int> {
        Set((value as? [Any] ?? []).enumerated().compactMap { index, name in
            (name as? String).map { _ in index }
        })
    }
    func add(materialPath: String, overrides: [String: Any]?, source: String) {
        guard let material = files.json(materialPath),
              let pass = (material["passes"] as? [[String: Any]])?.first,
              let shader = pass["shader"] as? String
        else { return }
        let merged = combos(pass["combos"]).merging(combos(overrides?["combos"])) { $1 }
        let provided = textures(pass["textures"]).union(textures(overrides?["textures"]))
        programs.append(CorpusProgram(shader: shader, combos: merged, providedTextures: provided, files: files, source: source))
    }

    for object in scene["objects"] as? [[String: Any]] ?? [] {
        if let modelPath = object["image"] as? String, let model = files.json(modelPath),
           let materialPath = model["material"] as? String {
            add(materialPath: materialPath, overrides: nil, source: modelPath)
        }
        for effect in object["effects"] as? [[String: Any]] ?? [] {
            guard let effectPath = effect["file"] as? String, let definition = files.json(effectPath) else { continue }
            let overrides = effect["passes"] as? [[String: Any]] ?? []
            for (index, pass) in (definition["passes"] as? [[String: Any]] ?? []).enumerated() {
                guard let materialPath = pass["material"] as? String else { continue }
                add(materialPath: materialPath, overrides: index < overrides.count ? overrides[index] : nil, source: effectPath)
            }
        }
    }
    return programs
}

// MARK: - 流水线

struct CorpusFailure: Error {
    let stage: String
    let summary: String
}

func translate(_ program: CorpusProgram, device: any MTLDevice, directory: URL) -> Result<Void, CorpusFailure> {
    guard let vertexSource = program.files.text("shaders/\(program.shader).vert"),
          let fragmentSource = program.files.text("shaders/\(program.shader).frag")
    else { return .failure(CorpusFailure(stage: "读取", summary: "找不到着色器文件")) }

    let translated: TranslatedProgram
    do {
        translated = try ProgramTranslator.translate(
            vertex: vertexSource, fragment: fragmentSource, combos: program.combos,
            providedTextures: program.providedTextures, include: program.files.text)
    } catch let error as ShaderCompiler.CompileError {
        return .failure(CorpusFailure(stage: error.step, summary: firstError(error.log)))
    } catch {
        return .failure(CorpusFailure(stage: "拼装", summary: error.localizedDescription))
    }
    try? translated.vertexMetal.write(to: directory.appendingPathComponent("vert.metal"), atomically: true, encoding: .utf8)
    try? translated.fragmentMetal.write(to: directory.appendingPathComponent("frag.metal"), atomically: true, encoding: .utf8)

    do {
        let vertex = try device.makeLibrary(source: translated.vertexMetal, options: nil).makeFunction(name: "main0")
        let fragment = try device.makeLibrary(source: translated.fragmentMetal, options: nil).makeFunction(name: "main0")
        guard let vertex, let fragment else { return .failure(CorpusFailure(stage: "Metal 编译", summary: "找不到入口函数")) }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let vertexDescriptor = MTLVertexDescriptor()
        var offset = 0
        for attribute in vertex.vertexAttributes ?? [] where attribute.isActive {
            let (format, size) = vertexFormat(attribute.attributeType)
            vertexDescriptor.attributes[attribute.attributeIndex].format = format
            vertexDescriptor.attributes[attribute.attributeIndex].offset = offset
            vertexDescriptor.attributes[attribute.attributeIndex].bufferIndex = 30
            offset += size
        }
        vertexDescriptor.layouts[30].stride = max(offset, 4)
        descriptor.vertexDescriptor = vertexDescriptor
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
        return .success(())
    } catch {
        return .failure(CorpusFailure(stage: "Metal 编译或连接", summary: firstError("\(error)")))
    }
}

private func vertexFormat(_ type: MTLDataType) -> (MTLVertexFormat, Int) {
    switch type {
    case .float: return (.float, 4)
    case .float2: return (.float2, 8)
    case .float3: return (.float3, 12)
    case .float4: return (.float4, 16)
    case .int: return (.int, 4)
    case .int4: return (.int4, 16)
    case .uint4: return (.uint4, 16)
    default: return (.float4, 16)
    }
}

/// 从编译器输出里取第一条错误，去掉文件路径和行号，便于归类
private func firstError(_ output: String) -> String {
    let lines = output.split(separator: "\n").map(String.init)
    let line = lines.first { $0.localizedCaseInsensitiveContains("error") } ?? lines.first ?? "未知错误"
    var text = line
    if let range = text.range(of: "ERROR: ") { text = String(text[range.upperBound...]) }
    if let range = text.range(of: "error: ") { text = String(text[range.upperBound...]) }
    text = text.replacingOccurrences(of: #"^[^:]*:\d+: "#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"^\d+:\d+: "#, with: "", options: .regularExpression)
    return String(text.prefix(120))
}
