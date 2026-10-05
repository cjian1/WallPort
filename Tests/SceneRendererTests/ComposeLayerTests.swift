import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 按 scene.pkg 的结构把文件打成包
private func makePackage(_ files: [String: Data]) throws -> ScenePackage {
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
    return try ScenePackage(data: header + body)
}

/// 1×1 的 RGBA TEX
private func makeTex(_ rgba: [UInt8]) -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    u32(0); u32(2); u32(1); u32(1); u32(1); u32(1); u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1); u32(UInt32(bitPattern: -1))
    u32(1); u32(1); u32(1); u32(0); u32(4); u32(4)
    return data + Data(rgba)
}

private func json(_ text: String) -> Data { Data(text.utf8) }

/// 特效：把 g_Texture0 反色；带 SOURCE1 时改为输出 g_Texture1
private let effectFiles: [String: Data] = [
    "effects/test/effect.json": json(#"{"passes": [{"material": "materials/test.json"}]}"#),
    "materials/test.json": json(#"{"passes": [{"shader": "test"}]}"#),
    "shaders/test.vert": json("""
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
        """),
    "shaders/test.frag": json("""
        // [COMBO] {"combo":"SOURCE1","default":0}
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        varying vec2 v_TexCoord;
        void main() {
        #if SOURCE1
            gl_FragColor = texSample2D(g_Texture1, v_TexCoord);
        #else
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(1.0 - c.rgb, c.a);
        #endif
        }
        """),
    "models/solid.json": json(#"{"solidlayer": true}"#),
    "models/compose.json": json(#"{"material": "materials/util/composelayer.json", "passthrough": true}"#),
    "models/green.json": json(#"{"material": "materials/green.json"}"#),
    "materials/green.json": json(#"{"passes": [{"shader": "genericimage2", "textures": ["green"]}]}"#),
    "materials/green.tex": makeTex([0, 255, 0, 255]),
]

/// 画布 100×50：左边一整层红色；右半边是一个合成层
private func scene(composeEffect: String) -> Data {
    json("""
    {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
     "objects": [
        {"id": 1, "image": "models/solid.json", "origin": "50 25 0", "size": "100 50", "color": "1 0 0"},
        {"id": 3, "image": "models/green.json", "origin": "10 10 0", "size": "4 4", "visible": false},
        {"id": 2, "image": "models/compose.json", "origin": "75 25 0", "size": "50 50",
         "effects": [\(composeEffect)]}
     ]}
    """)
}

/// 读出某个像素的 RGB（renderImage 的格式是 BGRX，小端）
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

@Suite struct ComposeLayerTests {
    @Test func composeLayerProcessesWhatIsBehindIt() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = effectFiles
        files["scene.json"] = scene(composeEffect: #"{"file": "effects/test/effect.json"}"#)
        let renderer = try SceneRenderer(device: device, package: makePackage(files), assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        let image = try renderer.renderImage(width: 100, height: 50)
        // 左半边保持红色，右半边是红色经合成层反色后的青色
        #expect(pixel(image, 10, 25) == [255, 0, 0])
        #expect(pixel(image, 90, 25) == [0, 255, 255])
        #expect(pixel(image, 60, 5) == [0, 255, 255])
    }

    /// 合成层的结果按图层的混合模式合回画面、按对齐方式摆：3142391697 时钟外的光环是"相加"（31）的合成层，
    /// 旁边的音频条是右上 / 右下对齐的合成层。这里合成层左对齐、原点在画布正中，只盖右半边；
    /// 红色反色成青色，再和底下的红色相加是白色（按普通模式画会是青色）
    @Test func composeLayerHonoursBlendModeAndAlignment() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = effectFiles
        files["scene.json"] = json("""
            {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
             "objects": [
                {"id": 1, "image": "models/solid.json", "origin": "50 25 0", "size": "100 50", "color": "1 0 0"},
                {"id": 2, "image": "models/compose.json", "origin": "50 25 0", "size": "50 50",
                 "alignment": "left", "colorBlendMode": 31, "effects": [{"file": "effects/test/effect.json"}]}
             ]}
            """)
        let renderer = try SceneRenderer(device: device, package: makePackage(files), assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        let image = try renderer.renderImage(width: 100, height: 50)
        #expect(pixel(image, 40, 25) == [255, 0, 0], "左对齐的合成层不该盖到原点左边")
        #expect(pixel(image, 60, 25) == [255, 255, 255], "相加模式：红 + 青 = 白")
        #expect(pixel(image, 95, 25) == [255, 255, 255], "左对齐的合成层要一直盖到原点右边 50")
    }

    @Test func effectsCanReadHiddenLayersByID() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = effectFiles
        files["scene.json"] = scene(composeEffect: """
            {"file": "effects/test/effect.json",
             "passes": [{"combos": {"SOURCE1": 1}, "textures": [null, "_rt_imageLayerComposite_3_a"]}]}
            """)
        let renderer = try SceneRenderer(device: device, package: makePackage(files), assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        let image = try renderer.renderImage(width: 100, height: 50)
        // 隐藏的绿色图层不直接出现在画面上，但它的结果被合成层的特效读到了
        #expect(pixel(image, 10, 10) == [255, 0, 0])
        #expect(pixel(image, 90, 25) == [0, 255, 0])
    }
}
