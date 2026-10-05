import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 纯色图层（solidlayer）上的特效：语料里 3 个场景把音频可视化条挂在纯色层上。
/// 这里用自己写的着色器验证纯色层会真的跑特效链，而且图层的颜色是链的输入。

/// 按 scene.pkg 的结构把文件打成包
private func solidPackage(_ files: [String: Data]) throws -> ScenePackage {
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

/// renderImage 的格式是 BGRX（小端），返回 [r, g, b]
private func solidRGB(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

private let solidVertex = """
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
"""

/// 画布 100×50，黑底；一个红色的纯色图层，框 x 20…40、y 15…35，挂一个特效
private func solidSceneFiles(fragment: String) -> [String: Data] {
    [
        "effects/probe/effect.json": Data(#"{"passes": [{"material": "materials/probe.json"}]}"#.utf8),
        "materials/probe.json": Data(#"{"passes": [{"shader": "probe"}]}"#.utf8),
        "shaders/probe.vert": Data(solidVertex.utf8),
        "shaders/probe.frag": Data(fragment.utf8),
        "models/solid.json": Data(#"{"solidlayer": true, "material": "materials/solid.json"}"#.utf8),
        "materials/solid.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": []}]}"#.utf8),
        "scene.json": Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "image": "models/solid.json", "origin": "30 25 0", "size": "20 20",
                      "color": "1 0 0", "effects": [{"file": "effects/probe/effect.json"}]}]}
        """.utf8),
    ]
}

@Suite struct SolidLayerEffectTests {
    /// 纯色层上的特效会跑：着色器不管输入、直接输出绿色，图层框里就应该是绿的
    /// （改动之前纯色层不建链，框里是图层自己的红色）
    @Test func effectsOnSolidLayersAreRendered() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device,
            package: try solidPackage(solidSceneFiles(fragment: """
                uniform sampler2D g_Texture0;
                varying vec2 v_TexCoord;
                void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }
                """)),
            assets: nil, targetSize: SIMD2(200, 100))
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(renderer.unsupported.isEmpty, "\(renderer.unsupported)")
        #expect(renderer.renderedEffectCount == 1)
        let image = try renderer.renderImage(width: 200, height: 100)
        // 屏幕上图层框 x 40…80、y 50…90：里面绿、外面黑
        #expect(solidRGB(image, 60, 50)[1] > 200 && solidRGB(image, 60, 50)[0] < 50, "\(solidRGB(image, 60, 50))")
        #expect(solidRGB(image, 20, 20).max()! < 30)
    }

    /// 图层的颜色是特效链的输入：把输入原样输出，图层框里应该还是图层自己的红色
    @Test func solidLayerColorFeedsTheChainInput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device,
            package: try solidPackage(solidSceneFiles(fragment: """
                uniform sampler2D g_Texture0;
                varying vec2 v_TexCoord;
                void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
                """)),
            assets: nil, targetSize: SIMD2(200, 100))
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        let image = try renderer.renderImage(width: 200, height: 100)
        let inside = solidRGB(image, 60, 50)
        #expect(inside[0] > 200 && inside[1] < 50 && inside[2] < 50, "\(inside)")
    }

    /// 图层透明度也在链的输入端：alpha 0.5 的红，输出也应该带上这个透明度
    @Test func solidLayerAlphaFeedsTheChainInput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = solidSceneFiles(fragment: """
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
            """)
        files["scene.json"] = Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "image": "models/solid.json", "origin": "30 25 0", "size": "20 20",
                      "color": "1 0 0", "alpha": 0.5, "effects": [{"file": "effects/probe/effect.json"}]}]}
        """.utf8)
        let renderer = try SceneRenderer(
            device: device, package: try solidPackage(files), assets: nil, targetSize: SIMD2(200, 100))
        let image = try renderer.renderImage(width: 200, height: 100)
        // 半透明红叠在黑底上：红约 128、绿蓝接近 0
        let inside = solidRGB(image, 60, 50)
        #expect(abs(Int(inside[0]) - 128) <= 12 && inside[1] < 20, "\(inside)")
    }

    /// 特效本身不随时间变（静态链只算一次），但脚本每帧改图层透明度：透明度一变，链要重算，
    /// 不然画面会停在第一次算出来的颜色上
    @Test func staticChainFollowsScriptedAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var files = solidSceneFiles(fragment: """
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
            """)
        // 第 1 秒以前不透明，之后半透明
        files["scene.json"] = Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "image": "models/solid.json", "origin": "30 25 0", "size": "20 20", "color": "1 0 0",
                      "alpha": {"script": "export function update(value) { return engine.runtime < 1 ? 1 : 0.5; }",
                                "value": 1},
                      "effects": [{"file": "effects/probe/effect.json"}]}]}
        """.utf8)
        let renderer = try SceneRenderer(
            device: device, package: try solidPackage(files), assets: nil, targetSize: SIMD2(200, 100))
        let before = solidRGB(try renderer.renderImage(width: 200, height: 100, time: 0), 60, 50)
        let after = solidRGB(try renderer.renderImage(width: 200, height: 100, time: 2), 60, 50)
        #expect(before[0] > 240, "\(before)")
        #expect(abs(Int(after[0]) - 128) <= 12, "\(after)")
    }
}
