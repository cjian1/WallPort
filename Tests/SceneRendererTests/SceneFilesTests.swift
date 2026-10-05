import Foundation
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 按 scene.pkg 的结构把文件打成包
private func package(_ files: [String: Data]) throws -> ScenePackage {
    var header = Data()
    func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
    u32(8)
    header += Data("PKGV0001".utf8)
    u32(files.count)
    var body = Data()
    for (name, data) in files.sorted(by: { $0.key < $1.key }) {
        u32(name.utf8.count)
        header += Data(name.utf8)
        u32(body.count)
        u32(data.count)
        body += data
    }
    return try ScenePackage(data: header + body)
}

@Suite struct SceneFilesTests {
    /// 查找顺序：包里的原路径 → 自带素材（原路径、特效文件夹）→ 最后才在包里按"顶层目录 + 文件名"兜底。
    /// 兜底放在前面的话，引用自带特效的文件会先撞上包里同名的工作坊文件
    @Test func builtInEffectFilesWinOverSameNamedWorkshopFiles() throws {
        let assets = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneFilesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: assets) }
        let effectFolder = assets.appendingPathComponent("effects/blur/materials/effects", isDirectory: true)
        try FileManager.default.createDirectory(at: effectFolder, withIntermediateDirectories: true)
        try Data("自带".utf8).write(to: effectFolder.appendingPathComponent("blur.json"))

        let files = SceneFiles(package: try package([
            "materials/workshop/123/effects/blur.json": Data("工作坊".utf8),
            "models/workshop/456/bar.json": Data("柱子".utf8),
        ]), assets: assets)
        #expect(files.text("materials/effects/blur.json") == "自带")
        // 包里原路径找不到、自带素材里也没有：按文件名在包里找到作者打包后挪进 workshop 子目录的那份
        #expect(files.text("models/bar.json") == "柱子")
        #expect(files.text("models/none.json") == nil)
    }

    /// 作者本机的 `../<项目文件夹>/particles/x.json` 在包里是 `particles/x.json`；
    /// 带 `..` 的路径绝不能拼到素材目录外面去（`<素材目录>/..` 就是用户主目录）
    @Test func parentFolderPathsResolveInsideThePackageOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneFilesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        // 素材目录旁边放一个"不该被读到"的文件
        let outside = root.appendingPathComponent("secret/particles", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("外面".utf8).write(to: outside.appendingPathComponent("p.json"))

        let files = SceneFiles(package: try package(["particles/new.json": Data("包里".utf8)]), assets: assets)
        #expect(files.text("../作者的项目/particles/new.json") == "包里")
        #expect(files.text("../secret/particles/p.json") == nil)
        #expect(SceneFiles.withoutParentFolder("../proj/particles/a.json") == "particles/a.json")
        #expect(SceneFiles.withoutParentFolder("particles/a.json") == nil)
        #expect(SceneFiles.withoutParentFolder("../a.json") == nil)
    }
}
