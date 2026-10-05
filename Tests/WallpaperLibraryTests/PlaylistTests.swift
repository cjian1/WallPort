import Foundation
import Testing
@testable import WallpaperLibrary

private func project(_ folder: String, kind: String = "scene", file: String? = "scene.json") throws -> WallpaperProject {
    var json: [String: Any] = ["title": folder, "type": kind]
    if let file { json["file"] = file }
    return try WallpaperProject(
        folder: URL(fileURLWithPath: "/tmp/playlist/\(folder)", isDirectory: true),
        projectJSON: try JSONSerialization.data(withJSONObject: json))
}

@Suite struct PlaylistPickerTests {
    @Test func sequentialWrapsAroundTheList() throws {
        let projects = [try project("a"), try project("b"), try project("c")]
        var generator = SystemRandomNumberGenerator()
        let fromA = try #require(PlaylistPicker.next(
            from: projects, current: projects[0].folder, isRandom: false, using: &generator))
        #expect(fromA.title == "b")
        let fromC = try #require(PlaylistPicker.next(
            from: projects, current: projects[2].folder, isRandom: false, using: &generator))
        #expect(fromC.title == "a")
        // 当前项目不在列表里（例如手动选过别的壁纸）时从头开始
        let unknown = try #require(PlaylistPicker.next(
            from: projects, current: URL(fileURLWithPath: "/tmp/other"), isRandom: false, using: &generator))
        #expect(unknown.title == "a")
    }

    /// 删掉正在用的壁纸：换成库里排在它后面、没被一起删掉的那张；全删光了就没有
    @Test func replacementSkipsDeletedProjects() throws {
        let projects = [try project("a"), try project("b"), try project("c"), try project("d", kind: "application")]
        let b = projects[1].folder, c = projects[2].folder
        #expect(PlaylistPicker.replacement(for: b, deleting: [b], in: projects)?.title == "c")
        #expect(PlaylistPicker.replacement(for: b, deleting: [b, c], in: projects)?.title == "a", "c 也删了，绕回开头")
        #expect(PlaylistPicker.replacement(for: c, deleting: [c], in: projects)?.title == "a", "应用程序类的 d 放不了，跳过")
        #expect(PlaylistPicker.replacement(
            for: b, deleting: projects.map(\.folder), in: projects) == nil)
    }

    @Test func randomNeverPicksTheCurrentOne() throws {
        let projects = [try project("a"), try project("b"), try project("c")]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let next = try #require(PlaylistPicker.next(
                from: projects, current: projects[1].folder, isRandom: true, using: &generator))
            #expect(next.title != "b")
        }
    }

    /// 应用程序类、类型认不出来、没有入口文件的都不参与轮播
    @Test func onlyPlayableProjectsAreConsidered() throws {
        let projects = [
            try project("app", kind: "application", file: "app.exe"),
            // 认不出的类型 + 认不出的扩展名 → unknown
            try project("unknown", kind: "unknown", file: "mystery.dat"),
            try project("noentry", kind: "scene", file: nil),
            try project("video", kind: "video", file: "loop.mp4"),
            try project("web", kind: "web", file: "index.html"),
        ]
        let playable = PlaylistPicker.playable(projects).map(\.title)
        #expect(playable == ["video", "web"])

        var generator = SystemRandomNumberGenerator()
        let next = try #require(PlaylistPicker.next(from: projects, current: nil, isRandom: false, using: &generator))
        #expect(next.title == "video")
    }

    @Test func singleCandidateDoesNotRepeatItself() throws {
        let projects = [try project("only")]
        var generator = SystemRandomNumberGenerator()
        #expect(PlaylistPicker.next(from: projects, current: nil, isRandom: true, using: &generator)?.title == "only")
        #expect(PlaylistPicker.next(from: projects, current: projects[0].folder, isRandom: true, using: &generator) == nil)
    }
}

@Suite struct PlaylistSettingsTests {
    @Test func settingsRoundTripThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "PlaylistSettingsTests-\(UUID().uuidString)"))
        let store = PlaylistStore(defaults: defaults)
        #expect(store.settings == PlaylistSettings())
        store.settings = PlaylistSettings(isEnabled: true, intervalMinutes: 5, mode: .random)
        #expect(store.settings.isEnabled)
        #expect(store.settings.intervalMinutes == 5)
        #expect(store.settings.mode == .random)
        // 间隔至少 1 分钟
        #expect(PlaylistSettings(intervalMinutes: 0).intervalMinutes == 1)
    }
}
