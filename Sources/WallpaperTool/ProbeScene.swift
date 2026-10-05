import CoreGraphics
import Foundation
import ImageIO
import Metal
import SceneRenderer
import UniformTypeIdentifiers
import WallpaperFormats

/// 自己造的场景的对照：把文件夹里的文件（scene.json、模型、材质、贴图……）打成包，分别用 WE 原版和兼容素材渲染，
/// 存两张图，打印差异和指定像素的值。用来量泛光这类整帧处理的公式（只看输出）。
///
///   WallpaperTool probe-scene <WE 自带素材目录> <场景文件夹> <输出目录> [秒数] [x,y …]
func probeScene(assets: String, folder: String, output: String, time: Float, points: [(Int, Int)]) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else { return 1 }
    let root = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
    var files: [String: Data] = [:]
    if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let name = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            files[name] = try? Data(contentsOf: url)
        }
    }
    let outputURL = URL(fileURLWithPath: output, isDirectory: true)
    try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    defer { SceneRenderer.compatAssetMode = .fallback }
    var images: [(name: String, data: Data, width: Int, row: Int)] = []
    for (name, mode) in [("we", CompatAssetMode.off), ("compat", CompatAssetMode.preferCode)] {
        SceneRenderer.compatAssetMode = mode
        do {
            let renderer = try SceneRenderer(
                device: device, package: try ScenePackage(data: packFiles(files)),
                assets: URL(fileURLWithPath: assets, isDirectory: true))
            renderer.problems.forEach { print("✗ \(name)：\($0)") }
            let size = renderer.canvasSize
            let image = try renderer.renderImage(width: Int(size.x), height: Int(size.y), time: time)
            images.append((name, (image.dataProvider?.data as Data?) ?? Data(), image.width, image.bytesPerRow))
            if let destination = CGImageDestinationCreateWithURL(
                outputURL.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        } catch {
            print("✗ \(name)：\(error.localizedDescription)")
            return 1
        }
    }
    let (we, compat) = (images[0].data, images[1].data)
    var changed = 0, maxDiff = 0
    for index in stride(from: 0, to: min(we.count, compat.count) - 3, by: 4) {
        let diff = (0..<3).map { abs(Int(we[index + $0]) - Int(compat[index + $0])) }.max() ?? 0
        if diff > 0 { changed += 1 }
        maxDiff = max(maxDiff, diff)
    }
    print("不同的像素 \(changed)，最大差 \(maxDiff)")
    for (x, y) in points {
        let values = images.map { image -> String in
            let i = y * image.row + x * 4
            guard i + 3 < image.data.count else { return "?" }
            return "\(image.name) \(image.data[i + 2]),\(image.data[i + 1]),\(image.data[i])"
        }
        print("  (\(x),\(y))：" + values.joined(separator: "  "))
    }
    return changed == 0 ? 0 : 1
}
