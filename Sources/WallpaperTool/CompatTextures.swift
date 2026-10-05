import CoreGraphics
import Foundation
import ImageIO
import SceneRenderer
import UniformTypeIdentifiers
import WallpaperFormats

/// 把兼容素材里程序生成的贴图导出成 PNG（铺在棋盘格上，看得出透明度），顺便核对能不能读回、量生成用时。
///
///   WallpaperTool compat-textures <输出目录>
func exportCompatTextures(to output: String) -> Int32 {
    let folder = URL(fileURLWithPath: output, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var failures = 0
    for path in CompatAssets.allPaths.filter({ $0.hasSuffix(".tex") }).sorted() {
        let started = Date()
        guard let data = CompatAssets.contents(path), let tex = try? TexFile(data: data),
              let mip = tex.images.first?.mipmaps.first, let bytes = try? mip.decompressedData(), let format = tex.pixelFormat
        else {
            print("✗ \(path) 读不回来")
            failures += 1
            continue
        }
        let seconds = Date().timeIntervalSince(started)
        let channels = format == .r8 ? 1 : format == .rg88 ? 2 : 4
        let (w, h) = (mip.width, mip.height)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * channels
                let color: (Float, Float, Float, Float) = switch format {
                case .r8: (1, 1, 1, Float(bytes[i]) / 255)
                case .rg88: (Float(bytes[i]) / 255, Float(bytes[i]) / 255, Float(bytes[i]) / 255, Float(bytes[i + 1]) / 255)
                default: (Float(bytes[i]) / 255, Float(bytes[i + 1]) / 255, Float(bytes[i + 2]) / 255, Float(bytes[i + 3]) / 255)
                }
                // 棋盘格底：看得出透明的地方
                let checker: Float = (x / 8 + y / 8) % 2 == 0 ? 0.25 : 0.4
                let o = (y * w + x) * 4
                rgba[o] = UInt8((color.0 * color.3 + checker * (1 - color.3)) * 255)
                rgba[o + 1] = UInt8((color.1 * color.3 + checker * (1 - color.3)) * 255)
                rgba[o + 2] = UInt8((color.2 * color.3 + checker * (1 - color.3)) * 255)
                rgba[o + 3] = 255
            }
        }
        let name = path.replacingOccurrences(of: "materials/", with: "").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".tex", with: ".png")
        if let context = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(
               folder.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        let frames = tex.spriteSheet.map { " \($0.frames.count) 帧" } ?? ""
        print(String(format: "%@ %d×%d %@%@ mipmap %d 层，生成 %.2f 秒", path, w, h, "\(format)", frames,
                     tex.images[0].mipmaps.count, seconds))
    }
    return failures == 0 ? 0 : 1
}
