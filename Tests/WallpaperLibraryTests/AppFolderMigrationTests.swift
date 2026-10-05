import Foundation
import Testing
@testable import WallpaperLibrary

/// 散在各处的东西挪进统一文件夹：设置、创意工坊下载、WE 自带素材、登录会话、缓存、日志；SteamCMD 旧程序拿走
@Suite struct AppFolderMigrationTests {
    private struct Sandbox {
        let home: URL
        let root: URL
        let settings: UserDefaults
        let old: UserDefaults
        let names: [String]
        var legacy: AppFolderMigration.Legacy { .init(home: home) }

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("AppFolderMigration-\(UUID().uuidString)")
            root = home.appendingPathComponent("WallPort")
            names = ["AppFolderMigrationTests-new-\(UUID().uuidString)", "AppFolderMigrationTests-old-\(UUID().uuidString)"]
            settings = try #require(UserDefaults(suiteName: names[0]))
            old = try #require(UserDefaults(suiteName: names[1]))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: home)
            for name in names { UserDefaults.standard.removePersistentDomain(forName: name) }
        }

        func file(_ path: String, _ text: String = "x") throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path) }

        func run(discard: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> AppFolderMigration.Result {
            AppFolderMigration.run(
                legacy: legacy, root: root, settings: settings, oldSettings: old, oldDomain: names[1], discard: discard)
        }
    }

    @Test func movesEverythingIntoTheFolder() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let support = "Library/Application Support/MacWallpaper"
        let steamCMDItems = "\(support)/SteamCMD/steamapps/workshop/content/431960"
        let steamWE = "Library/Application Support/Steam/steamapps/workshop/content/431960"
        try box.file("\(steamCMDItems)/3785217256/project.json")
        try box.file("\(steamCMDItems)/2078793128/project.json")
        try box.file("\(support)/SteamCMD/steamcmd.sh")
        try box.file("\(support)/Workshop/3807085665/project.json")
        try box.file("\(steamWE)/3144420683/project.json")
        try box.file("\(support)/steam-session.json", "{}")
        try box.file("\(support)/project-details.json", "{}")
        try box.file("\(support)/SystemWallpaper/1-2.jpg")
        try box.file("Library/Logs/MacWallpaper/desktop.log", "旧日志")
        try box.file("Library/Caches/MacWallpaper/Shaders/abc.metallib")
        try box.file("wp-assets/effects/shake/effect.json")
        let home = box.home.path, root = box.root.path
        box.old.set(["\(home)/\(steamWE)", "\(home)/\(steamCMDItems)", "\(home)/wp"], forKey: "libraryFolders")
        box.old.set(["A": "project:\(home)/\(steamCMDItems)/3785217256"], forKey: "displayAssignments")
        box.old.set(["\(home)/\(steamWE)/3144420683": ["effect:shake"]], forKey: "hiddenSceneElements")
        box.old.set(["\(home)/\(support)/Workshop/3807085665": ["posechoice": 2]], forKey: "userPropertyOverrides")
        box.old.set(["maximumFrameRate": 60], forKey: "performanceSettings")
        box.old.set("{0, 0, 900, 600}", forKey: "NSWindow Frame LibraryWindowWithSettings")

        var discarded: [String] = []
        let result = box.run {
            discarded.append($0.lastPathComponent)
            try FileManager.default.removeItem(at: $0)
        }
        #expect(result.workshopMoved == 4 && result.workshopKept.isEmpty && result.removedSteamCMD)
        #expect(result.settingsCopied == 5, "NS 开头的留给系统")
        #expect(discarded == ["SteamCMD"])
        for id in ["3785217256", "2078793128", "3807085665", "3144420683"] {
            #expect(box.exists("WallPort/Workshop/\(id)/project.json"), "\(id)")
        }
        #expect(box.exists("WallPort/Assets/effects/shake/effect.json") && !box.exists("wp-assets"))
        #expect(box.exists("WallPort/Data/steam-session.json") && box.exists("WallPort/Data/project-details.json"))
        #expect(box.exists("WallPort/Data/SystemWallpaper/1-2.jpg"))
        #expect(box.exists("WallPort/Logs/desktop.log") && box.exists("WallPort/Cache/Shaders/abc.metallib"))
        #expect(!box.exists("\(support)/SteamCMD"))

        // 设置搬过来了，路径都换成统一文件夹里的；原处只剩系统自己记的
        #expect(box.settings.stringArray(forKey: "libraryFolders") == ["\(root)/Workshop", "\(home)/wp"])
        #expect(box.settings.dictionary(forKey: "displayAssignments") as? [String: String]
            == ["A": "project:\(root)/Workshop/3785217256"])
        #expect(box.settings.dictionary(forKey: "hiddenSceneElements") as? [String: [String]]
            == ["\(root)/Workshop/3144420683": ["effect:shake"]])
        #expect(box.settings.dictionary(forKey: "userPropertyOverrides")?["\(root)/Workshop/3807085665"] != nil)
        #expect(box.settings.dictionary(forKey: "performanceSettings")?["maximumFrameRate"] as? Int == 60)
        #expect(box.settings.object(forKey: "weAssetsDirectory") == nil)
        #expect(Set(box.old.persistentDomain(forName: box.names[1])?.keys.map { $0 } ?? []) == ["NSWindow Frame LibraryWindowWithSettings"])

        // 再启动一次：没有旧东西了
        #expect(box.run().isEmpty)
    }

    /// 统一文件夹里已经有同一个编号：旧的留在原处，SteamCMD 文件夹不动；设置里另外指定的素材目录也不动
    @Test func leavesConflictsAndCustomAssetsAlone() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let steamCMDItems = "Library/Application Support/MacWallpaper/SteamCMD/steamapps/workshop/content/431960"
        try box.file("\(steamCMDItems)/3785217256/project.json")
        try box.file("WallPort/Workshop/3785217256/project.json")
        try box.file("External/WE/assets/effects/x.json")
        try box.file("wp-assets/effects/y.json")
        let custom = box.home.appendingPathComponent("External/WE/assets").path
        box.old.set(custom, forKey: "weAssetsDirectory")
        box.old.set(["\(box.home.path)/\(steamCMDItems)"], forKey: "libraryFolders")
        let result = box.run { _ in Issue.record("旧目录里还有条目，不该拿走 SteamCMD 文件夹") }
        #expect(result.workshopMoved == 0 && result.workshopKept == ["3785217256"] && !result.removedSteamCMD)
        #expect(box.exists("\(steamCMDItems)/3785217256/project.json"))
        // 旧目录里只剩统一文件夹里也有的：壁纸库改指统一文件夹，不再同时列出两份
        #expect(box.settings.stringArray(forKey: "libraryFolders") == ["\(box.root.path)/Workshop"])
        #expect(box.settings.string(forKey: "weAssetsDirectory") == custom)
        #expect(box.exists("External/WE/assets/effects/x.json") && box.exists("wp-assets/effects/y.json"))
        #expect(!box.exists("WallPort/Assets"))
    }
}
