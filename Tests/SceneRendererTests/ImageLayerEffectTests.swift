import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 按 scene.pkg 的结构把文件打成包
private func imagePackage(_ files: [String: Data]) throws -> ScenePackage {
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

/// 单色的 RGBA TEX（边长 size）。图层空间的特效缓冲按贴图分辨率开，1×1 的贴图只有一个像素，所以用 8×8
private func imageTex(_ rgba: [UInt8], size: UInt32 = 8) -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    u32(0); u32(2); u32(size); u32(size); u32(size); u32(size); u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1); u32(UInt32(bitPattern: -1))
    u32(1); u32(size); u32(size); u32(0); u32(size * size * 4); u32(size * size * 4)
    return data + Data((0..<Int(size * size)).flatMap { _ in rgba })
}

/// renderImage 的格式是 BGRX（小端），返回 [r, g, b]
private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

/// 画布 100×50；一张蓝色的图片图层，框 x 20…40、y 15…35（不在画面中央、也不铺满），挂一个特效
private func sceneFiles(vertex: String, fragment: String) -> [String: Data] {
    [
        "effects/probe/effect.json": Data(#"{"passes": [{"material": "materials/probe.json"}]}"#.utf8),
        "materials/probe.json": Data(#"{"passes": [{"shader": "probe"}]}"#.utf8),
        "shaders/probe.vert": Data(vertex.utf8),
        "shaders/probe.frag": Data(fragment.utf8),
        "models/blue.json": Data(#"{"material": "materials/blue.json"}"#.utf8),
        "materials/blue.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["blue"]}]}"#.utf8),
        "materials/blue.tex": imageTex([0, 0, 255, 255]),
        "scene.json": Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "image": "models/blue.json", "origin": "30 25 0", "size": "20 20",
                      "effects": [{"file": "effects/probe/effect.json"}]}]}
        """.utf8),
    ]
}

private let plainVertex = """
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
"""

@Suite struct ImageLayerEffectTests {
    /// 图片图层的特效链在图层自己的空间里算：缓冲不是整屏大小，纹理坐标 0–1 横跨图层框
    /// （作者画在图层上的遮罩、X-ray 读的别的图层都按这个坐标对齐）；结果只画在图层自己的位置上
    @Test func effectsRunInTheLayersOwnSpace() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // 左半边绿、右半边红：在图层空间里算的话，分界线正好在图层框的正中间
        let files = sceneFiles(vertex: plainVertex, fragment: """
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = v_TexCoord.x < 0.5 ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0); }
            """)
        let renderer = try SceneRenderer(
            device: device, package: try imagePackage(files), assets: nil, targetSize: SIMD2(200, 100))
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(renderer.unsupported.isEmpty, "\(renderer.unsupported)")
        #expect(!renderer.memorySummary.contains { name, _ in name.contains("特效链 200×100") })
        let image = try renderer.renderImage(width: 200, height: 100)
        // 屏幕上图层框 x 40…80：左四分之一处绿、右四分之一处红，框外黑
        #expect(rgb(image, 50, 50)[1] > 200 && rgb(image, 50, 50)[0] < 50, "\(rgb(image, 50, 50))")
        #expect(rgb(image, 70, 50)[0] > 200 && rgb(image, 70, 50)[1] < 50)
        #expect(rgb(image, 150, 50).max()! < 30)
    }

    /// 顶点模式的特效（植物摇摆、倾斜、透视的 Vertex 模式）按图层像素挪顶点：画到特效输出的通道里 a_Position
    /// 以像素为单位（中心为原点），乘 g_ModelViewProjectionMatrix 才是裁剪坐标。8×8 的贴图挪 2 像素 = 图层宽的 1/4；
    /// 以前四边形是裁剪坐标，挪 2 就是挪了一整个缓冲宽，整张图都挪没了（1446650543 整个画面大幅摆动）
    @Test func vertexDisplacementIsInLayerPixels() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let files = sceneFiles(vertex: """
            uniform mat4 g_ModelViewProjectionMatrix;
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
                vec3 position = a_Position;
                position.x += 2.0;
                gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
                v_TexCoord = a_TexCoord;
            }
            """, fragment: """
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = v_TexCoord.x < 0.5 ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0); }
            """)
        let renderer = try SceneRenderer(
            device: device, package: try imagePackage(files), assets: nil, targetSize: SIMD2(200, 100))
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        let image = try renderer.renderImage(width: 200, height: 100)
        // 屏幕上图层框 x 40…80，缓冲的一个像素是 5 个屏幕像素：左边 2 像素露空，接着绿 4 像素、红 2 像素（右边挪出框了）
        #expect(rgb(image, 45, 50).max()! < 30, "\(rgb(image, 45, 50))")
        #expect(rgb(image, 60, 50)[1] > 200 && rgb(image, 60, 50)[0] < 50, "\(rgb(image, 60, 50))")
        #expect(rgb(image, 76, 50)[0] > 200 && rgb(image, 76, 50)[1] < 50, "\(rgb(image, 76, 50))")
    }

    /// WE 自带 xray 的写法：用 g_ModelViewProjectionMatrixInverse 把屏幕上的鼠标反投影成图层像素坐标
    /// （以图层中心为原点、y 朝上），除以贴图分辨率得到 −0.5…0.5。鼠标在图层中心时是 0，在右边缘是 +0.5
    @Test func pointerUnprojectsIntoTheLayer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let files = sceneFiles(vertex: """
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform mat4 g_ModelViewProjectionMatrixInverse;
            uniform vec4 g_Texture0Resolution;
            uniform vec2 g_PointerPosition;
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec3 v_PointerUV;
            void main() {
                gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
                vec2 pointer = g_PointerPosition;
                pointer.y = 1.0 - pointer.y;
                v_PointerUV = mul(vec4(pointer * 2 - 1, 0.0, 1.0), g_ModelViewProjectionMatrixInverse).xyw;
                v_PointerUV.xy *= 1.0 / g_Texture0Resolution.xy;
            }
            """, fragment: """
            uniform sampler2D g_Texture0;
            varying vec3 v_PointerUV;
            void main() {
                vec2 uv = v_PointerUV.xy / v_PointerUV.z + 0.5;
                gl_FragColor = vec4(clamp(uv.x, 0.0, 1.0), clamp(uv.y, 0.0, 1.0), 0.0, 1.0);
            }
            """)
        let renderer = try SceneRenderer(
            device: device, package: try imagePackage(files), assets: nil, targetSize: SIMD2(200, 100))
        #expect(renderer.unsupported.isEmpty, "\(renderer.unsupported)")
        // 鼠标在图层中心（屏幕 0.3, 0.5）：两个分量都是 0.5 → 约 128
        let centered = rgb(try renderer.renderImage(width: 200, height: 100, pointer: SIMD2(0.3, 0.5)), 60, 50)
        #expect(abs(Int(centered[0]) - 128) <= 6 && abs(Int(centered[1]) - 128) <= 6, "\(centered)")
        // 鼠标在图层右边缘（屏幕 0.4）：x 分量 1.0；在图层上边缘（屏幕 y 0.3）：y 分量 1.0（y 朝上）
        #expect(rgb(try renderer.renderImage(width: 200, height: 100, pointer: SIMD2(0.4, 0.5)), 60, 50)[0] > 245)
        #expect(rgb(try renderer.renderImage(width: 200, height: 100, pointer: SIMD2(0.3, 0.3)), 60, 50)[1] > 245)
    }
}
