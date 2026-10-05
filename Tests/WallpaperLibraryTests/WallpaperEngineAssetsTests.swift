import Foundation
import Testing
@testable import WallpaperLibrary

/// 导入 WE 自带素材：认得出素材文件夹（或 WE 的安装目录），拷进统一文件夹；中途失败时原来的不动
@Suite struct WallpaperEngineAssetsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEAssets-\(UUID().uuidString)")

    private func makeAssets(at folder: URL, marker: String) throws {
        for name in ["shaders", "materials", "effects"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data(marker.utf8).write(to: folder.appendingPathComponent("shaders/marker.txt"))
    }

    @Test func locatesTheAssetsFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let install = root.appendingPathComponent("wallpaper_engine")
        try makeAssets(at: install.appendingPathComponent("assets"), marker: "a")
        #expect(WallpaperEngineAssets.locate(in: install.appendingPathComponent("assets"))?.lastPathComponent == "assets")
        #expect(WallpaperEngineAssets.locate(in: install)?.lastPathComponent == "assets", "选了 WE 的安装目录也认得")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("photos/shaders"), withIntermediateDirectories: true)
        #expect(WallpaperEngineAssets.locate(in: root.appendingPathComponent("photos")) == nil, "只有 shaders 不够")
        #expect(WallpaperEngineAssets.locate(in: root) == nil)
    }

    @Test func installCopiesAndReplaces() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("usb/assets"), second = root.appendingPathComponent("usb2/assets")
        let destination = root.appendingPathComponent("WallPort/Assets")
        try makeAssets(at: first, marker: "旧")
        try makeAssets(at: second, marker: "新")
        try WallpaperEngineAssets.install(from: first, to: destination)
        #expect(try String(contentsOf: destination.appendingPathComponent("shaders/marker.txt"), encoding: .utf8) == "旧")
        #expect(FileManager.default.fileExists(atPath: first.path), "是拷贝，原来的还在")
        try WallpaperEngineAssets.install(from: second, to: destination)
        #expect(try String(contentsOf: destination.appendingPathComponent("shaders/marker.txt"), encoding: .utf8) == "新")
        // 拷的过程中失败（源不存在）：原来的不动，临时文件夹不留
        #expect(throws: (any Error).self) {
            try WallpaperEngineAssets.install(from: root.appendingPathComponent("missing"), to: destination)
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("shaders/marker.txt"), encoding: .utf8) == "新")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(leftovers == ["Assets"])
        // 选的就是统一文件夹里那份：什么也不做
        try WallpaperEngineAssets.install(from: destination, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("shaders/marker.txt").path))
    }
}
