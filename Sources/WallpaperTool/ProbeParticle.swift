import CoreGraphics
import Foundation
import ImageIO
import Metal
import SceneRenderer
import UniformTypeIdentifiers
import WallpaperFormats

/// 粒子着色器的对照：自己造一个只有一个粒子的场景（贴图是"红 = u、绿 = v"的坐标图，或者精灵图、R8 / RG88 灰度图），
/// 分别用 WE 原版的 genericparticle 和兼容版渲染，打印差异、把两张图存到输出目录。
///
///   WallpaperTool probe-particle <WE 自带素材目录> <输出目录> '<规格 JSON>'
///   规格：{"size": 40, "rotation": "0 0 0.5", "velocity": "0 0 0", "color": "255 128 64", "alpha": 1,
///          "renderer": "sprite" | "spritetrail", "length": 0.05, "maxlength": 10, "minlength": 0,
///          "texture": "uv" | "r8" | "rg88" | "sheet", "blending": "translucent" | "additive" | "normal",
///          "combos": {}, "constants": {}, "lifetime": 2, "time": 1, "canvas": 128}
func probeParticle(assets: String, output: String, spec: String) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice(),
          let options = (try? JSONSerialization.jsonObject(with: Data(spec.utf8))) as? [String: Any]
    else {
        print("✗ 规格不是 JSON 或没有 Metal 设备")
        return 1
    }
    func value(_ key: String, _ fallback: Any) -> Any { options[key] ?? fallback }
    let canvas = (value("canvas", 128) as? Int) ?? 128
    let lifetime = (value("lifetime", 2) as? Double) ?? 2
    let time = Float((value("time", 1) as? Double) ?? 1)
    let rendererName = (value("renderer", "sprite") as? String) ?? "sprite"
    var renderer: [String: Any] = ["name": rendererName]
    for key in ["length", "maxlength", "minlength"] { if let v = options[key] { renderer[key] = v } }
    var definition: [String: Any] = [
        "material": "materials/probe.json", "maxcount": 1,
        "emitter": [["name": "boxrandom", "rate": 1000, "distancemin": 0, "distancemax": 0,
                     "origin": value("origin", "0 0 0")]],
        "initializer": [
            ["name": "lifetimerandom", "min": lifetime, "max": lifetime],
            ["name": "sizerandom", "min": value("size", 40), "max": value("size", 40)],
            ["name": "rotationrandom", "min": value("rotation", "0 0 0"), "max": value("rotation", "0 0 0")],
            ["name": "colorrandom", "min": value("color", "255 255 255"), "max": value("color", "255 255 255")],
            ["name": "alpharandom", "min": value("alpha", 1), "max": value("alpha", 1)],
            ["name": "velocityrandom", "min": value("velocity", "0 0 0"), "max": value("velocity", "0 0 0")],
        ],
        "renderer": [renderer],
    ]
    if let mode = options["animationmode"] { definition["animationmode"] = mode }
    let texture = (value("texture", "uv") as? String) ?? "uv"
    // "normal": true 时 1 号槽给一张法线图（折射粒子用）；"background": true 时背后铺一张坐标图（看折射取样）
    let normal = (value("normal", false) as? Bool) ?? false
    let backgroundKind = options["background"] as? String
    let background = backgroundKind != nil || ((value("background", false) as? Bool) ?? false)
    let material: [String: Any] = ["passes": [[
        "shader": "genericparticle", "blending": value("blending", "translucent"),
        "textures": [(options["texturename"] as? String) ?? "probe"] + (normal ? ["probenormal"] : []),
        "combos": value("combos", [String: Any]()), "constantshadervalues": value("constants", [String: Any]()),
    ]]]
    let scene = """
        {"general": {"orthogonalprojection": {"width": \(canvas), "height": \(canvas)}, "clearcolor": "0.1 0.1 0.1"},
         "objects": [\(background
            ? #"{"id": 2, "image": "models/bg.json", "origin": "\#(canvas / 2) \#(canvas / 2) 0", "size": "\#(canvas) \#(canvas)"},"#
            : "")
            {"id": \((options["id"] as? Int) ?? 1), "particle": "particles/probe.json", "origin": "\(canvas / 2) \(canvas / 2) 0"}]}
        """
    let files: [String: Data] = [
        "scene.json": Data(scene.utf8),
        "particles/probe.json": (try? JSONSerialization.data(withJSONObject: definition)) ?? Data(),
        "materials/probe.json": (try? JSONSerialization.data(withJSONObject: material)) ?? Data(),
        "materials/probe.tex": probeTexture(texture),
        "materials/probenormal.tex": (options["normalvalue"] as? String).map { constantTexture($0) } ?? probeTexture("normal"),
        "models/bg.json": Data(#"{"material": "materials/bg.json"}"#.utf8),
        "materials/bg.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["bg"]}]}"#.utf8),
        "materials/bg.tex": probeTexture(backgroundKind ?? "grid"),
    ]
    let outputURL = URL(fileURLWithPath: output, isDirectory: true)
    try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    var images: [Data] = []
    defer { SceneRenderer.compatAssetMode = .fallback }
    for (name, mode) in [("we", CompatAssetMode.off), ("compat", CompatAssetMode.preferCode)] {
        SceneRenderer.compatAssetMode = mode
        do {
            let renderer = try SceneRenderer(
                device: device, package: try ScenePackage(data: packFiles(files)),
                assets: URL(fileURLWithPath: assets, isDirectory: true))
            renderer.problems.forEach { print("✗ \(name)：\($0)") }
            let image = try renderer.renderImage(width: canvas, height: canvas, time: time)
            images.append((image.dataProvider?.data as Data?) ?? Data())
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
    // 差异：像素数、最大差，和 WE 版本里不是背景色的范围（看大小、位置对不对）
    let (we, compat) = (images[0], images[1])
    var changed = 0, maxDiff = 0
    var bounds = (minX: canvas, minY: canvas, maxX: -1, maxY: -1)
    for index in stride(from: 0, to: min(we.count, compat.count) - 3, by: 4) {
        let diff = (0..<3).map { abs(Int(we[index + $0]) - Int(compat[index + $0])) }.max() ?? 0
        if diff > 0 { changed += 1 }
        maxDiff = max(maxDiff, diff)
        let background = abs(Int(we[index]) - 26) <= 1 && abs(Int(we[index + 1]) - 26) <= 1 && abs(Int(we[index + 2]) - 26) <= 1
        if !background {
            let pixel = index / 4, x = pixel % canvas, y = pixel / canvas
            bounds = (min(bounds.minX, x), min(bounds.minY, y), max(bounds.maxX, x), max(bounds.maxY, y))
        }
    }
    print("不同的像素 \(changed)，最大差 \(maxDiff)；WE 画出的范围 x \(bounds.minX)…\(bounds.maxX) y \(bounds.minY)…\(bounds.maxY)")
    return changed == 0 ? 0 : 1
}

/// 探针贴图：uv（32×32，红 = u、绿 = v）、r8 / rg88（32×32 径向渐变）、sheet（64×32 的 4×2 精灵图，每帧一种颜色）
private func probeTexture(_ kind: String) -> Data {
    switch kind {
    case "r8", "rg88":
        let channels = kind == "r8" ? 1 : 2
        var pixels = [UInt8]()
        for y in 0..<32 {
            for x in 0..<32 {
                let d = min(1, (Double((x - 16) * (x - 16) + (y - 16) * (y - 16))).squareRoot() / 16)
                pixels.append(UInt8((1 - d) * 255))
                if channels == 2 { pixels.append(UInt8(x * 8)) }
            }
        }
        return texData(width: 32, height: 32, format: kind == "r8" ? 9 : 8, pixels: pixels, sheet: nil)
    case "coord":
        // 红 = 横坐标、绿 = 纵坐标（看折射从哪里取样）
        var pixels = [UInt8]()
        for y in 0..<256 { for x in 0..<256 { pixels += [UInt8(x), UInt8(y), 0, 255] } }
        return texData(width: 256, height: 256, format: 0, pixels: pixels, sheet: nil)
    case "padded":
        // 64×64 的贴图里只有左上 40×24 是图像（红 = u、绿 = v），其余补齐的部分是品红
        var pixels = [UInt8]()
        for y in 0..<64 {
            for x in 0..<64 {
                pixels += x < 40 && y < 24 ? [UInt8(x * 6 + 3), UInt8(y * 10 + 5), 0, 255] : [255, 0, 255, 255]
            }
        }
        return texData(width: 64, height: 64, format: 0, pixels: pixels, sheet: nil, image: (40, 24))
    case "white":
        return texData(width: 4, height: 4, format: 0, pixels: [UInt8](repeating: 255, count: 64), sheet: nil)
    case "rampr8":
        // R8：横向从 0 线性升到 1（第 x 列是 x / 63）
        var pixels = [UInt8]()
        for _ in 0..<4 { for x in 0..<64 { pixels.append(UInt8((Double(x) / 63 * 255).rounded())) } }
        return texData(width: 64, height: 4, format: 9, pixels: pixels, sheet: nil)
    case "normal":
        // 法线图：x、y 分量随位置变化（看偏移方向），z 朝外
        var pixels = [UInt8]()
        for y in 0..<32 {
            for x in 0..<32 { pixels += [UInt8(x * 8), UInt8(255 - y * 8), 200, 255] }
        }
        return texData(width: 32, height: 32, format: 0, pixels: pixels, sheet: nil)
    case "grid":
        var pixels = [UInt8]()
        for y in 0..<64 {
            for x in 0..<64 {
                let check: UInt8 = (x / 8 + y / 8) % 2 == 0 ? 220 : 40
                pixels += [check, UInt8(x * 4), UInt8(y * 4), 255]
            }
        }
        return texData(width: 64, height: 64, format: 0, pixels: pixels, sheet: nil)
    case "sheet16":
        // 64×64：4×4 共 16 帧，每帧 16×16，颜色按帧号变
        var pixels = [UInt8]()
        for y in 0..<64 {
            for x in 0..<64 {
                let frame = (y / 16) * 4 + x / 16
                let edge = x % 16 < 2 || y % 16 < 2
                pixels += edge ? [255, 255, 255, 255] : [UInt8(frame * 16), UInt8(255 - frame * 16), UInt8((frame % 4) * 80), 255]
            }
        }
        return texData(width: 64, height: 64, format: 0, pixels: pixels, sheet: (frames: 16, width: 16, height: 16, perRow: 4))
    case "sheet5":
        // 80×16：一行 5 帧，每帧 16×16（帧宽占 0.2，二进制小数表示不精确）
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [255, 0, 255]]
        var pixels = [UInt8]()
        for y in 0..<16 {
            for x in 0..<80 { pixels += x % 16 < 2 || y < 2 ? [255, 255, 255, 255] : colors[x / 16] + [255] }
        }
        return texData(width: 80, height: 16, format: 0, pixels: pixels, sheet: (frames: 5, width: 16, height: 16, perRow: 5))
    case "paddedsheet":
        // 64×32 的贴图里只有左边 48×32 是图像：每行 3 帧、共 2 行，每帧 16×16，其余补齐成灰色
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [255, 0, 255], [0, 255, 255]]
        var pixels = [UInt8]()
        for y in 0..<32 {
            for x in 0..<64 {
                if x >= 48 { pixels += [90, 90, 90, 255]; continue }
                let frame = (y / 16) * 3 + x / 16
                pixels += x % 16 < 2 || y % 16 < 2 ? [255, 255, 255, 255] : colors[frame] + [255]
            }
        }
        return texData(width: 64, height: 32, format: 0, pixels: pixels, sheet: (frames: 6, width: 16, height: 16, perRow: 3),
                       image: (48, 32))
    case "sheet":
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
                                 [255, 0, 255], [0, 255, 255], [255, 128, 0], [128, 0, 255]]
        var pixels = [UInt8]()
        for y in 0..<32 {
            for x in 0..<64 {
                let frame = (y / 16) * 4 + x / 16
                let edge = x % 16 < 2 || y % 16 < 2
                pixels += edge ? [255, 255, 255, 255] : colors[frame] + [255]
            }
        }
        return texData(width: 64, height: 32, format: 0, pixels: pixels, sheet: (frames: 8, width: 16, height: 16, perRow: 4))
    default:
        var pixels = [UInt8]()
        for y in 0..<32 {
            for x in 0..<32 { pixels += [UInt8(x * 8 + 4), UInt8(y * 8 + 4), 0, 255] }
        }
        return texData(width: 32, height: 32, format: 0, pixels: pixels, sheet: nil)
    }
}

/// 一种颜色的 4×4 贴图，"r g b"（0–255）
private func constantTexture(_ rgb: String) -> Data {
    let parts = rgb.split(separator: " ").compactMap { UInt8($0) }
    let pixel = parts.count == 4 ? parts : parts.count == 3 ? parts + [255] : [128, 128, 255, 255]
    return texData(width: 4, height: 4, format: 0, pixels: Array([[UInt8]](repeating: pixel, count: 16).joined()), sheet: nil)
}

private func texData(
    width: Int, height: Int, format: UInt32, pixels: [UInt8], sheet: (frames: Int, width: Int, height: Int, perRow: Int)?,
    image: (Int, Int)? = nil
) -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func f32(_ value: Float) { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    u32(format); u32(2); u32(UInt32(width)); u32(UInt32(height))
    u32(UInt32(image?.0 ?? width)); u32(UInt32(image?.1 ?? height)); u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1); u32(UInt32(bitPattern: -1))
    u32(1); u32(UInt32(width)); u32(UInt32(height)); u32(0); u32(UInt32(pixels.count)); u32(UInt32(pixels.count))
    data += Data(pixels)
    if let sheet {
        data += Data("TEXS0003".utf8) + Data([0])
        u32(UInt32(sheet.frames)); u32(UInt32(sheet.width)); u32(UInt32(sheet.height))
        for frame in 0..<sheet.frames {
            u32(0); f32(1 / Float(sheet.frames))
            f32(Float((frame % sheet.perRow) * sheet.width)); f32(Float((frame / sheet.perRow) * sheet.height))
            f32(Float(sheet.width)); f32(0); f32(0); f32(Float(sheet.height))
        }
    }
    return data
}
