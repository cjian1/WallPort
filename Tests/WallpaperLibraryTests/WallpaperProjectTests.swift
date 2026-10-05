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
}
