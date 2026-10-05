import Foundation
import Testing
@testable import WallpaperFormats

/// 设置面板"显示内容"：按场景内容自动列出粒子、文字、特效，关掉的就不画。夹具是手写的最小 scene.json
@Suite struct SceneElementsTests {
    private let scene = Data(#"""
    {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
     "objects": [
       {"id": 1, "name": "背景", "image": "models/bg.json",
        "effects": [{"file": "effects/shake/effect.json", "visible": true},
                    {"file": "effects/workshop/123/Simple_Audio_Bars/effect.json", "visible": {"user": "bars", "value": true}},
                    {"file": "effects/waterwaves/effect.json", "visible": false}]},
       {"id": 2, "name": "Ember", "particle": "particles/ember.json"},
       {"id": 3, "name": "Ember", "particle": "particles/ember.json"},
       {"id": 4, "name": "Snow", "particle": "particles/snow.json", "visible": false},
       {"id": 5, "name": "Clock", "text": {"value": "12:00"}, "effects": [{"file": "effects/nitro/effect.json"}]},
       {"id": 6, "name": "", "text": {"value": "日期"}, "parent": 5,
        "effects": [{"file": "effects/nitro/effect.json"}]}
     ]}
    """#.utf8)

    /// 粒子按名字合并、文字每个图层一项、特效按种类合并；作者写死成不可见的不列
    @Test func listsParticlesTextsAndEffectsGrouped() {
        let elements = SceneElements.list(sceneJSON: scene)
        #expect(elements.map(\.id) == [
            "particles:Ember", "text:5", "text:6", "effect:shake", "effect:Simple_Audio_Bars", "effect:nitro",
        ])
        #expect(elements.first { $0.id == "particles:Ember" }?.count == 2)
        #expect(elements.first { $0.id == "effect:nitro" }?.count == 2)
        #expect(elements.first { $0.id == "text:6" }?.title == "文字 6", "没名字的文字图层按编号叫")
        #expect(elements.first { $0.id == "effect:nitro" }?.title == "电光（nitro）")
        #expect(elements.first { $0.id == "effect:Simple_Audio_Bars" }?.title == "音频条（Simple Audio Bars）")
    }

    /// 关掉的内容标成不可见：同名粒子一起关、同种特效一起关，绑了属性的也照样关
    @Test func hiddenElementsBecomeInvisible() throws {
        let description = try SceneDescription(
            json: scene, userProperties: Data(#"{"bars": true}"#.utf8),
            hiddenElements: ["particles:Ember", "effect:Simple_Audio_Bars", "text:5", "effect:nitro"])
        let byID = Dictionary(uniqueKeysWithValues: description.objects.map { ($0.id, $0) })
        #expect(byID[2]?.isVisible == false && byID[3]?.isVisible == false)
        #expect(byID[5]?.isVisible == false)
        #expect(byID[6]?.isVisible == true, "子图层自己没关（渲染时跟着父图层不画）")
        #expect(byID[1]?.isVisible == true)
        let effects = try #require(byID[1]?.effects)
        #expect(effects.map(\.isVisible) == [true, false, false])
        #expect(byID[6]?.effects.map(\.isVisible) == [false])
    }

    /// 没关任何东西时和原来一样
    @Test func nothingHiddenChangesNothing() throws {
        let plain = try SceneDescription(json: scene)
        let same = try SceneDescription(json: scene, hiddenElements: [])
        #expect(plain.objects.map(\.isVisible) == same.objects.map(\.isVisible))
    }
}
