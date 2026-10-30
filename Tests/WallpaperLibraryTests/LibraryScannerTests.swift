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

    @Test func scansLooseImagesAsWallpapers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("png".utf8).write(to: root.appendingPathComponent("海边.PNG"))
        try Data("jpg".utf8).write(to: root.appendingPathComponent("森林.jpg"))

        let projects = LibraryScanner.scan(folders: [root])
        #expect(Set(projects.map(\.title)) == ["海边", "森林"])
        #expect(projects.allSatisfy { $0.kind == .image })
        #expect(projects.first { $0.title == "海边" }?.entry?.lastPathComponent == "海边.PNG")
        #expect(projects.first { $0.title == "海边" }?.preview?.lastPathComponent == "海边.PNG")
    }

    /// 同一个壁纸库里的基础项目和预设项目按编号关联，预设直接进入可播放的 Web 类型。
    @Test func scannerResolvesPresetDependencyFromTheSameLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("884307090", isDirectory: true)
        let preset = root.appendingPathComponent("3825824301", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preset, withIntermediateDirectories: true)
        try Data(#"{"title":"Base","type":"web","file":"index.html","general":{"properties":{"wallpapermode":{"type":"slider","value":1}}}}"#.utf8)
            .write(to: base.appendingPathComponent("project.json"))
        try Data(#"{"title":"Preset","dependency":"884307090","preset":{"wallpapermode":2}}"#.utf8)
            .write(to: preset.appendingPathComponent("project.json"))

        let projects = LibraryScanner.scan(folders: [root])
        let child = try #require(projects.first { $0.folder == preset })
        #expect(child.kind == .web)
        #expect(child.contentFolder == base)
        #expect(child.entry == base.appendingPathComponent("index.html"))
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
