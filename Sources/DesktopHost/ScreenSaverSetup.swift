import AppKit

/// 壁坞的屏幕保护程序（`WallPort.saver`，源码在 Sources/WallPortSaver）：装到 `~/Library/Screen Savers`，
/// 以及读出系统现在用的是哪个屏保。
///
/// 电脑空闲时系统启动的是屏幕保护程序，和桌面壁纸分开设置（默认是系统自带壁纸的动画），锁屏叠在它上面，
/// 所以系统壁纸同步成当前画面也挡不住空闲、唤醒时露出自带壁纸。壁坞的屏保显示的是同步下来的当前画面。
/// 系统没有公开接口替用户选屏保，所以只装好、打开系统设置的「屏幕保护程序」，由用户选「壁坞」。
/// 装在那里的是一份拷贝，App 更新以后不会自己变，启动时比一下、不一样就换掉（`updateIfInstalled`）
@MainActor
public enum ScreenSaverSetup {
    public nonisolated static let bundleName = "WallPort.saver"

    /// App 里带的那份（scripts/build-app.sh、release.sh 放进去的）；直接 `swift run` 跑的没有
    public static var bundled: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Screen Savers/\(bundleName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 装到这里：只给当前用户，不用管理员密码
    public nonisolated static var installed: URL {
        AppFolder.userHome.appendingPathComponent("Library/Screen Savers/\(bundleName)", isDirectory: true)
    }

    /// 系统设置里的「屏幕保护程序」
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!

    /// 系统现在选的屏保模块（`com.apple.screensaver` 当前主机设置里的 `moduleDict`），例如
    /// `/System/Library/ExtensionKit/Extensions/Ventura.appex`。没选过时是 nil
    public static var selectedModulePath: String? {
        let value = CFPreferencesCopyValue(
            "moduleDict" as CFString, "com.apple.screensaver" as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (value as? [String: Any])?["path"] as? String
    }

    /// 选的是不是壁坞的屏保
    public static func isSelected(modulePath: String? = selectedModulePath) -> Bool {
        modulePath.map { URL(fileURLWithPath: $0).lastPathComponent == bundleName } ?? false
    }

    /// 装上，已经装过的换成 `source` 这一份。先拷到旁边再换过去：换到一半失败也不会把装好的那份弄坏
    public static func install(from source: URL, to destination: URL = installed) throws {
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".\(destination.lastPathComponent).new", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    /// 装过、而且和 `source` 不一样（App 更新了）就换掉；返回换没换。没装过的不装：装不装由用户决定
    @discardableResult
    public static func updateIfInstalled(from source: URL, to destination: URL = installed) throws -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path),
              !FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path)
        else { return false }
        try install(from: source, to: destination)
        return true
    }
}
