import Foundation
import Testing
@testable import WallpaperLibrary

/// 依赖型网页预设的幻灯片图片：目录类属性的显示条件成立时才算（"完美壁纸"只在幻灯片模式下用这个文件夹），
/// 相对路径相对于预设自己的文件夹，只要图片
@Suite struct SlideshowImagesTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlideshowImagesTests-\(UUID().uuidString)", isDirectory: true)
        let base = root.appendingPathComponent("884307090", isDirectory: true)
        let preset = root.appendingPathComponent("3826301865", isDirectory: true)
        let slides = preset.appendingPathComponent("directories/customdirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        try Data("<html>".utf8).write(to: base.appendingPathComponent("index.html"))
        try Data(#"""
        {"title":"Base","type":"web","file":"index.html","general":{"properties":{
          "wallpapermode":{"type":"combo","value":1,"options":[{"label":"单张","value":1},{"label":"幻灯片","value":2}]},
          "customdirectory":{"type":"directory","mode":"fetchall","condition":"wallpapermode.value == 2"}}}}
        """#.utf8).write(to: base.appendingPathComponent("project.json"))
        try Data(#"""
        {"title":"Preset","dependency":"884307090",
         "preset":{"wallpapermode":2,"customdirectory":"directories/customdirectory"}}
        """#.utf8).write(to: preset.appendingPathComponent("project.json"))
        for name in ["10.jpg", "2.JPG", "1.png", "说明.txt", ".DS_Store"] {
            try Data("x".utf8).write(to: slides.appendingPathComponent(name))
        }
    }

    private func preset() throws -> WallpaperProject {
        try WallpaperProject(folder: root.appendingPathComponent("3826301865", isDirectory: true))
            .resolvingDependency(in: [root])
    }

    @Test func presetInSlideModeListsItsImagesInNaturalOrder() throws {
        let images = try preset().slideshowImages()
        #expect(images.map(\.lastPathComponent) == ["1.png", "2.JPG", "10.jpg"])
    }

    /// 用户把模式改回单张：文件夹的显示条件不成立，就不是幻灯片（按网页原样放）
    @Test func folderIsIgnoredWhenItsConditionFails() throws {
        #expect(try preset().slideshowImages(overrides: ["wallpapermode": .number(1)]).isEmpty)
    }

    /// 基础项目自己没有选文件夹、还没接上基础项目的预设，都不是幻灯片
    @Test func projectsWithoutAFolderAreNotSlideshows() throws {
        let base = try WallpaperProject(folder: root.appendingPathComponent("884307090", isDirectory: true))
        #expect(base.slideshowImages(overrides: ["wallpapermode": .number(2)]).isEmpty)
        let unresolved = try WallpaperProject(folder: root.appendingPathComponent("3826301865", isDirectory: true))
        #expect(unresolved.slideshowImages().isEmpty)
    }
}
