import Foundation
import Testing
@testable import WallpaperLibrary

/// 照真实 project.json 的写法手写一组属性
private let projectJSON = """
{"title": "测试", "type": "scene", "file": "scene.json", "general": {"properties": {
    "schemecolor": {"order": 0, "text": "ui_browse_properties_scheme_color", "type": "color", "value": "0.5 0.4 0.6"},
    "look": {"order": 1, "text": "<b>外观</b>", "type": "group", "value": ""},
    "show": {"order": 2, "text": "显示时钟", "type": "bool", "value": false},
    "size": {"order": 3, "text": "字号", "type": "slider", "min": 10, "max": 100, "fraction": false, "value": 30,
             "condition": "show.value"},
    "wallpaper": {"order": 4, "text": "选择壁纸", "type": "combo", "value": "1",
                  "options": [{"label": "第一张", "value": "1"}, {"label": "第二张", "value": "2"}]},
    "note": {"order": 5, "text": "<center>如果喜欢&nbsp;请点赞</center>", "condition": "hide.value==false"},
    "hide": {"order": 6, "text": "隐藏说明", "type": "bool", "value": false},
    "bgm": {"order": 7, "text": "背景音乐", "type": "file", "value": ""}
}}}
"""

private func project() throws -> WallpaperProject {
    try WallpaperProject(folder: URL(fileURLWithPath: "/tmp/测试项目"), projectJSON: Data(projectJSON.utf8))
}

@Suite struct UserPropertyTests {
    @Test func propertiesAreParsedInOrder() throws {
        let properties = try project().properties
        #expect(properties.map(\.name) == ["schemecolor", "look", "show", "size", "wallpaper", "note", "hide", "bgm"])
        #expect(properties[0].label == "方案颜色")
        #expect(properties[1].kind == .group && properties[1].label == "外观")
        let size = properties[3]
        #expect(size.kind == .slider && size.isInteger && size.minimum == 10 && size.maximum == 100)
        #expect(size.defaultValue == .number(30))
        #expect(properties[4].options.map(\.label) == ["第一张", "第二张"])
        #expect(properties[5].kind == .text && properties[5].label == "如果喜欢 请点赞")
        #expect(!properties[7].isEditable)
        #expect(properties[2].defaultValue == .bool(false))
    }

    @Test func conditionsFollowOtherValues() {
        let off: [String: PropertyValue] = ["show": .bool(false), "hide": .bool(false), "wallpaper": .string("2")]
        #expect(!UserProperty.conditionHolds("show.value", values: off))
        #expect(UserProperty.conditionHolds("!show.value", values: off))
        #expect(UserProperty.conditionHolds("hide.value==false", values: off))
        #expect(UserProperty.conditionHolds("wallpaper.value == '2'", values: off))
        #expect(UserProperty.conditionHolds("wallpaper.value==2", values: off))
        #expect(!UserProperty.conditionHolds("wallpaper.value!=2", values: off))
        #expect(UserProperty.conditionHolds("show.value || hide.value==false", values: off))
        #expect(!UserProperty.conditionHolds("show.value && hide.value==false", values: off))
        // 认不出来的条件按显示处理
        #expect(UserProperty.conditionHolds("somethingElse(1)", values: off))
        #expect(UserProperty.conditionHolds(nil, values: off))
    }

    @Test func overridesArePersistedPerProject() throws {
        let defaults = try #require(UserDefaults(suiteName: "UserPropertyTests-\(UUID().uuidString)"))
        let store = UserPropertyStore(defaults: defaults)
        let folder = URL(fileURLWithPath: "/tmp/a")
        store.set(.bool(true), for: "show", in: folder)
        store.set(.number(42), for: "size", in: folder)
        store.set(.string("x"), for: "other", in: URL(fileURLWithPath: "/tmp/b"))
        #expect(store.overrides(for: folder) == ["show": .bool(true), "size": .number(42)])
        // 重新打开（同一份 UserDefaults）还在
        #expect(UserPropertyStore(defaults: defaults).overrides(for: folder)["show"] == .bool(true))
        store.set(nil, for: "size", in: folder)
        #expect(store.overrides(for: folder) == ["show": .bool(true)])
        store.reset(folder)
        #expect(store.overrides(for: folder).isEmpty)
        #expect(store.overrides(for: URL(fileURLWithPath: "/tmp/b")) == ["other": .string("x")])
    }

    @Test func valuesMergeDefaultsAndOverrides() throws {
        let project = try project()
        let values = project.propertyValues(overrides: ["show": .bool(true)])
        #expect(values["show"] == .bool(true))
        #expect(values["size"] == .number(30))
        let json = try #require(project.propertyValuesJSON(overrides: ["size": .number(50)]))
        let decoded = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(decoded["size"] as? Double == 50)
        #expect(decoded["wallpaper"] as? String == "1")
    }

    @Test func webPropertiesKeepTheirShapeWithNewValues() throws {
        let project = try project()
        let json = try #require(project.userPropertiesJSON(overrides: ["show": .bool(true)]))
        let decoded = try #require(try JSONSerialization.jsonObject(with: json) as? [String: [String: Any]])
        #expect(decoded["show"]?["value"] as? Bool == true)
        #expect(decoded["show"]?["type"] as? String == "bool")
        #expect(decoded["size"]?["value"] as? Double == 30)
        let change = try #require(project.userPropertyChangeJSON(name: "wallpaper", value: .string("2")))
        let changed = try #require(try JSONSerialization.jsonObject(with: change) as? [String: [String: Any]])
        #expect(changed.keys.sorted() == ["wallpaper"])
        #expect(changed["wallpaper"]?["value"] as? String == "2")
    }

    @Test func booleansAreNotMistakenForNumbers() throws {
        let values = try #require(try JSONSerialization.jsonObject(with: Data(#"{"a": true, "b": 1, "c": 1.5}"#.utf8)) as? [String: Any])
        #expect(PropertyValue(json: values["a"]) == .bool(true))
        #expect(PropertyValue(json: values["b"]) == .number(1))
        #expect(PropertyValue(json: values["c"])?.conditionText == "1.5")
        #expect(PropertyValue.number(2).conditionText == "2")
    }
}
