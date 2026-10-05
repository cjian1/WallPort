import Foundation
import WallpaperFormats

/// 贴图的统计量（不导出像素）：每个通道的均值、标准差、相邻像素相关系数（白噪声接近 0、平滑噪声接近 1）、
/// 左右接缝和图中间的差（看能不能无缝平铺）。给兼容素材定程序生成的参数用
///
///   WallpaperTool tex-stats <纹理.tex>...
func texStats(_ paths: [String]) -> Int32 {
    for path in paths {
        guard let data = FileManager.default.contents(atPath: path), let tex = try? TexFile(data: data),
              let mip = tex.images.first?.mipmaps.first, let bytes = try? mip.decompressedData(),
              let format = tex.pixelFormat, [.rgba8888, .rg88, .r8].contains(format)
        else {
            print("\((path as NSString).lastPathComponent)：不是不压缩的原始像素，跳过")
            continue
        }
        let channels = format == .r8 ? 1 : format == .rg88 ? 2 : 4
        let (w, h) = (mip.width, mip.height)
        var line = "\((path as NSString).lastPathComponent) \(w)×\(h) \(channels) 通道："
        for c in 0..<channels {
            var sum = 0.0, sq = 0.0, corr = 0.0, seam = 0.0, middle = 0.0
            for y in 0..<h {
                for x in 0..<w {
                    let v = Double(bytes[(y * w + x) * channels + c]) / 255
                    let right = Double(bytes[(y * w + (x + 1) % w) * channels + c]) / 255
                    sum += v; sq += v * v; corr += v * right
                    if x == w - 1 { seam += abs(v - right) } else if x == w / 2 { middle += abs(v - right) }
                }
            }
            let n = Double(w * h), mean = sum / n, variance = max(sq / n - mean * mean, 0)
            line += String(format: " [均值 %.3f 标准差 %.3f 相邻相关 %.2f 接缝/中间 %.2f]",
                           mean, variance.squareRoot(), variance > 1e-9 ? (corr / n - mean * mean) / variance : 1,
                           middle > 0 ? seam / middle : 0)
        }
        print(line)
    }
    return 0
}
