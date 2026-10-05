import Foundation
import Testing
@testable import WallpaperLibrary

@Suite struct LibraryScannerTests {
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryScannerTests-\(UUID().uuidString)")
        func project(_ name: String, _ json: String) throws {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        }
        try project("b", #"{"title": "乙 壁纸", "type": "video", "file": "a.mp4"}"#)
        try project("a", #"{"title": "甲 壁纸", "type": "scene", "file": "scene.json"}"#)
        try project("broken", "不是 JSON")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("loose.txt"))
        return root
    }

    @Test func scansProjectFoldersAndSkipsTheRest() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = LibraryScanner.scan(folders: [root])
        #expect(projects.map(\.title) == ["甲 壁纸", "乙 壁纸"])
        #expect(projects.map(\.kind) == [.scene, .video])
        // 同一个文件夹列两次不会重复；文件夹本身是项目时也算
        #expect(LibraryScanner.scan(folders: [root, root]).count == 2)
        #expect(LibraryScanner.scan(folders: [root.appendingPathComponent("a")]).map(\.title) == ["甲 壁纸"])
    }

    @Test func foldersArePersistedWithAFallback() throws {
        let defaults = try #require(UserDefaults(suiteName: "LibraryScannerTests-\(UUID().uuidString)"))
        let fallback = FileManager.default.temporaryDirectory
        let store = LibraryFolderStore(defaults: defaults, fallback: fallback)
        #expect(store.folders.map(\.standardizedFileURL.path) == [fallback.standardizedFileURL.path])
        let other = URL(fileURLWithPath: "/tmp/其它壁纸", isDirectory: true)
        store.add(other)
        store.add(other)
        #expect(store.folders.count == 2)
        store.remove(fallback)
        #expect(store.folders.map(\.path) == [other.standardizedFileURL.path])
    }
}
