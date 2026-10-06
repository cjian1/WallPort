import CoreGraphics
import Foundation
import Metal
import simd
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 粒子的 rope / ropetrail 画法：把粒子连成一条带子，而不是各画一个精灵。
///
/// WE 的 genericparticle 顶点着色器把位置算成
/// `a_Position + size * (right * (u - 0.5) - up * (v - 0.5) * ratio)`。
/// 画带子时引擎自己把顶点位置算好，所以顶点里的大小填 0，着色器算出来就是原位置——
/// 这里用同一套算式的最小替身着色器，验证的就是这个约定。
private let particleVertex = """
attribute vec3 a_Position;
attribute vec4 a_TexCoordVec4;
attribute vec4 a_Color;
attribute vec2 a_TexCoordC2;
attribute vec4 a_TexCoordVec4C1;
uniform mat4 g_ModelViewProjectionMatrix;
uniform vec4 g_Texture0Resolution;
varying vec2 v_TexCoord;
varying vec4 v_Color;
void main() {
    vec2 uvs = a_TexCoordVec4.xy;
    float size = a_TexCoordVec4.w;
    float ratio = g_Texture0Resolution.y / g_Texture0Resolution.x;
    vec3 position = a_Position + vec3(size * (uvs.x - 0.5), -size * (uvs.y - 0.5) * ratio, 0.0);
    gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = uvs;
    v_Color = a_Color;
}
"""

private let particleFragment = """
uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
varying vec4 v_Color;
void main() {
    gl_FragColor = v_Color * texSample2D(g_Texture0, v_TexCoord);
}
"""

/// 12 个粒子撒在原点周围、半径为 `radius` 的圆周上；`speed` > 0 时它们还会往外飞
private func particleDefinition(renderer: String, radius: Float = 20, speed: Float = 0, startTime: Float = 0.2) -> String {
    """
    {
        "material": "materials/particle.json",
        "maxcount": 40,
        "starttime": \(startTime),
        "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 12, "distancemax": \(radius),
                     "distancemin": \(radius), "speedmin": \(speed), "speedmax": \(speed)}],
        "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                        {"name": "sizerandom", "min": 3, "max": 3},
                        {"name": "colorrandom", "min": "255 255 255", "max": "255 255 255"}],
        "operator": [{"name": "movement"}],
        "renderer": [\(renderer)]
    }
    """
}

private let scene = """
{
    "general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
    "objects": [{"id": 1, "particle": "particles/p.json", "origin": "50 25 0"}]
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

private func makeFiles(renderer: String, radius: Float = 20, speed: Float = 0, startTime: Float = 0.2) -> [String: Data] {
    [
        "scene.json": Data(scene.utf8),
        "particles/p.json": Data(particleDefinition(renderer: renderer, radius: radius, speed: speed, startTime: startTime).utf8),
        "materials/particle.json": Data(
            #"{"passes": [{"shader": "genericparticle", "blending": "additive", "cullmode": "nocull", "textures": ["white"]}]}"#
                .utf8),
        "materials/white.tex": makeTex([255, 255, 255, 255]),
        "shaders/genericparticle.vert": Data(particleVertex.utf8),
        "shaders/genericparticle.frag": Data(particleFragment.utf8),
    ]
}

/// 画出来的像素里有多少个亮着的
private func litPixels(_ image: CGImage) -> Int {
    let data = image.dataProvider!.data! as Data
    var count = 0
    for y in 0..<image.height {
        for x in 0..<image.width where data[y * image.bytesPerRow + x * 4 + 2] > 0 {
            count += 1
        }
    }
    return count
}

private func render(_ renderer: String, radius: Float = 20, speed: Float = 0, startTime: Float = 0.2) throws -> CGImage {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try SceneRenderer(
        device: device, package: makePackage(makeFiles(renderer: renderer, radius: radius, speed: speed, startTime: startTime)), assets: nil)
    #expect(renderer.problems.isEmpty, "\(renderer.problems)")
    let image = try renderer.renderImage(width: 100, height: 50)
    return image
}

@Suite struct RopeParticleTests {
    /// 坏文件：starttime 写成 1e30（有限但极大）时，预模拟的步数超出 Int 的范围，原来转整数时直接崩；
    /// 带子的 segments / subdivision 写成离谱的数也一样
    @Test func absurdStartTimeAndRibbonCountsDoNotCrash() throws {
        _ = try render(#"{"name": "ropetrail", "segments": 1e20, "subdivision": -1e20}"#, startTime: 1e30)
    }

    /// 同一批粒子：sprite 画成 12 个圆点，rope 把它们连成一整圈带子，亮着的像素多得多
    @Test func ropeRendererConnectsParticlesIntoARibbon() throws {
        let sprites = litPixels(try render(#"{"name": "sprite"}"#))
        let rope = litPixels(try render(#"{"name": "rope", "subdivision": 0}"#))
        #expect(sprites > 0, "精灵画法本身要画出东西")
        #expect(rope > sprites * 2, "带子把圆点连起来，亮像素该多出来：\(sprites) → \(rope)")
    }

    @Test func ropeTrailRendererDrawsAlongTheParticlePath() throws {
        // 粒子静止时没有路径可画，带子退化成一条线（画不出像素）
        #expect(litPixels(try render(#"{"name": "ropetrail", "length": 1}"#)) == 0, "不动就没有拖尾")
        // 会飞的粒子：ropetrail 画的是它走过的那条线，比一个圆点多出很多
        let ropeTrail = litPixels(try render(#"{"name": "ropetrail", "length": 1}"#, radius: 6, speed: 10, startTime: 2))
        let sprites = litPixels(try render(#"{"name": "sprite"}"#, radius: 6, speed: 10, startTime: 2))
        #expect(ropeTrail > sprites * 2, "拖尾该比圆点多：\(sprites) → \(ropeTrail)")
    }

    // MARK: - 几何

    private func section(_ x: Float, _ y: Float, halfWidth: Float = 1) -> ParticleLayer.Section {
        ParticleLayer.Section(position: SIMD3(x, y, 0), side: SIMD3(1, 0, 0), halfWidth: halfWidth,
                              color: SIMD4(1, 1, 1, 1), v: 0)
    }

    /// subdivision 用的是切角：拐角被切掉，新的点落在原来的两条边之内，不会冲出去
    @Test func subdivisionRoundsCornersWithoutOvershooting() {
        let corner = [section(0, 0), section(10, 0), section(10, 10), section(20, 10)]
        let smooth = ParticleLayer.smooth(corner, subdivision: 1)
        #expect(smooth.count > corner.count)
        #expect(smooth.first!.position == corner.first!.position, "两端不动")
        #expect(smooth.last!.position == corner.last!.position)
        for point in smooth {
            #expect(point.position.x >= -0.001 && point.position.x <= 20.001)
            #expect(point.position.y >= -0.001 && point.position.y <= 10.001)
        }
        // 原来的拐角 (10,0) 被前一段 3/4 处的点取代
        #expect(!smooth.contains { $0.position.x == 10 && $0.position.y == 0 })
        #expect(smooth.contains { abs($0.position.x - 7.5) < 0.001 && $0.position.y == 0 })

        #expect(ParticleLayer.smooth(corner, subdivision: 0) == corner, "细分为 0 时原样返回")
    }

    /// 沿带子的纹理坐标：按长度累加，走完一整条带子正好是 uvscale 次重复
    @Test func textureCoordinateRunsAlongTheRibbon() {
        let ribbon: (subdivision: Int, uvScale: Float, scrolling: Bool, segments: Int) = (0, 2, false, 0)
        let sections = [section(0, 0), section(3, 4), section(9, 4)]   // 长度 5 + 6
        let mapped = ParticleLayer.assignUV(sections, ribbon: ribbon, time: 0)
        #expect(abs(mapped[0].v) < 0.001)
        #expect(abs(mapped[1].v - 2 * 5.0 / 11) < 0.001)
        #expect(abs(mapped[2].v - 2) < 0.001, "整条带子上贴图铺 uvscale 次")

        let scrolling = ParticleLayer.assignUV(sections, ribbon: (0, 1, true, 0), time: 4)
        #expect(abs(scrolling[2].v - 5) < 0.001, "滚动时整体加时间偏移")
    }

    /// 横截面的方向是路径的法线（在 xy 平面内转 90°），拐弯处用前后两点的切线
    @Test func ribbonSidesArePerpendicularToThePath() {
        let sides = ParticleLayer.ribbonSides([section(0, 0), section(10, 0), section(10, 10)])
        #expect(abs(sides[0].y - 1) < 0.001, "沿 +x 走时横向是 +y")
        #expect(abs(simd_length(sides[1]) - 1) < 0.001, "单位向量")
        // 拐角处按前后两点的平均方向（这里是对角线）取横向，和该方向垂直
        let diagonal = simd_normalize(SIMD3<Float>(1, 1, 0))
        #expect(abs(simd_dot(sides[1], diagonal)) < 0.001, "拐角处用前后两点定方向")
        #expect(abs(sides[0].z) < 0.001 && abs(sides[2].z) < 0.001, "2D 场景里 z 不参与")
    }

    /// 画法上的开关：只有 spritetrail 用着色器的 TRAILRENDERER，只有 rope* 用带子
    @Test func renderersMapToTheRightBranches() {
        #expect(ParticleLayer.Renderer.sprite.ribbon == nil)
        #expect(ParticleLayer.Renderer.spriteTrail(length: 0.05, maxLength: 1, minLength: 0).isSpriteTrail)
        let rope = ParticleLayer.Renderer.rope(subdivision: 3, uvScale: 1, scrolling: false)
        #expect(rope.ribbon?.subdivision == 3)
        #expect(rope.trailLength == 0, "rope 不需要位置历史")
        let trail = ParticleLayer.Renderer.ropeTrail(length: 0.5, segments: 8, subdivision: 2, uvScale: 1, scrolling: true)
        #expect(trail.trailLength == 0.5)
        #expect(trail.ribbon?.segments == 8)
        #expect(trail.ribbon?.scrolling == true)
    }
}
