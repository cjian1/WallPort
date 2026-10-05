import CoreGraphics
import DesktopHost
import Foundation
import ImageIO
import Metal
import SceneRenderer
import UniformTypeIdentifiers
import WallpaperFormats
import WallpaperLibrary

// 回归基准：把每个场景按屏幕尺寸在第 0 秒和第 5 秒各渲染一张，存进基准目录；
// 以后每次回归都和基准逐像素比较，只列出真正变了的场景。
//
// 为什么不看"和预览图的差异"：那张图是 WE 编辑器出的缩略图，取景（裁切、缩放、动图取哪一帧）
// 和实际渲染不一定一致，动图还只读第一帧——这几次排查里它就误导过。基准比较只回答一个问题：
// 这次改动有没有改变任何一个场景的画面，不依赖 WE 的参照图。
//
// 注意：画面里带实时时钟的场景（读系统时间的文字脚本）每次都会算成"变了"，这是预期的。
func regressScenes(in directory: String, assets: URL, baseline: String) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    let baselineRoot = URL(fileURLWithPath: baseline, isDirectory: true)
    try? FileManager.default.createDirectory(at: baselineRoot, withIntermediateDirectories: true)
    // REGRESS_UPDATE=1：把这次的结果写成新基准（用来接受一次有意的画面变化）
    let update = ProcessInfo.processInfo.environment["REGRESS_UPDATE"] != nil
    let width = Int(ProcessInfo.processInfo.environment["TARGET_WIDTH"].flatMap(Float.init) ?? 1920)
    let height = Int(ProcessInfo.processInfo.environment["TARGET_HEIGHT"].flatMap(Float.init) ?? 1080)
    let times: [Float] = [0, 5]
    let signature = "\(width)x\(height)"

    let signatureFile = baselineRoot.appendingPathComponent("size.txt")
    if let stored = try? String(contentsOf: signatureFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), stored != signature, !update {
        // 尺寸不同就别比了，也别动基准：接着比的话每张都算"变了"，还会把尺寸记录改掉、让基准作废
        print("✗ 基准是按 \(stored) 存的，这次是 \(signature)：尺寸不同，比较没有意义。"
            + "用同样的 TARGET_WIDTH/TARGET_HEIGHT，或者 REGRESS_UPDATE=1 按新尺寸重建基准")
        return 1
    }
    try? signature.write(to: signatureFile, atomically: true, encoding: .utf8)

    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var created = 0
    var compared = 0
    var failures = 0
    var changed: [(name: String, mean: Double, percent: Double)] = []

    for folder in folders {
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene else { continue }
        let id = folder.lastPathComponent
        do {
            let package = try ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))
            // 和桌面上一样：按屏幕尺寸建渲染器、按同一尺寸出图（建和画的尺寸不一致时，取景和特效缓冲
            // 都和实际显示不一样，比出来的差异不代表桌面上看到的）
            let renderer = try SceneRenderer(
                device: device, package: package, assets: assets,
                targetSize: SIMD2(Float(width), Float(height)),
                userProperties: project.propertyValuesJSON(overrides: [:]))
            if ProcessInfo.processInfo.environment["SYSTEM_AUDIO"] != nil,
               SystemAudioSpectrum.shared.start() {
                renderer.audioSpectrum = SystemAudioSpectrum.shared
            }
            for time in times {
                let image = try renderer.renderImage(width: width, height: height, time: time)
                let file = baselineRoot.appendingPathComponent("\(id)-t\(Int(time)).png")
                if update || !FileManager.default.fileExists(atPath: file.path) {
                    try writePNG(image, to: file)
                    created += 1
                    continue
                }
                guard let previous = loadImage(file) else {
                    print("⚠️ \(id)-t\(Int(time)).png 读不出来，重新存")
                    try writePNG(image, to: file)
                    created += 1
                    continue
                }
                compared += 1
                let (mean, percent) = imageDifference(image, previous)
                // 阈值：平均差 0.5 或 0.1% 的像素明显变了，都算这个场景变了
                if mean > 0.5 || percent > 0.1 {
                    changed.append((name: "\(id)-t\(Int(time))", mean: mean, percent: percent))
                }
            }
        } catch {
            failures += 1
            print("✗ \(id)：\(error.localizedDescription)")
        }
    }

    let phase = update ? "已更新" : (compared == 0 ? "已建立" : "已比对")
    print("\n基准\(phase)：新存 \(created) 张，比较 \(compared) 张，失败 \(failures) 个场景")
    if !changed.isEmpty {
        print("画面变了的场景（\(changed.count) 张）：")
        for item in changed.sorted(by: { $0.mean > $1.mean }) {
            print(String(format: "  %-24@ 平均差 %.2f，变化像素 %.2f%%", item.name as NSString, item.mean, item.percent))
        }
    } else if compared > 0 {
        print("所有场景都和基准一致。")
    }
    if created > 0, !update {
        print("（基准目录里还没有的场景已按当前画面写入，下次再比）")
    }
    print("基准目录：\(baselineRoot.path)（含壁纸作者的内容，不要放进仓库）")
    return failures == 0 && changed.isEmpty ? 0 : 1
}

/// 两张同尺寸图的差异：RGB 的平均绝对差（0–255），以及明显变化的像素比例（%）
func imageDifference(_ first: CGImage, _ second: CGImage) -> (mean: Double, changedPercent: Double) {
    guard first.width == second.width, first.height == second.height else { return (.infinity, 100) }
    let a = pixels(first), b = pixels(second)
    var total = 0
    var changed = 0
    for index in stride(from: 0, to: a.count, by: 4) {
        let difference = abs(Int(a[index]) - Int(b[index])) + abs(Int(a[index + 1]) - Int(b[index + 1]))
            + abs(Int(a[index + 2]) - Int(b[index + 2]))
        total += difference
        if difference > 12 { changed += 1 }
    }
    let count = a.count / 4
    return (Double(total) / Double(count * 3), 100 * Double(changed) / Double(count))
}

private func pixels(_ image: CGImage) -> [UInt8] {
    var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
        data: &values, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return values }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return values
}

private func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
