import Foundation
import Testing
@testable import WallpaperLibrary

@Suite struct WallpaperProjectTests {
    private let folder = URL(fileURLWithPath: "/tmp/项目 123", isDirectory: true)

    private func project(_ json: String) throws -> WallpaperProject {
        try WallpaperProject(folder: folder, projectJSON: Data(json.utf8))
    }

    @Test func parsesWebProjectWithUserProperties() throws {
        let parsed = try project("""
            {"title": "星空", "type": "web", "file": "index.html", "preview": "preview.jpg",
             "general": {"supportsaudioprocessing": true,
                         "properties": {"schemecolor": {"type": "color", "value": "0.1 0.2 0.3"}}}}
            """)
        #expect(parsed.title == "星空")
        #expect(parsed.kind == .web)
        #expect(parsed.entry?.path == "/tmp/项目 123/index.html")
        #expect(parsed.preview?.lastPathComponent == "preview.jpg")
        #expect(parsed.supportsAudio)

        let properties = try #require(parsed.userProperties)
        let decoded = try JSONSerialization.jsonObject(with: properties) as? [String: [String: String]]
        #expect(decoded?["schemecolor"]?["value"] == "0.1 0.2 0.3")
    }

    @Test func typeIsCaseInsensitive() throws {
        #expect(try project(#"{"type": "Video", "file": "a.mp4"}"#).kind == .video)
        #expect(try project(#"{"type": "Scene", "file": "scene.json"}"#).kind == .scene)
    }

    @Test func missingTypeIsInferredFromEntryFile() throws {
        #expect(try project(#"{"file": "index.htm"}"#).kind == .web)
        #expect(try project(#"{"file": "loop.MOV"}"#).kind == .video)
        #expect(try project(#"{"file": "scene.pkg"}"#).kind == .scene)
        #expect(try project(#"{"file": "app.exe"}"#).kind == .application)
        #expect(try project(#"{}"#).kind == .unknown)
    }

    @Test func missingTitleFallsBackToFolderName() throws {
        #expect(try project(#"{"title": "", "file": "a.mp4"}"#).title == "项目 123")
    }

    @Test func windowsStyleSubfolderPathsResolve() throws {
        #expect(try project(#"{"file": "media\\loop.mp4"}"#).entry?.path == "/tmp/项目 123/media/loop.mp4")
    }

    @Test func entryEscapingTheFolderIsRejected() {
        #expect(throws: WallpaperProject.LoadError.entryOutsideFolder("../../etc/passwd")) {
            try project(#"{"file": "../../etc/passwd"}"#)
        }
    }

    @Test func invalidJSONIsRejected() {
        #expect(throws: WallpaperProject.LoadError.invalidJSON) {
            try project("not json")
        }
    }

    @Test func projectSourceRoundTrips() {
        let source = WallpaperSource.project(folder)
        #expect(WallpaperSource(storageValue: source.storageValue) == source)
    }

    /// 预设项目自身没有入口，但保留依赖编号和预设参数。
    @Test func parsesDependencyBackedPreset() throws {
        let parsed = try project(#"""
        {"title":"预设","dependency":"884307090","preview":"preview.jpg",
         "preset":{"schemecolor":"#112233","wallpapermode":2}}
        """#)
        #expect(parsed.dependencyID == "884307090")
        #expect(parsed.kind == .unknown)
        #expect(parsed.preset != nil)
        let preset = try #require(parsed.preset.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(preset["wallpapermode"] as? Int == 2)
    }

    /// 预设计算成基础 Web 项目：内容来自依赖，身份仍属于预设文件夹，预设值覆盖基础属性。
    @Test func resolvesPresetAgainstBaseProjectAndMergesProperties() throws {
        let baseFolder = URL(fileURLWithPath: "/tmp/base/884307090", isDirectory: true)
        let base = try WallpaperProject(folder: baseFolder, projectJSON: Data(#"""
        {"title":"基础","type":"web","file":"index.html",
         "general":{"supportsaudioprocessing":true,"properties":{
           "schemecolor":{"type":"color","value":"1 1 1"},
           "wallpapermode":{"type":"slider","value":1},
           "video":{"type":"file","value":""}
         }}}
        """#.utf8))
        let preset = try project(#"""
        {"title":"预设","dependency":"884307090","preview":"preview.jpg",
         "preset":{"schemecolor":"0.1 0.2 0.3","wallpapermode":2,"video":"clips/a.mp4","ignored":true}}
        """#)

        let resolved = preset.resolved(using: base)
        #expect(resolved.folder == preset.folder)
        #expect(resolved.title == "预设")
        #expect(resolved.kind == .web)
        #expect(resolved.contentFolder == base.folder)
        #expect(resolved.entry == base.entry)
        #expect(resolved.supportsAudio)
        let properties = try #require(resolved.userProperties.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        let scheme = properties["schemecolor"] as? [String: Any]
        let mode = properties["wallpapermode"] as? [String: Any]
        let video = properties["video"] as? [String: Any]
        #expect(scheme?["value"] as? String == "0.1 0.2 0.3")
        #expect((mode?["value"] as? NSNumber)?.intValue == 2)
        #expect(video?["value"] as? String == "clips/a.mp4")
        #expect(properties["ignored"] == nil)
    }

    /// 依赖循环不能无限递归；无法解析的预设保持 unknown。
    @Test func dependencyCyclesStayUnresolved() throws {
        let a = try WallpaperProject(
            folder: URL(fileURLWithPath: "/tmp/a", isDirectory: true),
            projectJSON: Data(#"{"title":"A","dependency":"b","preset":{}}"#.utf8))
        let b = try WallpaperProject(
            folder: URL(fileURLWithPath: "/tmp/b", isDirectory: true),
            projectJSON: Data(#"{"title":"B","dependency":"a","preset":{}}"#.utf8))
        let resolved = WallpaperProject.resolvingDependencies(in: [a, b])
        #expect(resolved.map(\.kind) == [.unknown, .unknown])
    }
}
