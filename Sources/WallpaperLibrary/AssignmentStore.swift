import DesktopHost
import Foundation

/// 一块显示器上放什么
public enum WallpaperSource: Equatable, Sendable {
    case testPattern
    /// 单独的视频文件
    case video(URL)
    /// 含 project.json 的 Wallpaper Engine 项目文件夹
    case project(URL)

    /// 存进 UserDefaults 的字符串形式，方便用 `defaults read local.macwallpaper` 直接查看和修改
    public var storageValue: String {
        switch self {
        case .testPattern: return "testPattern"
        case .video(let url): return Self.videoPrefix + url.path
        case .project(let url): return Self.projectPrefix + url.path
        }
    }

    public init?(storageValue: String) {
        if storageValue == "testPattern" {
            self = .testPattern
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

/// 逐屏的壁纸分配，以显示器的稳定标识（UUID）为键保存。没设置过或存的值认不出来时，默认是测试图案
public final class AssignmentStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = AppFolder.settings, key: String = "displayAssignments") {
        self.defaults = defaults
        self.key = key
    }

    public func source(forDisplay displayKey: String) -> WallpaperSource {
        let stored = defaults.dictionary(forKey: key)?[displayKey] as? String
        return stored.flatMap(WallpaperSource.init(storageValue:)) ?? .testPattern
    }

    /// 这块显示器**单独**设置过的内容；nil 表示没设置过（认不出来的旧值也算没设置过）
    public func storedSource(forDisplay displayKey: String) -> WallpaperSource? {
        (defaults.dictionary(forKey: key)?[displayKey] as? String)
            .flatMap(WallpaperSource.init(storageValue:))
    }

    /// 没单独设置过的显示器（例如刚插上 HDMI / DP 的副屏）该放什么：先用主显示器上那张，
    /// 再退到别的屏幕已经设过的；测试图案不算数（只有全都设成测试图案时才是测试图案）。
    /// 这样新接的屏幕看到的是"我现在用的壁纸"，而不是默认的测试图案
    public func inheritedSource(forDisplay displayKey: String, mainDisplayKey: String?) -> WallpaperSource {
        var keys: [String] = []
        if let mainDisplayKey, mainDisplayKey != displayKey { keys.append(mainDisplayKey) }
        let assigned = (defaults.dictionary(forKey: key) ?? [:]).keys
            .filter { $0 != displayKey && $0 != mainDisplayKey }
            .sorted()
        keys.append(contentsOf: assigned)
        for candidate in keys {
            if let source = storedSource(forDisplay: candidate), source != .testPattern { return source }
        }
        return .testPattern
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
