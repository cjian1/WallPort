import CoreGraphics
import Foundation
import Metal
import SceneRenderer
import WallpaperFormats
import WallpaperLibrary

/// 兼容素材的对照测试：同一个场景先用 WE 自带素材渲染（两遍，两遍就不一样的场景记为"不稳定"跳过），
/// 再换成兼容素材渲染，逐像素比较。只打印编号和数量，不打印标题。
///
///   WallpaperTool compat-check <目录> <WE 自带素材目录> [code|all|none] [场景编号…]
///   code（默认）：着色器、头文件、模型用兼容版，贴图仍用 WE 原版——代码写对了画面应该完全一样
///   all：兼容素材里有的一律用兼容版（贴图是自己做的，画面会不同，看有没有报错、缺不缺东西）
///   none：不给 WE 素材目录，只靠兼容素材（没有 WE 的用户看到的样子）
func compatCheck(in directory: String, assets: URL, mode: String, only: Set<String>) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    let compatMode: CompatAssetMode = switch mode {
    case "all": .preferAll
    case "none": .fallback
    default: .preferCode
    }
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .filter { only.isEmpty || only.contains($0.lastPathComponent) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let compatReads = PathCollector(), assetReads = PathCollector()
    SceneRenderer.compatReadObserver = { compatReads.insert($0) }
    SceneRenderer.assetReadObserver = { assetReads.insert($0) }
    defer {
        SceneRenderer.compatReadObserver = nil
        SceneRenderer.assetReadObserver = nil
        SceneRenderer.compatAssetMode = .fallback
    }

    struct Result {
        let id: String
        let mean: Double
        let changed: Double
        let maxDiff: Int
    }
    var same = 0, unstable = 0, failed = 0, untouched = 0
    var differing: [Result] = []
    var newProblems: [String: Set<String>] = [:]
    var stillFromAssets: [String: Set<String>] = [:]
    var used: [String: Int] = [:]
    let times: [Float] = [0, 3]
    for folder in folders {
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene,
              let package = try? ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))
        else { continue }
        let id = folder.lastPathComponent
        let properties = project.propertyValuesJSON(overrides: [:])
        func render(_ mode: CompatAssetMode, assets: URL?) -> (images: [Data], problems: [String])? {
            SceneRenderer.compatAssetMode = mode
            guard let renderer = try? SceneRenderer(
                device: device, package: package, assets: assets, targetSize: SIMD2(960, 540), userProperties: properties)
            else { return nil }
            let images = times.compactMap { try? renderer.renderImage(width: 960, height: 540, time: $0) }.map(pixels)
            return (images, renderer.problems)
        }
        guard let first = render(.off, assets: assets), let second = render(.off, assets: assets) else {
            failed += 1
            continue
        }
        if first.images != second.images {
            unstable += 1
            continue
        }
        compatReads.reset()
        assetReads.reset()
        guard let compat = render(compatMode, assets: compatMode == .fallback ? nil : assets) else {
            failed += 1
            newProblems["构建失败", default: []].insert(id)
            continue
        }
        let readCompat = compatReads.paths
        if readCompat.isEmpty { untouched += 1 }
        for path in readCompat { used[path, default: 0] += 1 }
        for path in assetReads.paths where compatMode != .preferAll || CompatAssets.isCodePath(path) {
            if compatMode == .preferCode, !CompatAssets.isCodePath(path) { continue }
            stillFromAssets[path, default: []].insert(id)
        }
        for problem in Set(compat.problems).subtracting(first.problems) {
            newProblems[problem.prefix(160).description, default: []].insert(id)
        }
        let diffs = zip(first.images, compat.images).map(compare)
        let worst = diffs.max { $0.mean < $1.mean } ?? (0, 0, 0)
        if worst.maxDiff == 0 {
            same += 1
        } else {
            differing.append(Result(id: id, mean: worst.mean, changed: worst.changed, maxDiff: worst.maxDiff))
        }
    }
    print("场景：一样 \(same) 个（其中没用到兼容素材的 \(untouched) 个）、不一样 \(differing.count) 个、"
        + "不稳定（WE 原版连画两遍就不同）\(unstable) 个、建不起来 \(failed) 个")
    if !differing.isEmpty {
        print("\n不一样的场景（按平均差排）：")
        for result in differing.sorted(by: { $0.mean > $1.mean }) {
            print(String(format: "  %@  平均差 %.3f，变化像素 %.2f%%，最大差 %d", result.id, result.mean, result.changed * 100, result.maxDiff))
        }
    }
    if !newProblems.isEmpty {
        print("\n只在兼容素材下出现的问题：")
        for (problem, ids) in newProblems.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(ids.count) 个场景：\(problem)（例如 \(ids.sorted().prefix(3).joined(separator: "、"))）")
        }
    }
    if !stillFromAssets.isEmpty {
        print("\n兼容素材里还没有、仍从 WE 素材读的：")
        for (path, ids) in stillFromAssets.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(ids.count) 个场景：\(path)")
        }
    }
    if !used.isEmpty {
        print("\n用到的兼容素材：" + used.sorted { $0.value > $1.value }.map { "\($0.key)（\($0.value)）" }.joined(separator: "、"))
    }
    return differing.isEmpty && newProblems.isEmpty ? 0 : 1
}

private final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<String> = []
    func insert(_ path: String) { lock.withLock { _ = set.insert(path) } }
    func reset() { lock.withLock { set = [] } }
    var paths: Set<String> { lock.withLock { set } }
}

private func pixels(_ image: CGImage) -> Data {
    (image.dataProvider?.data as Data?) ?? Data()
}

/// 平均差（0–255）、变化像素比例、最大差
private func compare(_ a: Data, _ b: Data) -> (mean: Double, changed: Double, maxDiff: Int) {
    guard a.count == b.count, !a.isEmpty else { return (255, 1, 255) }
    var total = 0, changedPixels = 0, maxDiff = 0
    a.withUnsafeBytes { pa in
        b.withUnsafeBytes { pb in
            let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
            var index = 0
            while index + 3 < x.count {
                var pixelChanged = false
                for channel in 0..<3 {
                    let diff = abs(Int(x[index + channel]) - Int(y[index + channel]))
                    total += diff
                    if diff > 0 { pixelChanged = true }
                    maxDiff = max(maxDiff, diff)
                }
                if pixelChanged { changedPixels += 1 }
                index += 4
            }
        }
    }
    let count = a.count / 4
    return (Double(total) / Double(count * 3), Double(changedPixels) / Double(count), maxDiff)
}
