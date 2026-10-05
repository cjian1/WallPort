import DesktopHost
import Foundation

/// 一块显示器上放什么
public enum WallpaperSource: Equatable, Sendable {
    /// 不放动态壁纸：桌面上是用户原来的系统壁纸（壁纸库还是空的、或者用户选了不放）
    case systemWallpaper
    /// 单独的视频文件
    case video(URL)
    /// 含 project.json 的 Wallpaper Engine 项目文件夹
    case project(URL)

    /// 存进 UserDefaults 的字符串形式，方便用 `defaults read local.macwallpaper` 直接查看和修改
    public var storageValue: String {
        switch self {
        case .systemWallpaper: return "system"
        case .video(let url): return Self.videoPrefix + url.path
        case .project(let url): return Self.projectPrefix + url.path
        }
    }

    public init?(storageValue: String) {
        // "testPattern" 是以前的写法（那时没设壁纸的屏幕显示测试图案），现在一样当作不放动态壁纸
        if storageValue == "system" || storageValue == "testPattern" {
            self = .systemWallpaper
        } else if let path = Self.path(in: storageValue, after: Self.videoPrefix) {
            self = .video(URL(fileURLWithPath: path))
        } else if let path = Self.path(in: storageValue, after: Self.projectPrefix) {
            self = .project(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            return nil
        }
    }

    private static let videoPrefix = "video:"
    private static let projectPrefix = "project:"

    private static func path(in value: String, after prefix: String) -> String? {
        guard value.hasPrefix(prefix), value.count > prefix.count else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}

/// 逐屏的壁纸分配，以显示器的稳定标识（UUID）为键保存。没设置过或存的值认不出来时，默认不放动态壁纸（显示系统壁纸）
public final class AssignmentStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = AppFolder.settings, key: String = "displayAssignments") {
        self.defaults = defaults
        self.key = key
    }

    public func source(forDisplay displayKey: String) -> WallpaperSource {
        let stored = defaults.dictionary(forKey: key)?[displayKey] as? String
        return stored.flatMap(WallpaperSource.init(storageValue:)) ?? .systemWallpaper
    }

    /// 这块显示器**单独**设置过的内容；nil 表示没设置过（认不出来的旧值也算没设置过）
    public func storedSource(forDisplay displayKey: String) -> WallpaperSource? {
        (defaults.dictionary(forKey: key)?[displayKey] as? String)
            .flatMap(WallpaperSource.init(storageValue:))
    }

    /// 没单独设置过的显示器（例如刚插上 HDMI / DP 的副屏）该放什么：先用主显示器上那张，
    /// 再退到别的屏幕已经设过的；"不放动态壁纸"不算数（只有全都不放时才不放）。
    /// 这样新接的屏幕看到的是"我现在用的壁纸"，而不是空着
    public func inheritedSource(forDisplay displayKey: String, mainDisplayKey: String?) -> WallpaperSource {
        var keys: [String] = []
        if let mainDisplayKey, mainDisplayKey != displayKey { keys.append(mainDisplayKey) }
        let assigned = (defaults.dictionary(forKey: key) ?? [:]).keys
            .filter { $0 != displayKey && $0 != mainDisplayKey }
            .sorted()
        keys.append(contentsOf: assigned)
        for candidate in keys {
            if let source = storedSource(forDisplay: candidate), source != .systemWallpaper { return source }
        }
        return .systemWallpaper
    }

    /// 所有显示器单独设置过的内容（包括现在没接上的屏幕），按显示器标识排序。启动时提前申请文件访问授权用
    public var storedSources: [WallpaperSource] {
        (defaults.dictionary(forKey: key) ?? [:]).sorted { $0.key < $1.key }
            .compactMap { ($0.value as? String).flatMap(WallpaperSource.init(storageValue:)) }
    }

    public func setSource(_ source: WallpaperSource, forDisplay displayKey: String) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[displayKey] = source.storageValue
        defaults.set(all, forKey: key)
    }
}
