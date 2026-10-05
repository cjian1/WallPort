import Foundation
import Testing
@testable import WebWallpaper

@Suite struct ByteRangeTests {
    private let size = 1000

    private func parse(_ header: String, limit: Int = 100) -> ClosedRange<Int>? {
        ByteRange.parse(header, fileSize: size, maxLength: limit)
    }

    @Test func explicitRangeIsAnsweredAsRequested() {
        #expect(parse("bytes=0-1") == 0...1)
        #expect(parse("bytes=10-599") == 10...599)
    }

    @Test func explicitEndIsClampedToFileSize() {
        #expect(parse("bytes=900-5000") == 900...999)
    }

    @Test func openEndedRangeIsCappedAtLimit() {
        #expect(parse("bytes=0-") == 0...99)
        #expect(parse("bytes=950-") == 950...999)
    }

    @Test func suffixRangeReturnsTheTail() {
        #expect(parse("bytes=-10") == 990...999)
        #expect(parse("bytes=-5000") == 0...999)
    }

    @Test func invalidRangesAreRejected() {
        #expect(parse("bytes=1000-") == nil)
        #expect(parse("bytes=5-1") == nil)
        #expect(parse("bytes=0-1,5-6") == nil)
        #expect(parse("items=0-1") == nil)
        #expect(parse("bytes=-0") == nil)
        #expect(ByteRange.parse("bytes=0-", fileSize: 0, maxLength: 100) == nil)
    }
}

@Suite struct ProjectFileResolutionTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectFileResolutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("资源"), withIntermediateDirectories: true)
        try Data("<html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("资源/配置 1.json"))
    }

    private func resolve(_ string: String) -> String? {
        ProjectSchemeHandler.file(for: URL(string: string)!, in: folder)?.lastPathComponent
    }

    @Test func entryURLRoundTrips() throws {
        let url = try #require(ProjectSchemeHandler.url(for: "资源/配置 1.json"))
        #expect(ProjectSchemeHandler.file(for: url, in: folder)?.lastPathComponent == "配置 1.json")
    }

    @Test func filesInsideTheFolderResolve() {
        #expect(resolve("wallpaper://project/index.html") == "index.html")
    }

    /// 指向文件夹外面的符号链接不能读（否则网页能顺着它读到用户别的文件）；指向里面的、文件夹本身是链接的照常可读
    @Test func symlinksLeavingTheFolderAreRejected() throws {
        let outside = folder.deletingLastPathComponent()
            .appendingPathComponent("ProjectFileResolutionTests-secret-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let manager = FileManager.default
        try manager.createSymbolicLink(at: folder.appendingPathComponent("leak.txt"), withDestinationURL: outside)
        try manager.createSymbolicLink(
            at: folder.appendingPathComponent("home"), withDestinationURL: manager.homeDirectoryForCurrentUser)
        try manager.createSymbolicLink(
            at: folder.appendingPathComponent("别名.html"), withDestinationURL: folder.appendingPathComponent("index.html"))
        #expect(resolve("wallpaper://project/leak.txt") == nil)
        #expect(resolve("wallpaper://project/home/.zshrc") == nil)
        #expect(resolve("wallpaper://project/别名.html") == "index.html")

        // 壁纸文件夹本身是个链接
        let alias = folder.deletingLastPathComponent().appendingPathComponent("ProjectFileResolutionTests-alias-\(UUID().uuidString)")
        try manager.createSymbolicLink(at: alias, withDestinationURL: folder)
        defer { try? manager.removeItem(at: alias) }
        #expect(ProjectSchemeHandler.file(for: URL(string: "wallpaper://project/index.html")!, in: alias)?.lastPathComponent
            == "index.html")
    }

    @Test func traversalOutsideTheFolderIsRejected() {
        #expect(resolve("wallpaper://project/../../../etc/hosts") == nil)
        #expect(resolve("wallpaper://project/%2E%2E/%2E%2E/etc/hosts") == nil)
    }

    @Test func otherSchemesHostsDirectoriesAndMissingFilesAreRejected() {
        #expect(resolve("file:///etc/hosts") == nil)
        #expect(resolve("wallpaper://elsewhere/index.html") == nil)
        #expect(resolve("wallpaper://project/资源") == nil)
        #expect(resolve("wallpaper://project/") == nil)
        #expect(resolve("wallpaper://project/missing.js") == nil)
    }

    @Test func textTypesDeclareUTF8AndWasmIsExact() {
        #expect(ProjectSchemeHandler.mimeType(for: URL(fileURLWithPath: "a.html")) == "text/html; charset=utf-8")
        #expect(ProjectSchemeHandler.mimeType(for: URL(fileURLWithPath: "a.wasm")) == "application/wasm")
        #expect(ProjectSchemeHandler.mimeType(for: URL(fileURLWithPath: "a.png")) == "image/png")
    }
}
