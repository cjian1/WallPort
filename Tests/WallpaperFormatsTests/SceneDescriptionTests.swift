import Foundation
import Testing
@testable import WallpaperFormats

/// 按真实 scene.json 的写法手写的样例，不含任何 WE 内容
@Suite struct SceneDescriptionTests {
    private let json = #"""
    {
      "version": 5,
      "general": {"orthogonalprojection": {"width": 3840, "height": 2160},
                  "clearcolor": "0.70000 0.70000 0.70000", "clearenabled": true},
      "objects": [
        {"id": 1, "name": "背景", "image": "models/bg.json", "origin": "1920.00000 1080.00000 0.00000",
         "size": "3840.00000 2160.00000", "scale": "1.01000 1.00000 1.00000"},
        {"id": 2, "name": "分组", "origin": "100 200 0"},
        {"id": 3, "name": "星星", "parent": 2, "particle": "particles/star.json", "angles": "0 -0 0.013"},
        {"id": 4, "name": "吊瓶", "image": "models/bottle.json",
         "origin": {"script": "export function update(v) { return v; }", "value": "2122.5 992.8 0"},
         "alpha": {"user": "opacity", "value": 0.66}, "color": {"user": "tint", "value": "1 0.5 0"},
         "visible": {"user": "showbottle", "value": false}, "colorBlendMode": 7,
         "effects": [{"file": "effects/shake/effect.json"}, {"file": "effects/waterwaves/effect.json"}]},
        {"id": 5, "name": "文字", "text": {"value": "12:00"}},
        {"id": 6, "name": "光束", "shape": "quad"},
        {"id": 7, "name": "", "camera": "default", "path": "scripts/camera_paths.json"}
      ]
    }
    """#

    @Test func readsGeneralSettings() throws {
        let scene = try SceneDescription(json: Data(json.utf8))
        #expect(scene.version == 5)
        #expect(scene.canvasSize == SIMD2(3840, 2160))
        #expect(scene.clearColor == SIMD3(0.7, 0.7, 0.7))
        #expect(scene.clearEnabled)
    }

    @Test func classifiesObjects() throws {
        let kinds = try SceneDescription(json: Data(json.utf8)).objects.map(\.kind)
        #expect(kinds == [
            .image(model: "models/bg.json"), .group, .particle("particles/star.json"),
            .image(model: "models/bottle.json"), .text, .shape, .camera,
        ])
    }

    @Test func readsTransformsAndDefaults() throws {
        let objects = try SceneDescription(json: Data(json.utf8)).objects
        #expect(objects[0].origin == SIMD3(1920, 1080, 0))
        #expect(objects[0].size == SIMD2(3840, 2160))
        #expect(objects[0].scale == SIMD3(1.01, 1, 1))
        #expect(objects[0].isVisible && objects[0].alpha == 1 && objects[0].color == SIMD3(1, 1, 1))
        #expect(objects[2].parent == 2)
        #expect(abs(objects[2].angles.z - 0.013) < 1e-6)
        #expect(objects[1].scale == SIMD3(1, 1, 1))
    }

    @Test func unwrapsUserAndScriptedValues() throws {
        let bottle = try SceneDescription(json: Data(json.utf8)).objects[3]
        #expect(bottle.origin == SIMD3(2122.5, 992.8, 0))
        #expect(abs(bottle.alpha - 0.66) < 1e-6)
        #expect(bottle.color == SIMD3(1, 0.5, 0))
        #expect(!bottle.isVisible)
        #expect(bottle.colorBlendMode == 7)
        #expect(bottle.scriptedFields == ["origin"])
        #expect(bottle.effectFiles == ["effects/shake/effect.json", "effects/waterwaves/effect.json"])
    }

    @Test func perspectiveScenesHaveNoCanvas() throws {
        let scene = try SceneDescription(json: Data(#"{"general": {}, "objects": []}"#.utf8))
        #expect(scene.canvasSize == nil)
        #expect(scene.objects.isEmpty)
    }

    @Test func singleComponentVectorsFillAllAxes() {
        #expect(SceneValue.vector3("2") == SIMD3(2, 2, 2))
        #expect(SceneValue.vector3(1.5) == SIMD3(1.5, 1.5, 1.5))
        #expect(SceneValue.vector2("256 128") == SIMD2(256, 128))
    }

    /// 向量除了空格分隔，还有逗号分隔的写法（特效参数里很常见："0.0, 1.0"）
    @Test func commaSeparatedVectorsAreParsed() {
        #expect(SceneValue.vector2("256, 128") == SIMD2(256, 128))
        #expect(SceneValue.vector3("1, 0.5, 0") == SIMD3(1, 0.5, 0))
        #expect(SceneValue.floats("0.0, 1.0") == [0, 1])
    }
}

@Suite struct SceneEffectOverrideTests {
    @Test func readsPerPassOverrides() throws {
        let json = #"""
        {"general": {}, "objects": [{"id": 1, "image": "models/a.json", "effects": [
          {"file": "effects/shake/effect.json", "visible": {"user": "shake", "value": false},
           "passes": [{"combos": {"MASK": 1, "DIRECTION": 2}, "textures": [null, "masks/m1", null, "masks/m3"],
                       "constantshadervalues": {"speed": 2.5, "friction": "1 0.5", "bounds": {"value": "0 1"}}}]},
          {"file": "effects/waterwaves/effect.json"}
        ]}]}
        """#
        let effects = try SceneDescription(json: Data(json.utf8)).objects[0].effects
        #expect(effects.map(\.file) == ["effects/shake/effect.json", "effects/waterwaves/effect.json"])
        #expect(!effects[0].isVisible && effects[1].isVisible)
        let pass = try #require(effects[0].passes.first)
        #expect(pass.combos == ["MASK": 1, "DIRECTION": 2])
        #expect(pass.textures == [nil, "masks/m1", nil, "masks/m3"])
        #expect(pass.constants["speed"] == [2.5])
        #expect(pass.constants["friction"] == [1, 0.5])
        #expect(pass.constants["bounds"] == [0, 1])
        #expect(effects[1].passes.isEmpty)
    }
}

@Suite struct UserPropertyBindingTests {
    private let scene = """
    {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
     "objects": [
        {"id": 1, "name": "第一张", "image": "a.json", "visible": {"user": {"condition": "1", "name": "wallpaper"}, "value": true}},
        {"id": 2, "name": "第二张", "image": "b.json", "visible": {"user": {"condition": "2", "name": "wallpaper"}, "value": false}},
        {"id": 3, "name": "时钟", "image": "c.json", "alpha": {"user": "opacity", "value": 1.0},
         "color": {"user": "color", "value": "1 1 1"}, "visible": {"user": "show", "value": true},
         "effects": [{"file": "effects/x/effect.json", "passes": [{"constantshadervalues": {"speed": {"user": "speed", "value": 0.2}}}]}]},
        {"id": 4, "name": "类型不配", "image": "d.json", "alpha": {"user": "show", "value": 0.5}}
     ]}
    """

    private func parse(_ values: String) throws -> SceneDescription {
        try SceneDescription(json: Data(scene.utf8), userProperties: Data(values.utf8))
    }

    @Test func withoutValuesTheSavedValuesAreUsed() throws {
        let description = try SceneDescription(json: Data(scene.utf8))
        #expect(description.objects.map(\.isVisible) == [true, false, true, true])
        #expect(description.objects[2].alpha == 1)
    }

    @Test func directBindingsTakeThePropertyValue() throws {
        let description = try parse(#"{"opacity": 0.3, "color": "1 0 0", "show": false, "speed": 0.9}"#)
        #expect(description.objects[2].alpha == 0.3)
        #expect(description.objects[2].color == SIMD3(1, 0, 0))
        #expect(!description.objects[2].isVisible)
        #expect(description.objects[2].effects[0].passes[0].constants["speed"] == [0.9])
    }

    @Test func conditionBindingsCompareWithTheCondition() throws {
        let second = try parse(#"{"wallpaper": "2"}"#)
        #expect(second.objects.map(\.isVisible).prefix(2) == [false, true])
        // 下拉选项的值是数字时也按文字比较
        let numeric = try parse(#"{"wallpaper": 1}"#)
        #expect(numeric.objects.map(\.isVisible).prefix(2) == [true, false])
    }

    @Test func mismatchedTypesKeepTheSavedValue() throws {
        // 开关属性绑在了透明度（数值）上：WE 怎么换算不清楚，保留场景里的值
        let description = try parse(#"{"show": true}"#)
        #expect(description.objects[3].alpha == 0.5)
        // 数字写成字符串的，按数字代入
        let text = try parse(#"{"opacity": "0.25"}"#)
        #expect(text.objects[2].alpha == 0.25)
    }

    /// NaN、无穷大（坏文件里的 "nan"、1e300）当成没写：一路算下去会在转整数时让渲染崩掉
    @Test func nonFiniteNumbersCountAsMissing() {
        #expect(SceneValue.float("nan") == nil)
        #expect(SceneValue.float("inf") == nil)
        #expect(SceneValue.float(NSNumber(value: 1e300)) == nil)
        #expect(SceneValue.float("2.5") == 2.5)
        #expect(SceneValue.floats("nan nan nan").isEmpty)
        #expect(SceneValue.floats("1 1e39 0").isEmpty)
        #expect(SceneValue.floats(NSNumber(value: -1e300)).isEmpty)
        #expect(SceneValue.floats("1, 0.5") == [1, 0.5])
        #expect(SceneValue.vector3("nan 1 2") == nil)
        #expect(SceneValue.vector3("1 2 3") == SIMD3(1, 2, 3))
    }
}
