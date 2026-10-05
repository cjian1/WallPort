import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 场景泛光（general.bloom）的整条链：降采样 → 两次模糊 → 加回画面。
/// WE 的着色器在自带素材里（不进仓库），这里在夹具包里放同名的简化版：降采样直接输出 (强度, 0, 0)，
/// 模糊原样传递，合成把两张相加——画面是黑的，结果的红色就等于泛光强度，能看出参数有没有传到、链有没有跑

private func package(_ files: [String: Data]) throws -> ScenePackage {
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

private let vertex = Data("""
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
    """.utf8)

private let passThrough = Data("""
    uniform sampler2D g_Texture0;
    varying vec2 v_TexCoord;
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
    """.utf8)

private func files(general: String) -> [String: Data] {
    [
        "shaders/downsample_quarter_bloom.vert": vertex,
        "shaders/downsample_quarter_bloom.frag": Data("""
            uniform sampler2D g_Texture0;
            uniform float g_BloomStrength; // {"material":"bloomstrength","default":2}
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = vec4(g_BloomStrength + texSample2D(g_Texture0, v_TexCoord).r, 0.0, 0.0, 1.0); }
            """.utf8),
        "shaders/downsample_eighth_blur_v.vert": vertex,
        "shaders/downsample_eighth_blur_v.frag": passThrough,
        "shaders/blur_h_bloom.vert": vertex,
        "shaders/blur_h_bloom.frag": passThrough,
        "shaders/combine.vert": vertex,
        "shaders/combine.frag": Data("""
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture1;
            varying vec2 v_TexCoord;
            void main() {
                gl_FragColor = vec4(texSample2D(g_Texture0, v_TexCoord).rgb + texSample2D(g_Texture1, v_TexCoord).rgb, 1.0);
            }
            """.utf8),
        "scene.json": Data("""
            {"general": {"orthogonalprojection": {"width": 64, "height": 64}, "clearcolor": "0 0 0", \(general)},
             "objects": []}
            """.utf8),
    ]
}

private func red(_ image: CGImage) -> Int {
    let data = image.dataProvider!.data! as Data
    let offset = 32 * image.bytesPerRow + 32 * 4
    return Int(data[offset + 2])
}

@Suite struct SceneBloomTests {
    private func render(general: String, userProperties: String? = nil) throws -> (SceneRenderer, CGImage) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device, package: package(files(general: general)), assets: nil,
            userProperties: userProperties.map { Data($0.utf8) })
        return (renderer, try renderer.renderImage(width: 64, height: 64))
    }

    @Test func bloomAddsTheBlurredHighlightsBack() throws {
        let (renderer, image) = try render(general: #""bloom": true, "bloomstrength": 0.5, "bloomthreshold": 0.65"#)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(abs(red(image) - 128) <= 2, "黑色画面加上强度 0.5 的泛光，红色应该是 128，实际 \(red(image))")
    }

    @Test func bloomOffOrHDRLeavesTheFrameAlone() throws {
        #expect(red(try render(general: #""bloom": false, "bloomstrength": 0.5"#).1) == 0)
        // HDR 场景的泛光是另一套（阈值 1 以上才泛光），8 位画面上不照搬
        #expect(red(try render(general: #""bloom": true, "hdr": true, "bloomstrength": 0.5"#).1) == 0)
    }

    /// 3142391697 的"光圈闪光"这类开关：绑在 general.bloom 上的用户属性
    @Test func bloomFollowsItsUserProperty() throws {
        let general = #""bloom": {"user": "glow", "value": true}, "bloomstrength": {"user": "amount", "value": 0.5}"#
        #expect(red(try render(general: general, userProperties: #"{"glow": false, "amount": 0.5}"#).1) == 0)
        let (_, strong) = try render(general: general, userProperties: #"{"glow": true, "amount": 0.25}"#)
        #expect(abs(red(strong) - 64) <= 2)
    }
}
