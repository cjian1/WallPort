import Foundation

/// 壁坞的所有东西都放在一个文件夹里：`~/WallPort`（用户决定：不用到处找，不要的时候整个文件夹一起删）。
///
///     WallPort/
///       WallPort.app       软件（scripts/build-app.sh 装到这里）
///       Settings.plist     设置
///       Workshop/          创意工坊下载的壁纸（每个编号一个文件夹）
///       Assets/            Wallpaper Engine 自带素材（场景壁纸要用）
///       Data/              Steam 登录会话、壁纸详情缓存、同步给系统的壁纸截图
///       Cache/             着色器、网络缓存（删了会重建）
///       Logs/              日志
///
/// 原来散在 `~/Library/Application Support/MacWallpaper`、`~/Library/Preferences`、`~/Library/Logs`、`~/Library/Caches`、
/// `~/wp-assets` 和 Steam 的创意工坊文件夹里，App 第一次启动时由 `AppFolderMigration`（WallpaperLibrary）挪过来。
/// macOS 自己还会给每个 App 记一些东西（窗口位置、打开面板上次的位置、网页的 Cookie），放在系统的位置，删了会重建
public enum AppFolder {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WallPort", isDirectory: true)
    }

    /// 设置文件（`UserDefaults` 按路径开的，所以名字不带 .plist）
    public static var settingsPath: String { root.appendingPathComponent("Settings").path }
    public static var workshop: URL { root.appendingPathComponent("Workshop", isDirectory: true) }
    public static var assets: URL { root.appendingPathComponent("Assets", isDirectory: true) }
    public static var data: URL { root.appendingPathComponent("Data", isDirectory: true) }
    public static var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    public static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public static var shaderCache: URL { cache.appendingPathComponent("Shaders", isDirectory: true) }
    public static var systemWallpaper: URL { data.appendingPathComponent("SystemWallpaper", isDirectory: true) }

    /// App 的设置。App 启动时 `activate()` 以后存在 `Settings.plist`；命令行工具、测试里没激活，仍是 `.standard`，
    /// 碰不到用户真正的设置
    nonisolated(unsafe) public private(set) static var settings: UserDefaults = .standard
    /// 已经 `activate()`（是真正的 App 在跑）。没激活时缓存之类也不往统一文件夹里写
    nonisolated(unsafe) public private(set) static var isActive = false

    /// App 一启动就调（在建任何存储之前）：设置改存到统一文件夹，网络缓存也放进来
    public static func activate() {
        isActive = true
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let folderSettings = UserDefaults(suiteName: settingsPath) { settings = folderSettings }
        URLCache.shared = URLCache(
            memoryCapacity: 16 << 20, diskCapacity: 256 << 20, directory: cache.appendingPathComponent("Web", isDirectory: true))
    }
}
