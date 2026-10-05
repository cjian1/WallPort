import Foundation
import SceneRenderer
import WallpaperFormats

/// 列出场景包里各个版本的内置特效着色器（去掉注释和空白后的指纹），并把每个版本的源码写到输出目录，
/// 给"特效只在图层内容附近算"（`EffectRegion`）逐个核对用。
///
///   WallpaperTool effect-variants <目录> <WE 自带素材目录> <输出目录> [特效名...]
func listEffectVariants(in directory: String, assets: URL, output: String, names: [String]) -> Int32 {
    let outputRoot = URL(fileURLWithPath: output, isDirectory: true)
    try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let packages = folders.compactMap { folder in
        (try? ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))).map { (folder.lastPathComponent, $0) }
    }
    for name in names {
        func builtIn(_ kind: String) -> String? {
            let path = assets.appendingPathComponent("effects/\(name)/shaders/effects/\(name).\(kind)")
            return try? String(contentsOf: path, encoding: .utf8)
        }
        struct Variant { var count = 0; var example = ""; var frag = ""; var vert = "" }
        var variants: [String: Variant] = [:]
        let reference = [builtIn("frag"), builtIn("vert")].map { $0.map(effectShaderCodeHash) }
        func key(_ frag: String, _ vert: String) -> String {
            String(format: "%016llx-%016llx", effectShaderCodeHash(frag), effectShaderCodeHash(vert))
        }
        for (id, package) in packages {
            guard let frag = package.contents(of: "shaders/effects/\(name).frag").map({ String(decoding: $0, as: UTF8.self) })
                ?? nil else { continue }
            let vert = package.contents(of: "shaders/effects/\(name).vert").map { String(decoding: $0, as: UTF8.self) }
                ?? builtIn("vert") ?? ""
            let k = key(frag, vert)
            variants[k, default: Variant(example: id, frag: frag, vert: vert)].count += 1
        }
        if let frag = builtIn("frag"), let vert = builtIn("vert") {
            let k = key(frag, vert)
            if variants[k] == nil { variants[k] = Variant(count: 0, example: "自带", frag: frag, vert: vert) }
        }
        print("\(name)：自带 \(reference.map { $0.map { String(format: "%016llx", $0) } ?? "-" })")
        for (k, variant) in variants.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(k)  \(variant.count) 个场景，例 \(variant.example)")
            try? variant.frag.write(to: outputRoot.appendingPathComponent("\(name)-\(k).frag"), atomically: true, encoding: .utf8)
            try? variant.vert.write(to: outputRoot.appendingPathComponent("\(name)-\(k).vert"), atomically: true, encoding: .utf8)
        }
    }
    return 0
}
