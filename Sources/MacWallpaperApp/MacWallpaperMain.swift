import AppKit
import DesktopHost
import WallpaperLibrary

@main
enum MacWallpaperMain {
    @MainActor
    static func main() {
        prepareAppFolder()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 菜单栏应用：不占 Dock。打包后 Info.plist 里的 LSUIElement 也会生效，直接 swift run 时靠这一行
        app.setActivationPolicy(.accessory)
        // NSApplication.delegate 是弱引用，必须保证 delegate 活过整个运行循环
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

extension MacWallpaperMain {
    /// 统一文件夹（`AppFolder`）：设置改存进去，旧位置的东西挪进来，写一份说明。要在建 AppDelegate 之前做——
    /// 它一建好就读设置、开日志、建各种存储
    @MainActor
    static func prepareAppFolder() {
        AppFolder.activate()
        let result = AppFolderMigration.run(
            legacy: .init(home: FileManager.default.homeDirectoryForCurrentUser), root: AppFolder.root,
            settings: AppFolder.settings, oldSettings: .standard,
            oldDomain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
            discard: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        writeGuide()
        guard !result.isEmpty else { return }
        let log = EventLog()
        log.write("统一文件夹 \(AppFolder.root.path)：设置 \(result.settingsCopied) 项，创意工坊壁纸 \(result.workshopMoved) 个"
            + (result.workshopKept.isEmpty ? "" : "（已经有、留在原处的 \(result.workshopKept.count) 个）")
            + (result.moved.isEmpty ? "" : "，另外挪了：\(result.moved.joined(separator: "、"))")
            + (result.removedSteamCMD ? "；用不上的 SteamCMD 文件夹移到了废纸篓" : ""))
    }

    /// 统一文件夹里的说明：每样东西是什么、能不能删（App 装在这里时才列它；正式版一般在「应用程序」里）
    private static func writeGuide() {
        let hasApp = FileManager.default.fileExists(atPath: AppFolder.root.appendingPathComponent("WallPort.app").path)
        let appLine = hasApp ? String(localized: "WallPort.app     软件本身") + "\n" : ""
        let text = [
            hasApp ? String(localized: "壁坞（WallPort）的所有文件都在这个文件夹里。")
                : String(localized: "壁坞（WallPort）的所有文件都在这个文件夹里（软件本身在「应用程序」里）。"),
            "",
            appLine + String(localized: "Settings.plist   设置（壁纸库、每块屏幕放的壁纸、性能、筛选……）"),
            String(localized: "Workshop/        从 Steam 创意工坊下载的壁纸（每个编号一个文件夹）"),
            String(localized: "Assets/          导入的 Wallpaper Engine 自带素材（可选；没有时用壁坞自带的兼容素材）"),
            String(localized: "Data/            Steam 登录信息、壁纸详情缓存、同步给系统的壁纸截图"),
            String(localized: "Cache/           缓存，删了会自动重建"),
            String(localized: "Logs/            日志，出问题时看这里"),
            "",
            hasApp ? String(localized: "不用了的话，先退出壁坞，再把整个文件夹移到废纸篓。")
                : String(localized: "不用了的话，先退出壁坞，再把整个文件夹和「应用程序」里的壁坞移到废纸篓。"),
            String(localized: "macOS 自己还会记一点东西（窗口位置、网页 Cookie 之类），放在系统的位置，删不删都行。"),
            "",
        ].joined(separator: "\n")
        // 文件名跟着界面语言；换了语言时把另一种语言的旧说明删掉
        let name = String(localized: "说明.txt")
        for other in ["说明.txt", "Read Me.txt"] where other != name {
            try? FileManager.default.removeItem(at: AppFolder.root.appendingPathComponent(other))
        }
        let url = AppFolder.root.appendingPathComponent(name)
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
