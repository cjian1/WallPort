import Foundation
import Testing
@testable import WebWallpaper

/// 网页壁纸的目录类属性（幻灯片文件夹等）：从 general.properties 找出本机文件夹，列出交给页面的文件
@Suite struct DirectoryPropertyTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryPropertyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("预设/directories/customdirectory/子目录"), withIntermediateDirectories: true)
    }

    private func write(_ path: String) throws {
        try Data("x".utf8).write(to: root.appendingPathComponent(path))
    }

    /// 依赖型预设把幻灯片文件夹打包成自己的 directories/<属性名>，值是相对路径，相对于预设自己的文件夹
    @Test func relativeValuesResolveAgainstThePropertyFolder() throws {
        let json = #"""
        {"customdirectory":{"type":"directory","mode":"fetchall","value":"directories/customdirectory"},
         "random":{"type":"directory","mode":"ondemand","value":"directories/customdirectory"},
         "wallpapermode":{"type":"combo","value":2}}
        """#
        let properties = WebContent.directoryProperties(in: json, relativeTo: root.appendingPathComponent("预设"))
        let folder = root.appendingPathComponent("预设/directories/customdirectory", isDirectory: true).standardizedFileURL
        #expect(properties == [
            .init(name: "customdirectory", fetchesAll: true, folder: folder),
            .init(name: "random", fetchesAll: false, folder: folder),
        ])
    }

    /// 作者电脑上的 Windows 路径、空值、不存在的文件夹、指向文件的值都不算
    @Test func unusableValuesAreSkipped() throws {
        try write("预设/directories/customdirectory/0001.jpg")
        let file = root.appendingPathComponent("预设/directories/customdirectory/0001.jpg").path
        let json = """
        {"windows":{"type":"directory","value":"C:/Users/someone/Pictures"},
         "backslash":{"type":"directory","value":"directories\\\\customdirectory"},
         "empty":{"type":"directory","value":""},
         "missing":{"type":"directory","value":"directories/none"},
         "file":{"type":"directory","value":"\(file)"},
         "absolute":{"type":"directory","value":"\(root.appendingPathComponent("预设/directories").path)"}}
        """
        let properties = WebContent.directoryProperties(in: json, relativeTo: root)
        #expect(properties.map(\.name) == ["absolute"])
    }

    /// 文件按自然顺序（2 在 10 前面），含子文件夹；访达的 .DS_Store、Windows 的 Thumbs.db 不给页面。
    /// 路径不带开头的 "/"：页面照 WE 的写法拼 'file:///' + 路径正好是这个文件
    @Test func filesAreListedInNaturalOrderWithoutJunk() throws {
        let folder = root.appendingPathComponent("预设/directories/customdirectory", isDirectory: true)
        for name in ["10.jpg", "2.jpg", "1.jpg", ".DS_Store", "Thumbs.db", "子目录/3.png"] {
            try write("预设/directories/customdirectory/" + name)
        }
        let files = WebContent.files(in: folder)
        let base = String(folder.standardizedFileURL.path.dropFirst()) + "/"
        #expect(files == ["1.jpg", "2.jpg", "10.jpg", "子目录/3.png"].map { base + $0 })
        #expect(files.allSatisfy { !$0.hasPrefix("/") })
        #expect(WebContent.files(in: folder, limit: 2).count == 2)
    }
}
