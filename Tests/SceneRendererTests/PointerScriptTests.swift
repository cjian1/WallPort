import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

private func pointerPackage(_ files: [String: Data]) throws -> ScenePackage {
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

private func pointerPixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

private func pointerJSON(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self)
        .dropFirst().dropLast().description
}

/// 悬停时放大、移开缩回（`~/wp` 里 Lucy 时钟的 scale 脚本就是这种写法）
private let hoverScript = """
'use strict';
export var scriptProperties = createScriptProperties()
    .addSlider({ name: 'hoverScale', value: 2 })
    .addSlider({ name: 'speed', value: 10 })
    .finish();

let target = 1;

export function cursorEnter(event) { target = scriptProperties.hoverScale; }
export function cursorLeave(event) { target = 1; }

export function update(value) {
    return value.x + (target - value.x) * scriptProperties.speed * engine.frametime;
}
"""

/// 画布 100×50，中间一个 20×20 的红方块，scale 由悬停脚本驱动
private func hoverScene() -> [String: Data] {
    [
        "scene.json": Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "image": "models/solid.json", "origin": "50 25 0", "size": "20 20",
                      "color": "1 0 0",
                      "scale": {"script": \(pointerJSON(hoverScript)), "value": "1 1 1"}}]}
        """.utf8),
        "models/solid.json": Data(#"{"solidlayer": true}"#.utf8),
    ]
}

@Suite struct PointerScriptTests {
    /// 脚本里注册的回调能被找到（点击/拖动靠它判断要不要收事件）
    @Test func handlerLookup() throws {
        let script = try #require(SceneScript(
            source: "export function cursorDown(event) {}\nexport function update(v) { return v; }",
            properties: nil, environment: .init()))
        #expect(script.hasHandler("cursorDown"))
        #expect(script.hasHandler("update"))
        #expect(!script.hasHandler("cursorUp"))
    }

    /// 点在四边形里：进出要触发 cursorEnter / cursorLeave
    @Test func pointInQuadDetection() {
        let quad: [SIMD4<Float>] = [
            SIMD4(0, 0, 0, 0), SIMD4(10, 0, 1, 0), SIMD4(0, 10, 0, 1), SIMD4(10, 10, 1, 1),
        ]
        #expect(SceneRenderer.contains(quad, SIMD2(5, 5)))
        #expect(!SceneRenderer.contains(quad, SIMD2(15, 5)))
        #expect(!SceneRenderer.contains(quad, SIMD2(5, -1)))
    }

    /// 鼠标移到方块上：脚本收到 cursorEnter，缩放朝 hoverScale 走；移开再缩回
    @Test func hoverGrowsAndShrinksTheLayer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device, package: try pointerPackage(hoverScene()), assets: nil)
        #expect(renderer.needsAnimation)

        // 鼠标在方块外：保持 1 倍
        var image = try renderer.renderImage(width: 100, height: 50, time: 0, pointer: SIMD2(0.05, 0.5))
        #expect(pointerPixel(image, 50, 25) == [255, 0, 0])
        #expect(pointerPixel(image, 38, 25) == [0, 0, 0])   // 方块只有 20 宽

        // 鼠标移到方块中心，连续几帧让它长大
        for index in 1...12 {
            image = try renderer.renderImage(
                width: 100, height: 50, time: Float(index) / 30, pointer: SIMD2(0.5, 0.5))
        }
        #expect(pointerPixel(image, 38, 25) == [255, 0, 0], "悬停后应该变大")

        // 鼠标移开，再缩回去
        for index in 13...30 {
            image = try renderer.renderImage(
                width: 100, height: 50, time: Float(index) / 30, pointer: SIMD2(0.05, 0.5))
        }
        #expect(pointerPixel(image, 38, 25) == [0, 0, 0], "移开后应该缩回")
    }

    /// 按下拖动：cursorDown 拿起、cursorMove 跟着鼠标走、cursorUp 放下（`~/wp` 里时钟的拖拽脚本）
    @Test func draggingMovesTheLayer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let script = """
        'use strict';
        let dragging = false;
        let offset = new Vec3(0, 0, 0);
        export function cursorDown(event) {
            dragging = true;
            offset = thisLayer.origin.subtract(event.worldPosition);
        }
        export function cursorMove(event) {
            if (dragging) thisLayer.origin = event.worldPosition.add(offset);
        }
        export function cursorUp(event) { dragging = false; }
        export function update(value) { return value; }
        """
        let scene = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "image": "models/solid.json", "size": "20 20", "color": "1 0 0",
                      "origin": \(#"{"script": \#(pointerJSON(script)), "value": "50 25 0"}"#)}]}
        """
        let renderer = try SceneRenderer(
            device: device,
            package: try pointerPackage([
                "scene.json": Data(scene.utf8), "models/solid.json": Data(#"{"solidlayer": true}"#.utf8),
            ]),
            assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems) / \(renderer.unsupported)")
        #expect(renderer.needsPointerEvents)

        // 按下（点在方块上）→ 拖到右边 → 抬起
        let start = SIMD2<Float>(0.5, 0.5)
        let target = SIMD2<Float>(0.7, 0.5)
        var image = try renderer.renderImage(
            width: 100, height: 50, time: 0, pointer: start, pointerEvents: [.init(kind: .down, position: start)])
        #expect(pointerPixel(image, 50, 25) == [255, 0, 0])
        image = try renderer.renderImage(
            width: 100, height: 50, time: 0.1, pointer: target,
            pointerEvents: [.init(kind: .dragged, position: target)])
        image = try renderer.renderImage(
            width: 100, height: 50, time: 0.2, pointer: target,
            pointerEvents: [.init(kind: .up, position: target)])
        // 方块跟着鼠标搬到了右边（画布 100 宽，0.7 对应 x=70）
        #expect(pointerPixel(image, 70, 25) == [255, 0, 0])
        #expect(pointerPixel(image, 50, 25) == [0, 0, 0])
    }

    /// 点击（按下后很快抬起）会合成 cursorClick
    @Test func quickClickIsSynthesized() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let script = """
        'use strict';
        let clicks = 0;
        export function cursorClick(event) { clicks += 1; }
        export function update(value) { return value; }
        """
        let scene = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "image": "models/solid.json", "origin": "50 25 0", "size": "20 20",
                      "color": "1 0 0",
                      "alpha": \(#"{"script": \#(pointerJSON(script)), "value": 1}"#)}]}
        """
        let renderer = try SceneRenderer(
            device: device,
            package: try pointerPackage([
                "scene.json": Data(scene.utf8), "models/solid.json": Data(#"{"solidlayer": true}"#.utf8),
            ]),
            assets: nil)
        #expect(renderer.needsPointerEvents)
        // click 事件本身就能送到脚本，不崩、场景照常画
        let point = SIMD2<Float>(0.5, 0.5)
        let image = try renderer.renderImage(
            width: 100, height: 50, time: 0, pointer: point, pointerEvents: [.init(kind: .click, position: point)])
        #expect(pointerPixel(image, 50, 25) == [255, 0, 0])
    }
}
