import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 折射粒子（雨打在玻璃上）：着色器按屏幕坐标去读"到这里为止的画面"（WE 的 _rt_FullFrameBuffer）。
///
/// 素材不能进仓库，所以这里用自己写的最小粒子着色器复现同一套坐标约定：
/// 顶点里 `v_ScreenCoord = gl_Position.xyw`，片段里
/// `coord = xy / w * 0.5 + 0.5`（裁剪坐标 y 向上、纹理坐标 v = 0 在画面底部）。
private let particleVertex = """
attribute vec3 a_Position;
attribute vec4 a_TexCoordVec4;
attribute vec4 a_Color;
attribute vec2 a_TexCoordC2;
uniform mat4 g_ModelViewProjectionMatrix;
varying vec2 v_TexCoord;
varying vec4 v_Color;
varying vec3 v_ScreenCoord;
void main() {
    vec2 uvs = a_TexCoordVec4.xy;
    float size = a_TexCoordVec4.w;
    vec3 position = a_Position + vec3((uvs.x - 0.5) * size, (0.5 - uvs.y) * size, 0.0);
    gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = uvs;
    v_Color = a_Color;
    v_ScreenCoord = gl_Position.xyw;
}
"""

private let particleFragment = """
// [COMBO] {"combo":"REFRACT","default":0}
#include "particle_refract.h"
uniform sampler2D g_Texture0;
#if REFRACT
uniform sampler2D g_Texture1; // {"format":"normalmap","formatcombo":true,"combo":"NORMALMAP"}
uniform sampler2D g_Texture3; // {"default":"_rt_FullFrameBuffer","hidden":true}
#endif
varying vec2 v_TexCoord;
varying vec4 v_Color;
varying vec3 v_ScreenCoord;
void main() {
    vec4 color = v_Color * texSample2D(g_Texture0, v_TexCoord);
#if REFRACT
    vec2 offset = CAST2(0.0);
#if NORMALMAP
    vec3 normal = texSample2D(g_Texture1, v_TexCoord).xyz * 2.0 - 1.0;
    offset = normal.xy * g_RefractAmount;
    offset.y = -offset.y;
#endif
    vec2 coord = v_ScreenCoord.xy / v_ScreenCoord.z * vec2(0.5, 0.5) + 0.5 + offset;
    color.rgb *= texSample2D(g_Texture3, coord).rgb;
#endif
    gl_FragColor = color;
}
"""

/// 折射量写在头文件里，和 WE 的 common_particles.h 一样
private let particleHeader = """
uniform float g_RefractAmount; // {"material":"refractamount","default":0.05}
"""

private let particleDefinition = """
{
    "material": "materials/refract.json",
    "maxcount": 4,
    "emitter": [{"name": "sphererandom", "rate": 10, "distancemax": 0}],
    "initializer": [{"name": "lifetimerandom", "min": 30, "max": 30},
                    {"name": "sizerandom", "min": 10, "max": 10}],
    "renderer": [{"name": "sprite"}]
}
"""

/// 画布 100×50：下半蓝、上半红，粒子系统放在上半部分中央
private let scene = """
{
    "general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
    "objects": [
        {"id": 1, "image": "models/solid.json", "origin": "50 12.5 0", "size": "100 25", "color": "0 0 1"},
        {"id": 2, "image": "models/solid.json", "origin": "50 37.5 0", "size": "100 25", "color": "1 0 0"},
        {"id": 3, "particle": "particles/refract.json", "origin": "50 37.5 0"}
    ]
}
"""

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

/// - Parameter material: 折射材质的 pass（开关、贴图、材质参数）
private func makeFiles(material: String) -> [String: Data] {
    [
        "scene.json": Data(scene.utf8),
        "particles/refract.json": Data(particleDefinition.utf8),
        "materials/refract.json": Data(material.utf8),
        "materials/white.tex": makeTex([255, 255, 255, 255]),
        // 法线图：解码后是 (0, 0, 1)，加上折射量后偏移很小
        "materials/flatnormal.tex": makeTex([128, 128, 255, 255]),
        // 生产代码只接受 WE 的 genericparticle，这里用同名的最小替身
        "shaders/genericparticle.vert": Data(particleVertex.utf8),
        "shaders/genericparticle.frag": Data(particleFragment.utf8),
        "shaders/particle_refract.h": Data(particleHeader.utf8),
        "models/solid.json": Data(#"{"solidlayer": true}"#.utf8),
    ]
}

/// 读出某个像素的 RGB（renderImage 的格式是 BGRX，小端）
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

@Suite struct RefractionParticleTests {
    /// 没有法线图：折射量不起作用，但采样位置要对。粒子在上半部分（红色区域），
    /// 正确取样会原样得到红色；如果画面拷贝没有上下翻转，着色器会取到下半部分的蓝色
    @Test func refractionSamplesTheScreenAtTheFragmentsPosition() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let material = """
        {"passes": [{"shader": "genericparticle", "blending": "translucent",
                     "combos": {"REFRACT": 1}, "textures": ["white"]}]}
        """
        let renderer = try SceneRenderer(
            device: device, package: makePackage(makeFiles(material: material)), assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(renderer.particleSystemCount == 1)

        let image = try renderer.renderImage(width: 100, height: 50, time: 0.5)
        // 图像第 12 行就是画布上半部分（y 轴向上）：粒子取样正确时原样是红色，
        // 画面拷贝没有翻转时会取到下半部分的蓝色
        #expect(pixel(image, 50, 12) == [255, 0, 0])
        #expect(pixel(image, 50, 37) == [0, 0, 255])
        #expect(pixel(image, 5, 12) == [255, 0, 0])
    }

    /// 给了法线图时 NORMALMAP 自动打开（贴图槽的关联开关），折射量从 #include 的头文件里读到默认值、
    /// 再被材质的 constantshadervalues 覆盖
    @Test func normalMapTurnsOnTheComboAndTheHeaderParameterIsSet() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let material = """
        {"passes": [{"shader": "genericparticle", "blending": "translucent",
                     "combos": {"REFRACT": 1}, "textures": ["white", "flatnormal"],
                     "constantshadervalues": {"refractamount": 0.4}}]}
        """
        let renderer = try SceneRenderer(
            device: device, package: makePackage(makeFiles(material: material)), assets: nil)
        let summary = try #require(renderer.effectSummaries.first { $0.hasPrefix("粒子 ") })
        #expect(summary.contains("REFRACT=1"))
        #expect(summary.contains("NORMALMAP=1"))
        #expect(summary.contains("1=flatnormal"))
        #expect(summary.contains("refractamount=0.4"))
        #expect(renderer.unsupported["折射粒子（跳过）"] == nil)
    }
}
