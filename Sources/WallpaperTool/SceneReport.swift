import Foundation
import Metal
import SceneRenderer
import WallpaperFormats
import WallpaperLibrary

/// 全部场景构建一遍（不出图），汇总渲染器报告的"暂不支持"和问题，按出现的场景数排：看还有哪些特效、
/// 功能没做或者做错了。
///
///     WallpaperTool scene-report <目录> <WE 自带素材目录>
func sceneReport(in directory: String, assets: URL) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else { return 1 }
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var unsupported: [String: Set<String>] = [:]
    var problems: [String: Set<String>] = [:]
    var failures: [String] = []
    var count = 0
    for folder in folders {
        let id = folder.lastPathComponent
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene else { continue }
        count += 1
        do {
            let renderer = try SceneRenderer(
                device: device, package: try ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg")),
                assets: assets, targetSize: SIMD2(1512, 982), userProperties: project.propertyValuesJSON(overrides: [:]))
            for key in renderer.unsupported.keys { unsupported[key, default: []].insert(id) }
            for problem in renderer.problems {
                // 同一类问题合在一起：去掉具体的名字、数字
                let kind = problem.replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
                problems[String(kind.prefix(140)), default: []].insert(id)
            }
        } catch {
            failures.append("\(id)：\(error.localizedDescription)")
        }
    }
    print("构建了 \(count) 个场景，失败 \(failures.count) 个")
    failures.forEach { print("  ✗ \($0)") }
    print("\n暂不支持（按场景数）：")
    for (key, ids) in unsupported.sorted(by: { $0.value.count > $1.value.count }) {
        print("  \(ids.count)  \(key)  例：\(ids.sorted().prefix(4).joined(separator: " "))")
    }
    print("\n问题（按场景数）：")
    for (key, ids) in problems.sorted(by: { $0.value.count > $1.value.count }) {
        print("  \(ids.count)  \(key)  例：\(ids.sorted().prefix(4).joined(separator: " "))")
    }
    return 0
}
