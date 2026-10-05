import DesktopHost
import Foundation
import ServiceManagement

/// 开机自动启动。用 macOS 13 起的 `SMAppService`；必须以 .app 运行才有效
/// （`swift run` 直接跑可执行文件时会失败，这时把原因写进日志）。
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 用户的选择记在设置里：系统按 App 所在的位置登记开机启动，App 挪了位置（装进统一文件夹）以后
    /// 登记的还是旧位置，启动时按记下的选择重新登记一次（`restore`）
    private static let settingKey = "launchAtLogin"

    /// 返回 nil 表示成功，否则是失败原因
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            AppFolder.settings.set(enabled, forKey: settingKey)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 启动时：记下的是"开机启动"、但这个位置的 App 没登记上，就登记一次。返回失败原因。
    /// 在临时位置运行（直接从 .dmg 打开）时不登记：登记上的是推出 .dmg 就没了的路径
    static func restore() -> String? {
        guard AppFolder.settings.bool(forKey: settingKey), !isEnabled, !isRunningFromTemporaryLocation else { return nil }
        return setEnabled(true)
    }

    /// 直接在 .dmg 里、或者没挪过地方的下载文件夹里打开时，macOS 会把 App 放到一个随机的只读位置运行
    /// （App Translocation），每次打开的位置都不一样
    static var isRunningFromTemporaryLocation: Bool {
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        return bundle.path.contains("/AppTranslocation/") || readOnly
    }
}
