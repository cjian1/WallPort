import Foundation
import Metal
import SceneRenderer
import WallpaperFormats

/// 黑盒量一个特效着色器的行为：一张宽 × 高的贴图（中间一个白点 / 横向渐变 / 自定义的 RGBA 文件）挂上给定的
/// 片元着色器渲染，打印中间那一行的像素。用来量模糊核、确认函数的符号约定，给兼容素材对照用（只看输出，不看实现）。
///
///   WallpaperTool probe-effect <WE 自带素材目录|none> <片元着色器> [impulse|ramp|grid] [宽] [高] [顶点着色器]
///   素材目录写 none 时只用兼容素材
func probeEffect(assets: String, fragment: String, input: String, width: Int, height: Int, vertex: String?) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice(),
          let fragmentSource = try? String(contentsOfFile: fragment, encoding: .utf8)
    else {
        print("✗ 读不到片元着色器或没有 Metal 设备")
        return 1
    }
    let vertexSource = vertex.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = vec4(a_TexCoord, a_TexCoord);
        }
        """
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            switch input {
            case "ramp":
                let v = UInt8(x * 255 / max(width - 1, 1))
                pixels.replaceSubrange(i..<i + 4, with: [v, UInt8(255 - Int(v)), UInt8(y * 255 / max(height - 1, 1)), 255])
            case "grid":
                let v: UInt8 = (x / 4 + y / 4) % 2 == 0 ? 255 : 0
                pixels.replaceSubrange(i..<i + 4, with: [v, v, v, 255])
            default:
                let on = x == width / 2 && y == height / 2
                pixels.replaceSubrange(i..<i + 4, with: on ? [255, 255, 255, 255] : [0, 0, 0, 255])
            }
        }
    }
    let files: [String: Data] = [
        "scene.json": Data("""
            {"general": {"orthogonalprojection": {"width": \(width), "height": \(height)}, "clearcolor": "0 0 0"},
             "objects": [{"id": 1, "image": "models/layer.json", "origin": "\(Double(width) / 2) \(Double(height) / 2) 0",
                          "size": "\(width) \(height)", "effects": [{"file": "effects/probe/effect.json"}]}]}
            """.utf8),
        "models/layer.json": Data(#"{"material": "materials/layer.json"}"#.utf8),
        "materials/layer.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["layer"]}]}"#.utf8),
        "materials/layer.tex": rgbaTex(width: width, height: height, pixels: pixels),
        "effects/probe/effect.json": Data(#"{"passes": [{"material": "materials/effects/probe.json"}]}"#.utf8),
        "materials/effects/probe.json": Data(#"{"passes": [{"shader": "effects/probe"}]}"#.utf8),
        "shaders/effects/probe.vert": Data(vertexSource.utf8),
        "shaders/effects/probe.frag": Data(fragmentSource.utf8),
    ]
    do {
        let renderer = try SceneRenderer(
            device: device, package: try ScenePackage(data: packFiles(files)),
            assets: assets == "none" ? nil : URL(fileURLWithPath: assets, isDirectory: true))
        renderer.problems.forEach { print("✗ \($0)") }
        let image = try renderer.renderImage(width: width, height: height)
        guard let data = image.dataProvider?.data as Data? else { return 1 }
        let row = height / 2
        var line: [String] = []
        for x in 0..<width {
            let i = row * image.bytesPerRow + x * 4
            // 渲染结果是 BGRA
            let (b, g, r, a) = (data[i], data[i + 1], data[i + 2], data[i + 3])
            if input == "impulse", r == 0, g == 0, b == 0 { continue }
            line.append("\(x - (input == "impulse" ? width / 2 : 0)):\(r),\(g),\(b),\(a)")
        }
        print(line.joined(separator: "  "))
        return 0
    } catch {
        print("✗ \(error.localizedDescription)")
        return 1
    }
}

private func rgbaTex(width: Int, height: Int, pixels: [UInt8]) -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    u32(0); u32(3); u32(UInt32(width)); u32(UInt32(height)); u32(UInt32(width)); u32(UInt32(height)); u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1); u32(UInt32(bitPattern: -1))
    u32(1); u32(UInt32(width)); u32(UInt32(height)); u32(0); u32(UInt32(pixels.count)); u32(UInt32(pixels.count))
    return data + Data(pixels)
}

/// 按 scene.pkg 的结构把文件打成包
func packFiles(_ files: [String: Data]) -> Data {
    var header = Data()
    func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
    u32(8)
    header += Data("PKGV0001".utf8)
    u32(files.count)
    var body = Data()
    for (name, data) in files.sorted(by: { $0.key < $1.key }) {
        u32(name.utf8.count)
        header += Data(name.utf8)
        u32(body.count)
        u32(data.count)
        body += data
    }
    return header + body
}
