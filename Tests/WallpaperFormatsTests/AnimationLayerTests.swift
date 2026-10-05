import Foundation
import Testing
@testable import WallpaperFormats

/// 动画层的 visible 上挂着脚本的例子（按 Lucy 场景的写法手写，不含 WE 内容）
@Suite struct AnimationLayerTests {
    private let json = #"""
    {"general": {}, "objects": [{"id": 1, "image": "models/puppet.json", "animationlayers": [
      {"animation": 3, "blend": 1, "rate": 1, "additive": true,
       "visible": {"script": "export function init(value) { shared.offsetedStartAni(thisObject.getAnimation(), scriptProperties.percentage); return value; }",
                   "scriptproperties": {"percentage": 0.4}, "value": true}},
      {"animation": 5, "blend": 0.5, "rate": 2, "additive": false, "visible": true},
      {"animation": 7, "blend": 1, "rate": 1, "additive": true,
       "visible": {"script": "export function init(value) { return scriptProperties.percentage > 0.5; }",
                   "scriptproperties": {"percentage": 0.9}, "value": true}}
    ]}]}
    """#

    @Test func readsLayersAndTheirStartProgress() throws {
        let layers = try SceneDescription(json: Data(json.utf8)).objects[0].animationLayers
        #expect(layers.count == 3)
        #expect(layers[0].animation == 3)
        #expect(layers[0].blend == 1)
        #expect(layers[0].rate == 1)
        #expect(layers[0].additive)
        #expect(layers[0].isVisible)
        // shared.offsetedStartAni 的 scriptproperties.percentage
        #expect(layers[0].startProgress == 0.4)
        // 没有脚本的层从头开始播
        #expect(layers[1].startProgress == 0)
        #expect(layers[1].blend == 0.5 && layers[1].rate == 2 && !layers[1].additive)
        // 别的脚本就算也带 percentage，也不当成起始进度
        #expect(layers[2].startProgress == 0)
    }

    @Test func startProgressIsClampedToZeroToOne() {
        let script = #"{"script": "shared.offsetedStartAni(x, scriptProperties.percentage)", "scriptproperties": {"percentage": 2.5}}"#
        #expect(SceneDescription.startProgress(try? JSONSerialization.jsonObject(with: Data(script.utf8))) == 1)
        #expect(SceneDescription.startProgress(nil) == 0)
        #expect(SceneDescription.startProgress(true) == 0)
    }
}
