import CoreGraphics
import Foundation
import Metal
import simd
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 场景级相机（general.zoom / cameraparallax / camerashake）、场景级重力 / 风，以及"沉默特性"的覆盖检查。
/// 这一套原来在渲染器里是**静默忽略**的（不产生 unsupported 条目），M6 验收要先把它们变成可见、再修掉。

/// 按 scene.pkg 的结构把文件打成包
private func cameraPackage(_ files: [String: Data]) throws -> ScenePackage {
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

private let cameraVertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
    """
private let cameraFragment = """
    uniform sampler2D g_Texture0;
    varying vec2 v_TexCoord;
    void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
    """

/// 画布 100×100、黑底；中间一个 20×20 的红色纯色块（x、y 都是 40…60）
private func cameraSceneFiles(
    general: String, parallaxDepth: String = "1 1", color: String = "1 0 0", brightness: Float = 1
) -> [String: Data] {
    [
        "models/solid.json": Data(#"{"solidlayer": true, "material": "materials/solid.json"}"#.utf8),
        "materials/solid.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": []}]}"#.utf8),
        "shaders/genericimage2.vert": Data(cameraVertex.utf8),
        "shaders/genericimage2.frag": Data(cameraFragment.utf8),
        "scene.json": Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}, "clearcolor": "0 0 0", \(general)},
         "objects": [{"id": 1, "image": "models/solid.json", "origin": "50 50 0", "size": "20 20",
                      "color": "\(color)", "brightness": \(brightness), "parallaxDepth": "\(parallaxDepth)"}]}
        """.utf8),
    ]
}

private func sceneDescription(general: String, object extra: String = "") throws -> SceneDescription {
    let json = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}, \(general)},
         "objects": [{"id": 1, "image": "models/solid.json", "origin": "50 50 0", "size": "20 20", \(extra)}]}
        """
    return try SceneDescription(json: Data(json.utf8))
}

/// 两张图缩到 64×64 逐像素比较（和 WallpaperTool 的 meanDifference 同一套，测试里自带一份）
private func meanDiff(_ first: CGImage, _ second: CGImage, size: Int = 64) -> Double {
    func thumbnail(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let scale = max(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(
            x: (CGFloat(size) - drawn.width) / 2, y: (CGFloat(size) - drawn.height) / 2,
            width: drawn.width, height: drawn.height))
        return pixels
    }
    let a = thumbnail(first), b = thumbnail(second)
    var total = 0
    for index in stride(from: 0, to: a.count, by: 4) {
        for channel in 0..<3 { total += abs(Int(a[index + channel]) - Int(b[index + channel])) }
    }
    return Double(total) / Double(a.count / 4 * 3)
}

@Suite struct SceneCameraEffectsTests {
    /// general 里的相机和物理字段要读出来（含 NaN / 负 zoom 这类坏值）
    @Test func parsesGeneralCameraAndPhysics() throws {
        let scene = try sceneDescription(general: """
            "zoom": 1.5, "cameraparallax": true, "cameraparallaxamount": 0.5, "cameraparallaxdelay": 0.44,
            "cameraparallaxmouseinfluence": 0.5, "camerashake": true, "camerashakeamplitude": 0.5,
            "camerashakeroughness": 1, "camerashakespeed": 0.59, "camerafade": true,
            "gravitydirection": "0 -1 0", "gravitystrength": 1, "windenabled": true,
            "winddirection": "1 0 0", "windstrength": 2
            """)
        #expect(scene.cameraEffects.zoom == 1.5)
        #expect(scene.cameraEffects.parallaxEnabled)
        #expect(scene.cameraEffects.parallaxAmount == 0.5)
        #expect(scene.cameraEffects.parallaxDelay == 0.44)
        #expect(scene.cameraEffects.parallaxMouseInfluence == 0.5)
        #expect(scene.cameraEffects.shakeEnabled)
        #expect(scene.cameraEffects.shakeSpeed == 0.59)
        #expect(scene.cameraEffects.fadeEnabled)
        #expect(scene.gravity == SIMD3(0, -1, 0))
        #expect(scene.wind == SIMD3(2, 0, 0))
    }

    @Test func ignoresBadValues() throws {
        let scene = try sceneDescription(general: #""zoom": -3, "gravitystrength": "nan""#)
        #expect(scene.cameraEffects.zoom == 1)
        #expect(scene.gravity == .zero)
        // 没写 windenabled 时风不算数
        let windOnly = try sceneDescription(general: #""winddirection": "1 0 0", "windstrength": 5"#)
        #expect(windOnly.wind == .zero)
    }

    /// 图层的 parallaxDepth 要读出来，默认 (1, 1)
    @Test func parsesLayerParallaxDepth() throws {
        let scene = try sceneDescription(general: "", object: #""parallaxDepth": "0.25 0.5""#)
        #expect(scene.objects.first?.parallaxDepth == SIMD2(0.25, 0.5))
        let plain = try sceneDescription(general: "")
        #expect(plain.objects.first?.parallaxDepth == SIMD2(1, 1))
    }

    /// 打开视差以后，指针在左在右画面不一样；depth 为 0 的图层不跟着动
    @Test func parallaxFollowsThePointer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func difference(_ parallaxDepth: String) throws -> Double {
            let renderer = try SceneRenderer(
                device: device,
                package: try cameraPackage(cameraSceneFiles(
                    general: #""cameraparallax": true, "cameraparallaxamount": 1, "cameraparallaxmouseinfluence": 1"#,
                    parallaxDepth: parallaxDepth)),
                assets: nil, targetSize: SIMD2(200, 200))
            let left = try renderer.renderImage(width: 200, height: 200, time: 1, pointer: SIMD2(0.1, 0.5))
            let right = try renderer.renderImage(width: 200, height: 200, time: 1, pointer: SIMD2(0.9, 0.5))
            return meanDiff(left, right)
        }
        #expect(rendererFollows(parallaxDepth: "1 1", device: device))
        // 打开视差时画面随指针变
        let moving = try difference("1 1")
        #expect(moving > 0.5)
        // depth 0 的图层不跟着动
        let still = try difference("0 0")
        #expect(still < 0.01)
    }

    private func rendererFollows(parallaxDepth: String, device: any MTLDevice) -> Bool {
        (try? SceneRenderer(
            device: device,
            package: cameraPackage(cameraSceneFiles(
                general: #""cameraparallax": true, "cameraparallaxamount": 1, "cameraparallaxmouseinfluence": 1"#,
                parallaxDepth: parallaxDepth)),
            assets: nil, targetSize: SIMD2(200, 200)))?.followsPointer ?? false
    }

    /// general.zoom 是绕画布中心的缩放：放大 2 倍以后同一个方块在屏幕上更大
    @Test func sceneZoomScalesTheCanvas() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let plain = try SceneRenderer(
            device: device, package: try cameraPackage(cameraSceneFiles(general: #""zoom": 1"#)),
            assets: nil, targetSize: SIMD2(100, 100))
        let zoomed = try SceneRenderer(
            device: device, package: try cameraPackage(cameraSceneFiles(general: #""zoom": 2"#)),
            assets: nil, targetSize: SIMD2(100, 100))
        let a = try plain.renderImage(width: 100, height: 100, time: 1)
        let b = try zoomed.renderImage(width: 100, height: 100, time: 1)
        #expect(meanDiff(a, b) > 1)
    }

    /// 镜头抖动随时间变（同一个渲染器在 t=0.2 / t=0.6 两帧不一样）
    @Test func cameraShakeChangesOverTime() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device,
            package: try cameraPackage(cameraSceneFiles(
                general: #""camerashake": true, "camerashakeamplitude": 5, "camerashakeroughness": 1, "camerashakespeed": 3"#)),
            assets: nil, targetSize: SIMD2(200, 200))
        let a = try renderer.renderImage(width: 200, height: 200, time: 0.2)
        let b = try renderer.renderImage(width: 200, height: 200, time: 0.6)
        #expect(meanDiff(a, b) > 0.2)
        #expect(SceneRenderer.smoothNoise(0.5, seed: 1) != SceneRenderer.smoothNoise(1.5, seed: 1))
    }

    /// 图层亮度（brightness）：颜色乘它——半亮的红乘 2 和不打折的红画出来一样
    @Test func layerBrightnessScalesTheColor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let half = try SceneRenderer(
            device: device,
            package: try cameraPackage(cameraSceneFiles(general: "", color: "0.5 0 0", brightness: 2)),
            assets: nil, targetSize: SIMD2(100, 100))
        let full = try SceneRenderer(
            device: device,
            package: try cameraPackage(cameraSceneFiles(general: "", color: "1 0 0", brightness: 1)),
            assets: nil, targetSize: SIMD2(100, 100))
        let a = try half.renderImage(width: 100, height: 100, time: 1)
        let b = try full.renderImage(width: 100, height: 100, time: 1)
        #expect(meanDiff(a, b) < 1.0)
    }
}

@Suite struct SceneFeatureCoverageTests {
    @Test func flagsUnimplementedWholeSceneFeatures() {
        let json = Data("""
        {"general": {"orthogonalprojection": {"width": 10, "height": 10}, "camerafade": true,
                     "somefutureflag": true},
         "objects": [{"id": 1, "image": "m", "brightness": 2, "perspective": true}]}
        """.utf8)
        let scene = try! SceneDescription(json: json)
        let unhandled = SceneFeatureCoverage.unhandled(in: json, scene: scene)
        #expect(unhandled["开场淡入（camerafade，未实现）"] == 1)
        #expect(unhandled["general.somefutureflag（未处理）"] == 1)
        #expect(unhandled["透视图层（perspective，未实现）"] == 1)
        // 图层亮度已经实现，不再报
        #expect(!unhandled.keys.contains { $0.contains("brightness") })
    }

    /// 已经处理的整场景特性不要再报（视差、缩放、抖动、重力算做了）
    @Test func doesNotFlagHandledFeatures() {
        let json = Data("""
        {"general": {"orthogonalprojection": {"width": 10, "height": 10}, "zoom": 1.5,
                     "cameraparallax": true, "cameraparallaxamount": 1, "camerashake": true,
                     "camerashakeamplitude": 1, "gravitystrength": 1, "windenabled": true, "windstrength": 1,
                     "bloom": true, "hdr": false, "camerapreview": true},
         "objects": [{"id": 1, "image": "m", "brightness": 1, "castshadow": false}]}
        """.utf8)
        let scene = try! SceneDescription(json: json)
        #expect(SceneFeatureCoverage.unhandled(in: json, scene: scene).isEmpty)
    }

    /// HDR 泛光没实现（非 HDR 的泛光是做了的）
    @Test func flagsHDRBloom() {
        let json = Data("""
        {"general": {"orthogonalprojection": {"width": 10, "height": 10}, "bloom": true, "hdr": true},
         "objects": []}
        """.utf8)
        let scene = try! SceneDescription(json: json)
        #expect(SceneFeatureCoverage.unhandled(in: json, scene: scene)["HDR 泛光（未实现）"] == 1)
    }
}

@Suite struct SceneForceTests {
    /// 场景级重力（general.gravity*）会把粒子往下拉——语料里粒子的 movement 算子普遍写成 0，
    /// 靠的就是这个全局重力（雪花、落叶、尘埃）
    @Test func sceneGravityPullsParticlesDown() throws {
        let definition = try ParticleDefinition(json: Data("""
        {"material": "m", "maxcount": 8,
         "emitter": [{"name": "sphererandom", "rate": 8, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "velocityrandom", "min": "0 0 0", "max": "0 0 0"}],
         "operator": [{"name": "movement", "gravity": "0 0 0", "drag": 0}]}
        """.utf8))
        func simulate(_ force: SIMD3<Float>) -> Float {
            let simulation = ParticleSimulation(definition: definition, seed: 3, sceneForce: force)
            var elapsed: Float = 0
            let origins = [SIMD3<Float>](repeating: .zero, count: 8)
            while elapsed < 1 {
                simulation.step(1.0 / 30, controlPoints: origins)
                elapsed += 1.0 / 30
            }
            return simulation.particles.first?.position.y ?? 0
        }
        #expect(simulate(SIMD3(0, -100, 0)) < simulate(.zero) - 10)
    }
}
