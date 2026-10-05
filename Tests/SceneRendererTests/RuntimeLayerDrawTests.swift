import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// `thisScene.createLayer` 建出来的图层（音乐可视化条那类）：脚本在 init 里建 63 根柱子，
/// 每帧改 origin / scale。这里用不含任何 WE 内容的自写夹具验证它们真的会被画到画面上。

private func runtimePackage(_ files: [String: Data]) throws -> ScenePackage {
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

/// 全白的 RGBA TEX
private func whiteTex(size: UInt32 = 8) -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    u32(0); u32(2); u32(size); u32(size); u32(size); u32(size); u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1); u32(UInt32(bitPattern: -1))
    u32(1); u32(size); u32(size); u32(0); u32(size * size * 4); u32(size * size * 4)
    return data + Data((0..<Int(size * size)).flatMap { _ in [UInt8(255), 255, 255, 255] })
}

private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

private func runtimeSceneFiles(script: String) -> [String: Data] {
    [
        "models/bar.json": Data(#"{"material": "materials/bar.json"}"#.utf8),
        "materials/bar.json": Data(
            #"{"passes": [{"blending": "translucent", "shader": "genericimage2", "textures": ["white"]}]}"#.utf8),
        "materials/white.tex": whiteTex(),
        "scene.json": Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}, "clearcolor": "0 0 0"},
         "objects": [
           {"id": 1, "name": "控制器", "image": "models/bar.json", "origin": "20 20 0", "size": "4 4",
            "visible": {"script": \(jsonString(script)), "value": true}}
         ]}
        """.utf8),
    ]
}

private func jsonString(_ text: String) -> String {
    let encoded = try! JSONSerialization.data(withJSONObject: [text])
    return String(decoding: encoded.dropFirst().dropLast(), as: UTF8.self)
}

/// init 里建 3 根柱子，每根 20×40（画布 100×100），排在中间一条横线上
private let barScript = """
export function init() {
    for (var i = 0; i < 3; ++i) {
        var bar = thisScene.createLayer('models/bar.json');
        bar.origin = new Vec3(20 + i * 20, 50, 0);
        bar.scale = new Vec3(5, 10, 1);
    }
}
export function update() {}
"""

/// 和真实的可视化条一样：建图层的时候高度是 0（还没有音频），之后每帧才把 scale 改大
private let silentAtFirstScript = """
var bars = [];
export function init() {
    for (var i = 0; i < 3; ++i) {
        var bar = thisScene.createLayer('models/bar.json');
        bars.push(bar);
        bar.origin = new Vec3(20 + i * 20, 50, 0);
        bar.scale = new Vec3(5, 0, 0);
    }
}
export function update() {
    for (var i = 0; i < bars.length; ++i) {
        bars[i].scale = new Vec3(5, 10, 1);
    }
}
"""

/// 可视化条的写法（2350484035 那类）：脚本自己那一层当第一根，其余 createLayer；都设成底边对齐，
/// init 时高度是 0，之后每帧才改大。底边对齐时柱子从 origin 往上长，而不是以 origin 为中心上下对称
private let bottomAlignedScript = """
var bars = [];
export function init() {
    thisLayer.alignment = 'bottom';
    thisLayer.origin = new Vec3(20, 30, 0);
    thisLayer.scale = new Vec3(5, 0, 0);
    bars.push(thisLayer);
    for (var i = 1; i < 3; ++i) {
        var bar = thisScene.createLayer('models/bar.json');
        bar.alignment = 'bottom';
        bar.origin = new Vec3(20 + i * 30, 30, 0);
        bar.scale = new Vec3(5, 0, 0);
        bars.push(bar);
    }
}
export function update() {
    // 第一帧（t = 0）还没有声音，高度是 0：场景里那一层就是按这时的状态建绘制项的
    var height = engine.runtime > 0.25 ? 1 : 0;
    // 场景里那一层是 4×4 的框，运行时建的按贴图尺寸（8×8）摆：缩放减半，三根都是 20×40
    for (var i = 0; i < bars.length; ++i) {
        bars[i].scale = i == 0 ? new Vec3(5, 10 * height, 1) : new Vec3(2.5, 5 * height, 1);
    }
}
"""

@Suite struct RuntimeLayerDrawTests {
    @Test func createdLayersAreDrawn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let package = try runtimePackage(runtimeSceneFiles(script: barScript))
        let renderer = try SceneRenderer(
            device: device, package: package, assets: nil, targetSize: SIMD2(100, 100))
        let image = try renderer.renderImage(width: 100, height: 100, time: 0)
        // 画布 y 向上：y = 50 是画面正中；三根柱子在 x = 20 / 40 / 60
        for x in [20, 40, 60] {
            let pixel = rgb(image, x, 50)
            #expect(pixel == [255, 255, 255], "x=\(x) 处的像素是 \(pixel)，柱子没有画出来")
        }
    }

    /// 建的时候高度为 0（还没有音频），之后每帧才改大——真实的音乐可视化条就是这样
    @Test func layersCreatedWithZeroHeightStillDrawAfterScaleChanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let package = try runtimePackage(runtimeSceneFiles(script: silentAtFirstScript))
        let renderer = try SceneRenderer(
            device: device, package: package, assets: nil, targetSize: SIMD2(100, 100))
        // 画三帧：第一帧建图层，后面的帧改 scale
        _ = try renderer.renderImage(width: 100, height: 100, time: 0)
        _ = try renderer.renderImage(width: 100, height: 100, time: 0.5)
        let image = try renderer.renderImage(width: 100, height: 100, time: 1)
        for x in [20, 40, 60] {
            let pixel = rgb(image, x, 50)
            #expect(pixel == [255, 255, 255], "x=\(x) 处的像素是 \(pixel)，柱子没有画出来")
        }
    }

    /// 底边对齐：20×40 的柱子底边在 y = 30，占画布 y 30…70（画面第 30…70 行）。
    /// 第一根是场景里原有的那一层，它建绘制项时脚本已经把高度设成 0——按 0 烘进顶点的话
    /// 之后的增量要放大上千万倍，这一根会画到别处或者看不见
    @Test func bottomAlignedBarsGrowUpFromTheirOrigin() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let package = try runtimePackage(runtimeSceneFiles(script: bottomAlignedScript))
        let renderer = try SceneRenderer(
            device: device, package: package, assets: nil, targetSize: SIMD2(100, 100))
        _ = try renderer.renderImage(width: 100, height: 100, time: 0)
        _ = try renderer.renderImage(width: 100, height: 100, time: 0.5)
        let image = try renderer.renderImage(width: 100, height: 100, time: 1)
        for x in [20, 50, 80] {
            // 画布 y 向上：画布 y = 65 是第 35 行（柱子里面），y = 25 是第 75 行（底边以下）
            #expect(rgb(image, x, 35) == [255, 255, 255], "x=\(x) 的柱子没有从底边往上长")
            #expect(rgb(image, x, 68) == [255, 255, 255], "x=\(x) 的柱子底边不在 origin 上")
            #expect(rgb(image, x, 75) == [0, 0, 0], "x=\(x) 的柱子伸到了底边以下（还是居中对齐）")
            #expect(rgb(image, x, 25) == [0, 0, 0], "x=\(x) 的柱子比 40 高")
        }
    }
}
