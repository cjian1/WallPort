import CoreGraphics
import Foundation
import Metal
import SceneRenderer
import WallpaperFormats
import WallpaperLibrary

/// 取景自检：同一个场景按屏幕尺寸渲染一张，再按画布比例、同样的缩放渲染一张，取后者中间和屏幕一样大的一块比较。
/// 取景、特效缓冲、屏幕坐标（复制背景、折射、X-ray 读的别的图层）都对的话两张应该一样；
/// 差得多的场景就是"屏幕比例和画布不同时画面不对"（只显示一角、错位）的候选——不用看图就能筛。
///
///     WallpaperTool framing-check <目录> <WE 自带素材目录> [宽 高] [场景编号…]   # 默认 1512×982
func framingCheck(in directory: String, assets: URL, width: Int, height: Int, only: Set<String>) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else { return 1 }
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var results: [(id: String, mean: Double, percent: Double)] = []
    for folder in folders {
        let id = folder.lastPathComponent
        guard only.isEmpty || only.contains(id),
              let project = try? WallpaperProject(folder: folder), project.kind == .scene else { continue }
        do {
            let package = try ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))
            let properties = project.propertyValuesJSON(overrides: [:])
            let screen = try SceneRenderer(
                device: device, package: package, assets: assets, targetSize: SIMD2(Float(width), Float(height)),
                userProperties: properties)
            let screenImage = try screen.renderImage(width: width, height: height, time: 2)
            // 画布比例、缩放和屏幕那张相同的一张（画布比屏幕宽就按屏幕高，否则按屏幕宽）
            let aspect = screen.canvasSize.x / max(screen.canvasSize.y, 1)
            let wide = aspect >= Float(width) / Float(height)
            let fullWidth = wide ? Int((Float(height) * aspect).rounded()) : width
            let fullHeight = wide ? height : Int((Float(width) / aspect).rounded())
            guard fullWidth <= 16384, fullHeight <= 16384 else { continue }
            let full = try SceneRenderer(
                device: device, package: package, assets: assets,
                targetSize: SIMD2(Float(fullWidth), Float(fullHeight)), userProperties: properties)
            let fullImage = try full.renderImage(width: fullWidth, height: fullHeight, time: 2)
            let crop = CGRect(
                x: (fullWidth - width) / 2, y: (fullHeight - height) / 2, width: width, height: height)
            guard let middle = fullImage.cropping(to: crop) else { continue }
            let (mean, percent) = imageDifference(screenImage, middle)
            // FRAMING_SAVE=<目录>：两张都存下来对着看
            if let save = ProcessInfo.processInfo.environment["FRAMING_SAVE"] {
                let dir = URL(fileURLWithPath: save, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? writePNG(screenImage, to: dir.appendingPathComponent("\(id)-screen.png"))
                try? writePNG(middle, to: dir.appendingPathComponent("\(id)-canvas.png"))
            }
            results.append((id, mean, percent))
            if mean > 3 || percent > 5 {
                print(String(format: "  %@ 平均差 %.2f，变化像素 %.1f%%（画布 %.0f×%.0f%@）", id, mean, percent,
                             screen.canvasSize.x, screen.canvasSize.y, screen.fillBox == nil ? "" : "，有空边取景"))
            }
        } catch {
            print("✗ \(id)：\(error.localizedDescription)")
        }
    }
    let bad = results.filter { $0.mean > 3 || $0.percent > 5 }
    print("\n比较了 \(results.count) 个场景，差得多的 \(bad.count) 个（平均差 > 3 或变化像素 > 5%）")
    return bad.isEmpty ? 0 : 1
}
