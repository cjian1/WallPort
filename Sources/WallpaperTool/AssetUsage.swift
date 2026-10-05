import Foundation
import Metal
import SceneRenderer
import WallpaperFormats
import WallpaperLibrary

/// 场景实际从 WE 自带素材里读了哪些文件：逐个构建、渲染（第 0、3 秒），记下从素材目录读到的每个文件。
/// 比 `scan` 的静态追踪全：着色器注释里的默认贴图、特效文件夹里的文件、脚本建的图层都算在内。
/// 用来估计"自己写一套替代素材"要写哪些、先写哪些。只打印编号和数量，不打印标题。
///
///   WallpaperTool asset-usage <目录> <WE 自带素材目录> [输出.json]
///   输出 JSON：每个场景用到的素材文件（含壁纸编号，放在仓库外面）
func assetUsage(in directory: String, assets: URL, output: String?) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let collected = Collector()
    SceneRenderer.assetReadObserver = { collected.insert($0) }
    defer { SceneRenderer.assetReadObserver = nil }
    var usage: [String: [String]] = [:]
    var failed = 0
    for folder in folders {
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene,
              let package = try? ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))
        else { continue }
        collected.reset()
        do {
            let renderer = try SceneRenderer(
                device: device, package: package, assets: assets, targetSize: SIMD2(1920, 1080),
                userProperties: project.propertyValuesJSON(overrides: [:]))
            for time: Float in [0, 3] { _ = try renderer.renderImage(width: 480, height: 270, time: time) }
        } catch {
            failed += 1
        }
        usage[folder.lastPathComponent] = collected.paths.sorted()
    }
    if let output {
        let data = try? JSONSerialization.data(withJSONObject: usage, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: URL(fileURLWithPath: output))
    }
    printAssetSummary(usage, assets: assets, failed: failed)
    return 0
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<String> = []
    func insert(_ path: String) { lock.withLock { _ = set.insert(path) } }
    func reset() { lock.withLock { set = [] } }
    var paths: Set<String> { lock.withLock { set } }
}

/// 素材文件归到"要写的一样东西"：一个特效、一个着色器、一张贴图、一个字体……
func assetUnit(_ path: String) -> String {
    let parts = path.split(separator: "/").map(String.init)
    let name = (parts.last ?? path) as NSString
    switch parts.first {
    case "effects" where parts.count > 1: return "特效 \(parts[1])"
    case "shaders":
        if name.pathExtension == "h" { return "着色器头文件 \(name)" }
        return "着色器 \(parts.dropFirst().joined(separator: "/").replacingOccurrences(of: ".\(name.pathExtension)", with: ""))"
    case "materials":
        if name.pathExtension == "tex" { return "贴图 \(parts.dropFirst().joined(separator: "/"))" }
        return "材质 \(parts.dropFirst().joined(separator: "/"))"
    case "fonts": return "字体 \(name)"
    case "particles", "presets": return "粒子 \(parts.dropFirst().joined(separator: "/"))"
    case "models": return "模型 \(name)"
    case "scripts": return "脚本 \(name)"
    default: return "其它 \(path)"
    }
}

private func printAssetSummary(_ usage: [String: [String]], assets: URL, failed: Int) {
    let scenes = usage.count
    let none = usage.values.filter(\.isEmpty).count
    print("场景 \(scenes) 个（构建或渲染出错 \(failed) 个）；完全不用自带素材的 \(none) 个")

    // 每样东西被多少个场景用到
    var unitScenes: [String: Set<String>] = [:]
    var unitFiles: [String: Set<String>] = [:]
    for (scene, paths) in usage {
        for path in paths {
            let unit = assetUnit(path)
            unitScenes[unit, default: []].insert(scene)
            unitFiles[unit, default: []].insert(path)
        }
    }
    let bytes = { (unit: String) -> Int in
        unitFiles[unit, default: []].reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: assets.appendingPathComponent(path).path)[.size] as? Int) ?? 0)
        }
    }
    var kinds: [String: (units: Int, files: Int)] = [:]
    for (unit, files) in unitFiles {
        let kind = String(unit.split(separator: " ").first ?? "")
        kinds[kind, default: (0, 0)].units += 1
        kinds[kind, default: (0, 0)].files += files.count
    }
    print("用到的自带素材：\(unitFiles.count) 样、\(unitFiles.values.map(\.count).reduce(0, +)) 个文件")
    for (kind, count) in kinds.sorted(by: { $0.value.units > $1.value.units }) {
        print("  \(kind) \(count.units) 样（\(count.files) 个文件）")
    }

    let ranked = unitScenes.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
    print("\n按用到的场景数排（前 60）：")
    for (unit, users) in ranked.prefix(60) {
        print(String(format: "  %4d  %@  （%d 个文件，%.0f KB）", users.count, unit, unitFiles[unit]?.count ?? 0,
                     Double(bytes(unit)) / 1024))
    }

    // 按这个顺序一样一样写，写完前 N 样时有多少场景用到的全都有了
    let needs = usage.mapValues { Set($0.map(assetUnit)) }
    var done: Set<String> = []
    var lastCovered = -1
    print("\n按上面的顺序写，写完前 N 样时不缺自带素材的场景数：")
    for (index, (unit, _)) in ranked.enumerated() {
        done.insert(unit)
        let covered = needs.values.filter { $0.isSubset(of: done) }.count
        let n = index + 1
        if [5, 10, 20, 30, 40, 60, 80, 100, 150].contains(n) || n == ranked.count {
            if covered != lastCovered || n == ranked.count {
                print("  前 \(n) 样：\(covered)/\(scenes)（\(Int((Double(covered) / Double(max(scenes, 1)) * 100).rounded()))%）")
                lastCovered = covered
            }
        }
    }
}
