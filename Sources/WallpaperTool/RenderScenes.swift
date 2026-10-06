import CoreGraphics
import Foundation
import ImageIO
import Metal
import DesktopHost
import SceneRenderer
import UniformTypeIdentifiers
import WallpaperFormats
import WallpaperLibrary

/// 离屏渲染目录下的全部场景项目，存成 PNG，并和项目自带的 preview.jpg（WE 自己渲染的缩略图）比较。
///
/// 相似度用"平均绝对差"：两张图都缩到 32×32，逐像素比较 RGB，0 表示一模一样，数值越小越像。
/// 同时把渲染结果上下翻转再比一次：翻转后反而更像，说明坐标方向弄反了。
/// 预览图通常是正方形，这里按"铺满裁切"渲染同样尺寸来比，取第 5 秒的画面（入场动画已经结束）。
func renderScenes(in directory: String, assets: URL, output: String) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    let outputRoot = URL(fileURLWithPath: output, isDirectory: true)
    try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var unsupportedTotals: [String: Int] = [:]
    var effectTotal = 0
    var animated = 0
    var rendered = 0
    var closer = 0
    var failures = 0
    for folder in folders {
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene else { continue }
        let id = folder.lastPathComponent
        do {
            let started = Date()
            let package = try ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))
            // 按 1920 宽的屏幕构建，和桌面上的用法一致（特效缓冲尺寸、特效投影矩阵都按屏幕算）
            let probe = try SceneDescription(json: package.contents(of: "scene.json") ?? Data())
            let aspect = probe.canvasSize.map { $0.y / $0.x } ?? 9.0 / 16.0
            // 和桌面上一样代入用户属性的默认值（NO_USER_PROPERTIES 时用场景文件里保存的值，用来对比）
            let properties = ProcessInfo.processInfo.environment["NO_USER_PROPERTIES"] == nil
                ? project.propertyValuesJSON(overrides: [:]) : nil
            let renderer = try SceneRenderer(
                device: device, package: package, assets: assets, targetSize: SIMD2(1920, (1920 * aspect).rounded()),
                userProperties: properties)
            // 默认不采集系统音频：回归比较的结果不该随正在放的音乐变。SYSTEM_AUDIO=1 时接上
            if ProcessInfo.processInfo.environment["SYSTEM_AUDIO"] != nil, SystemAudioSpectrum.shared.start() {
                renderer.audioSpectrum = SystemAudioSpectrum.shared
            }
            let buildTime = Date().timeIntervalSince(started)

            // 按画布比例存一张 1920 宽的完整渲染，方便查看
            let width = 1920
            let height = Int((Float(width) * renderer.canvasSize.y / renderer.canvasSize.x).rounded())
            try writePNG(renderer.renderImage(width: width, height: height), to: outputRoot.appendingPathComponent("\(id).png"))

            var comparison = "没有可比较的预览图"
            if let preview = project.preview.flatMap(loadImage) {
                // 按第 5 秒比较：有入场动画的场景（例如 Lucy 从右下角滑进来）开头几秒和预览图不一样
                let render = try renderer.renderImage(width: preview.width, height: preview.height, time: 5)
                // SAVE_PREVIEW_RENDER=1：把拿去和预览图比较的那一张也存下来（按预览图尺寸、第 5 秒）
                if ProcessInfo.processInfo.environment["SAVE_PREVIEW_RENDER"] != nil {
                    try writePNG(render, to: outputRoot.appendingPathComponent("\(id)-preview.png"))
                }
                let direct = meanDifference(render, preview, flipFirst: false)
                let flipped = meanDifference(render, preview, flipFirst: true)
                if direct < flipped { closer += 1 }
                comparison = String(format: "与预览图的差异 %.1f（上下翻转后 %.1f）", direct, flipped)
            }
            // 有特效时比较第 0 秒和第 1.5 秒两帧：特效在工作的话画面应该有变化
            var motion = ""
            if renderer.needsAnimation {
                let first = try renderer.renderImage(width: 640, height: 360, time: 0)
                let later = try renderer.renderImage(width: 640, height: 360, time: 1.5)
                let difference = meanDifference(first, later, flipFirst: false, size: 128)
                if difference > 0.05 { animated += 1 }
                let particlesAtLater = renderer.liveParticleCount
                let left = try renderer.renderImage(width: 640, height: 360, time: 1.5, pointer: SIMD2(0.2, 0.5))
                let right = try renderer.renderImage(width: 640, height: 360, time: 1.5, pointer: SIMD2(0.8, 0.5))
                let pointerDifference = meanDifference(left, right, flipFirst: false, size: 128)
                motion = String(format: "；特效 %d 个，粒子系统 %d 个（1.5 秒时 %d 个粒子），0 秒与 1.5 秒两帧差异 %.2f，鼠标左右两处差异 %.2f",
                                renderer.renderedEffectCount, renderer.particleSystemCount, particlesAtLater,
                                difference, pointerDifference)
                try writePNG(later, to: outputRoot.appendingPathComponent("\(id)-t1.5.png"))
            }
            effectTotal += renderer.renderedEffectCount
            rendered += 1
            renderer.unsupported.forEach { unsupportedTotals[$0.key, default: 0] += $0.value }
            let skipped = renderer.unsupported.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
            print("\(id) 画了 \(renderer.drawnLayerCount) 层，用时 \(String(format: "%.2f", buildTime)) 秒；\(comparison)\(motion)")
            if !skipped.isEmpty { print("    暂不支持：\(skipped.joined(separator: "、"))") }
            renderer.problems.forEach { print("    ✗ \($0)") }
            if ProcessInfo.processInfo.environment["SHOW_EFFECTS"] != nil {
                renderer.effectSummaries.forEach { print("    · \($0)") }
            }
        } catch {
            failures += 1
            print("✗ \(id)：\(error.localizedDescription)")
        }
    }

    print("\n渲染成功 \(rendered) 个，失败 \(failures) 个；与预览图比较时，不翻转更接近的有 \(closer) 个")
    print("渲染的特效共 \(effectTotal) 个；带特效的场景里，画面随时间变化的有 \(animated) 个")
    print("全部场景里暂不支持的内容：")
    for (name, count) in unsupportedTotals.sorted(by: { $0.value > $1.value }) {
        print("  \(String(format: "%3d", count))  \(name)")
    }
    print("渲染结果在 \(outputRoot.path)（含壁纸作者的内容，不要放进仓库）")
    return failures == 0 ? 0 : 1
}

private func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw FormatError("无法写入 \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FormatError("无法写入 \(url.path)") }
}

/// 两张图缩到 32×32 后逐像素比较 RGB 的平均绝对差（0–255）
func meanDifference(_ first: CGImage, _ second: CGImage, flipFirst: Bool, size: Int = 32) -> Double {
    let a = thumbnail(first, flip: flipFirst, size: size)
    let b = thumbnail(second, flip: false, size: size)
    var total = 0
    for index in stride(from: 0, to: a.count, by: 4) {
        for channel in 0..<3 { total += abs(Int(a[index + channel]) - Int(b[index + channel])) }
    }
    return Double(total) / Double(a.count / 4 * 3)
}

private func thumbnail(_ image: CGImage, flip: Bool, size: Int = 32) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    let context = CGContext(
        data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    if flip {
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
    }
    // 按铺满裁切缩放，和渲染时的对齐方式一致
    let scale = max(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
    let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    context.draw(image, in: CGRect(
        x: (CGFloat(size) - drawn.width) / 2, y: (CGFloat(size) - drawn.height) / 2,
        width: drawn.width, height: drawn.height))
    return pixels
}
