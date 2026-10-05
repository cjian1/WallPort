import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 按 scene.pkg 的结构把文件打成包
private func graphPackage(_ files: [String: Data]) throws -> ScenePackage {
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

private func graphPixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

private func jsonText(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self)
        .dropFirst().dropLast().description
}

/// 语料里"幻灯片控制器"用到的那套接口：遍历子图层、改透明度、按名字取图层、调整绘制顺序
private let slideshowScript = """
'use strict';
export var scriptProperties = createScriptProperties()
    .addSlider({ name: 'interval', value: 1 })
    .finish();

let layers = [];
let elapsed = 0;
let index = 0;

export function init() {
    layers = thisObject.getChildren();
    for (const layer of layers) layer.alpha = 0;
    if (layers.length > 0) layers[0].alpha = 1;
}

export function update() {
    if (layers.length < 2) return;
    elapsed += engine.frametime;
    if (elapsed < scriptProperties.interval) return;
    elapsed = 0;
    index = (index + 1) % layers.length;
    for (let i = 0; i < layers.length; i++) layers[i].alpha = i === index ? 1 : 0;
    thisScene.sortLayer(layers[index], 100);
}

export function showByName(name) {
    const layer = thisScene.getLayer(name);
    if (!layer) return false;
    for (const other of layers) other.alpha = 0;
    layer.alpha = 1;
    thisScene.sortLayer(layer, thisScene.getLayerIndex(layer) + 100);
    return true;
}
"""

/// 画布 100×50：一个分组（脚本挂在它上面）里面两个纯色图层，红在下、绿在上
private func slideshowScene(script: String) -> [String: Data] {
    let value = #"{"script": \#(jsonText(script)), "value": true}"#
    return [
        "scene.json": Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [
            {"id": 1, "name": "控制器", "visible": \(value)},
            {"id": 2, "name": "红", "parent": 1, "image": "models/solid.json", "origin": "50 25 0",
             "size": "100 50", "color": "1 0 0"},
            {"id": 3, "name": "绿", "parent": 1, "image": "models/solid.json", "origin": "50 25 0",
             "size": "100 50", "color": "0 1 0"}
         ]}
        """.utf8),
        "models/solid.json": Data(#"{"solidlayer": true}"#.utf8),
    ]
}

@Suite struct SceneGraphScriptTests {
    /// 脚本在 init 里遍历子图层改透明度；每帧按累计时间轮换到下一张
    @Test func childrenAlphaFollowsTheScript() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try SceneRenderer(
            device: device, package: try graphPackage(slideshowScene(script: slideshowScript)), assets: nil)
        // update 不给自己那个属性返回值（只改别的图层）是 WE 的正常写法：不算错误，也不上报
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(renderer.unsupported["脚本驱动的字段（按静态值处理）"] == nil)
        #expect(renderer.needsAnimation)

        // init 里第一张（红）alpha = 1，第二张（绿）alpha = 0
        let first = try renderer.renderImage(width: 100, height: 50, time: 0)
        #expect(graphPixel(first, 50, 25) == [255, 0, 0])

        // 每渲染一帧脚本的时钟最多走 0.25 秒，interval = 1；多渲染几帧应该换到绿
        var last = first
        for time in stride(from: Float(0.5), through: 3, by: 0.5) {
            last = try renderer.renderImage(width: 100, height: 50, time: time)
        }
        #expect(graphPixel(last, 50, 25) == [0, 255, 0])
    }

    /// 位置/缩放也能通过场景对象接口改，并且父图层改了会带着子图层一起走
    @Test func movingAParentLayerMovesItsChildren() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let script = """
        export function update(value) {
            const group = thisScene.getLayer('控制器');
            if (group) group.origin = new Vec3(0, 0, 0);
            return value;
        }
        """
        var files = slideshowScene(script: script)
        // 红块放在中间，脚本把整个分组往左下挪 25
        files["scene.json"] = Data("""
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [
            {"id": 1, "visible": \(#""#)},
            {"id": 2, "image": "models/solid.json", "size": "20 20", "origin": "50 25 0", "color": "1 0 0"}
         ]}
        """.utf8)
        _ = files
        // 用带脚本的分组版本
        let scene = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
         "objects": [
            {"id": 1, "name": "控制器", "origin": "25 25 0",
             "visible": \(#"{"script": \#(jsonText(script)), "value": true}"#)},
            {"id": 2, "parent": 1, "image": "models/solid.json", "size": "20 20", "origin": "25 25 0",
             "color": "1 0 0"}
         ]}
        """
        let renderer = try SceneRenderer(
            device: device,
            package: try graphPackage(["scene.json": Data(scene.utf8), "models/solid.json": Data(#"{"solidlayer": true}"#.utf8)]),
            assets: nil)
        // 构建时脚本就把分组挪到 (25, 25)，红块跟着到画布左下
        let image = try renderer.renderImage(width: 100, height: 50, time: 0)
        #expect(graphPixel(image, 25, 25) == [255, 0, 0])
        #expect(graphPixel(image, 50, 25) == [0, 0, 0])
    }

    /// 认不出来的图层名返回 undefined，脚本自己兜住就行
    @Test func missingLayerByNameIsUndefined() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let script = """
        export function update(value) {
            return thisScene.getLayer('没有这一层') === undefined ? value : false;
        }
        """
        let renderer = try SceneRenderer(
            device: device, package: try graphPackage(slideshowScene(script: script)), assets: nil)
        // 布尔属性拿到 undefined 也当"算不出"，保持静态值，不该崩
        _ = try renderer.renderImage(width: 100, height: 50, time: 0)
    }
}
