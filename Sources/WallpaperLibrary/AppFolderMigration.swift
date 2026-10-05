import DesktopHost
import Foundation

/// 把原来散在各处的东西挪进统一文件夹（`AppFolder`，默认 `~/WallPort`）。App 启动时、建任何存储之前做；
/// 挪完就没有旧东西了，以后启动什么也不做。
///
/// - 设置：原来在 App 的偏好设置域（`~/Library/Preferences/local.macwallpaper.plist`），复制到 `Settings.plist`，
///   原处删掉复制过的键（`NS` 开头的是 macOS 自己记的窗口位置、打开面板的位置，留给系统）；
/// - 创意工坊下载：M7 时 SteamCMD 的目录结构、短暂用过的 `MacWallpaper/Workshop`、Steam 的 WE 文件夹，
///   逐个挪进 `Workshop/`（同一个磁盘上只是改名）；统一文件夹里已经有同一个编号时旧的不动；
/// - WE 自带素材（默认的 `~/wp-assets`）挪进 `Assets/`；设置里另外指定过目录的不动；
/// - 登录会话、壁纸详情缓存、同步给系统的壁纸截图挪进 `Data/`；日志挪进 `Logs/`；着色器缓存挪进 `Cache/`；
/// - 设置里记着这些旧路径的地方（壁纸库文件夹、每块屏幕的壁纸、关掉的场景内容、改过的属性值）一起改；
/// - 挪完以后 SteamCMD 文件夹里只剩 M7 时装的 SteamCMD 程序和缓存（用不上），整个移到废纸篓
public enum AppFolderMigration {
    public struct Result: Equatable, Sendable {
        /// 从偏好设置复制过来的设置项数
        public var settingsCopied = 0
        /// 挪进 Workshop 的创意工坊条目数
        public var workshopMoved = 0
        /// 统一文件夹里已经有、留在原处的编号
        public var workshopKept: [String] = []
        /// 挪过来的其它东西（给日志看）
        public var moved: [String] = []
        /// SteamCMD 文件夹移走了
        public var removedSteamCMD = false

        public var isEmpty: Bool {
            settingsCopied == 0 && workshopMoved == 0 && workshopKept.isEmpty && moved.isEmpty && !removedSteamCMD
        }
    }

    /// 旧位置（都在 `home` 里；测试里换成临时目录）
    public struct Legacy {
        public let home: URL
        public init(home: URL) { self.home = home }

        var support: URL { home.appendingPathComponent("Library/Application Support/MacWallpaper", isDirectory: true) }
        var steamCMD: URL { support.appendingPathComponent("SteamCMD", isDirectory: true) }
        var logs: URL { home.appendingPathComponent("Library/Logs/MacWallpaper", isDirectory: true) }
        var shaderCache: URL { home.appendingPathComponent("Library/Caches/MacWallpaper/Shaders", isDirectory: true) }
        var assets: URL { home.appendingPathComponent("wp-assets", isDirectory: true) }

        /// 以前放创意工坊下载的地方
        public var workshopDirectories: [URL] {
            [steamCMD.appendingPathComponent("steamapps/workshop/content/\(Workshop.appID)", isDirectory: true),
             support.appendingPathComponent("Workshop", isDirectory: true),
             home.appendingPathComponent(
                "Library/Application Support/Steam/steamapps/workshop/content/\(Workshop.appID)", isDirectory: true)]
        }
    }

    /// 迁过设置的记号（写在新的设置里）
    static let migratedKey = "migratedToAppFolder"
    static let assetsKey = "weAssetsDirectory"

    /// - Parameters:
    ///   - root: 统一文件夹
    ///   - settings: 新的设置（`AppFolder.settings`）
    ///   - oldSettings / oldDomain: 原来的偏好设置和它的域名（App 里是 `.standard` 和 Bundle ID）
    ///   - discard: 把用不上的 SteamCMD 文件夹拿走（App 里移到废纸篓，测试里直接删）
    public static func run(
        legacy: Legacy, root: URL, settings: UserDefaults, oldSettings: UserDefaults, oldDomain: String,
        fileManager: FileManager = .default, discard: (URL) throws -> Void
    ) -> Result {
        var result = Result()
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // 1. 设置（只做一次）
        if !settings.bool(forKey: migratedKey) {
            let old = oldSettings.persistentDomain(forName: oldDomain) ?? [:]
            let keys = old.keys.filter { !$0.hasPrefix("NS") && !$0.hasPrefix("Apple") && $0 != migratedKey }
            for key in keys where settings.object(forKey: key) == nil { settings.set(old[key], forKey: key) }
            settings.set(true, forKey: migratedKey)
            for key in keys { oldSettings.removeObject(forKey: key) }
            result.settingsCopied = keys.count
        }

        // 2. 创意工坊下载
        let workshop = root.appendingPathComponent("Workshop", isDirectory: true)
        for source in legacy.workshopDirectories where source.standardizedFileURL != workshop.standardizedFileURL {
            let children = (try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
            var moved = 0
            for child in children where Workshop.isItemID(child.lastPathComponent) {
                let target = workshop.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                if fileManager.fileExists(atPath: target.path) {
                    result.workshopKept.append(child.lastPathComponent)
                    continue
                }
                do {
                    try fileManager.createDirectory(at: workshop, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: child, to: target)
                    moved += 1
                } catch {
                    result.workshopKept.append(child.lastPathComponent)
                }
            }
            result.workshopMoved += moved
            // 旧目录里没有条目了、或者剩下的统一文件夹里都有（留在原处的重复）：设置里指着它的都换成新目录，
            // 不然壁纸库会同时列出旧目录，同一张壁纸出现两份
            if moved > 0
                || Workshop.localItemIDs(in: [source]).isSubset(of: Workshop.localItemIDs(in: [workshop])) {
                rewritePaths(from: source, to: workshop, in: settings)
            }
        }

        // 3. WE 自带素材：默认的 ~/wp-assets 挪进来；用户在设置里另外指定的目录（比如外接盘上 WE 的安装目录）不动
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        let configured = settings.string(forKey: assetsKey).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        if configured == nil || configured == legacy.assets.standardizedFileURL {
            if move(legacy.assets, to: assets, fileManager: fileManager) { result.moved.append("WE 自带素材 ~/wp-assets") }
            if fileManager.fileExists(atPath: assets.path) { settings.removeObject(forKey: assetsKey) }
        }

        // 4. 数据、日志、缓存
        let data = root.appendingPathComponent("Data", isDirectory: true)
        for name in ["steam-session.json", "project-details.json", "SystemWallpaper"] {
            let source = legacy.support.appendingPathComponent(name)
            if move(source, to: data.appendingPathComponent(name), fileManager: fileManager) { result.moved.append(name) }
        }
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        for file in (try? fileManager.contentsOfDirectory(at: legacy.logs, includingPropertiesForKeys: nil)) ?? [] {
            if move(file, to: logs.appendingPathComponent(file.lastPathComponent), fileManager: fileManager) {
                result.moved.append("日志 \(file.lastPathComponent)")
            }
        }
        if move(legacy.shaderCache, to: root.appendingPathComponent("Cache/Shaders", isDirectory: true), fileManager: fileManager) {
            result.moved.append("着色器缓存")
        }

        // 5. SteamCMD 文件夹：没有留下条目就整个拿走
        if fileManager.fileExists(atPath: legacy.steamCMD.path),
           Workshop.localItemIDs(in: [legacy.workshopDirectories[0]]).isEmpty,
           (try? discard(legacy.steamCMD)) != nil {
            result.removedSteamCMD = true
        }
        return result
    }

    /// 挪一个文件或文件夹；目的地已经有了就不动。返回挪了没有
    private static func move(_ source: URL, to target: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) else { return false }
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: target)
            return true
        } catch {
            return false
        }
    }

    /// 设置里记着的路径：旧目录（或其中的条目）换成新目录下的同一个位置
    static func rewritePaths(from old: URL, to new: URL, in defaults: UserDefaults) {
        let oldPath = old.standardizedFileURL.path, newPath = new.standardizedFileURL.path
        func rewrite(_ path: String) -> String {
            if path == oldPath { return newPath }
            guard path.hasPrefix(oldPath + "/") else { return path }
            return newPath + path.dropFirst(oldPath.count)
        }
        // 壁纸库文件夹：换掉旧目录，重复的去掉
        if let folders = defaults.stringArray(forKey: "libraryFolders") {
            var seen = Set<String>()
            defaults.set(folders.map(rewrite).filter { seen.insert($0).inserted }, forKey: "libraryFolders")
        }
        // 每块屏幕放的壁纸："project:<路径>" / "video:<路径>"
        if var assignments = defaults.dictionary(forKey: "displayAssignments") {
            for (display, value) in assignments {
                guard let value = value as? String else { continue }
                for prefix in ["project:", "video:"] where value.hasPrefix(prefix) {
                    assignments[display] = prefix + rewrite(String(value.dropFirst(prefix.count)))
                }
            }
            defaults.set(assignments, forKey: "displayAssignments")
        }
        // 按项目文件夹存的：关掉的场景内容、改过的属性值（新位置已经有记录时保留新位置的）
        for key in ["hiddenSceneElements", "userPropertyOverrides"] {
            guard let stored = defaults.dictionary(forKey: key) else { continue }
            var rewritten: [String: Any] = [:]
            for (path, value) in stored where rewrite(path) == path { rewritten[path] = value }
            for (path, value) in stored where rewrite(path) != path && rewritten[rewrite(path)] == nil {
                rewritten[rewrite(path)] = value
            }
            defaults.set(rewritten, forKey: key)
        }
    }
}
