import DesktopHost
import Foundation

/// 轮播设置：隔多久换一张、按什么顺序换。存在 UserDefaults 里。
public struct PlaylistSettings: Equatable, Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        /// 按壁纸库的顺序往下轮
        case sequential
        /// 每次随机挑一张（不会挑到当前这张）
        case random

        public var title: String { self == .sequential ? String(localized: "按顺序") : String(localized: "随机") }
    }

    public var isEnabled: Bool
    public var intervalMinutes: Int
    public var mode: Mode

    public init(isEnabled: Bool = false, intervalMinutes: Int = 30, mode: Mode = .sequential) {
        self.isEnabled = isEnabled
        self.intervalMinutes = max(1, intervalMinutes)
        self.mode = mode
    }
}

/// 轮播设置的存储
public final class PlaylistStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "playlistSettings"

    public init(defaults: UserDefaults = AppFolder.settings) {
        self.defaults = defaults
    }

    public var settings: PlaylistSettings {
        get {
            guard let raw = defaults.dictionary(forKey: key) else { return PlaylistSettings() }
            return PlaylistSettings(
                isEnabled: raw["isEnabled"] as? Bool ?? false,
                intervalMinutes: (raw["intervalMinutes"] as? NSNumber)?.intValue ?? 30,
                mode: (raw["mode"] as? String).flatMap(PlaylistSettings.Mode.init(rawValue:)) ?? .sequential)
        }
        set {
            defaults.set(
                ["isEnabled": newValue.isEnabled, "intervalMinutes": newValue.intervalMinutes,
                 "mode": newValue.mode.rawValue],
                forKey: key)
        }
    }
}

/// 轮播时挑下一张：从壁纸库的项目里选，跳过放不了的（应用程序类、类型认不出来的）
public enum PlaylistPicker {
    /// 能作为壁纸播放的项目
    public static func playable(_ projects: [WallpaperProject]) -> [WallpaperProject] {
        projects.filter { [.scene, .video, .web].contains($0.kind) && $0.entry != nil }
    }

    /// - Parameters:
    ///   - current: 这块显示器当前用的项目文件夹
    ///   - isRandom: true 时随机挑一张（不挑当前这张）；false 时按列表顺序取下一张
    /// - Returns: 下一个项目；没有可选项时返回 nil
    public static func next(
        from projects: [WallpaperProject], current: URL?, isRandom: Bool,
        using generator: inout some RandomNumberGenerator
    ) -> WallpaperProject? {
        let candidates = playable(projects)
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            return candidates[0].folder.standardizedFileURL == current?.standardizedFileURL ? nil : candidates[0]
        }

        if isRandom {
            let others = candidates.filter { $0.folder.standardizedFileURL != current?.standardizedFileURL }
            return others.randomElement(using: &generator) ?? candidates.randomElement(using: &generator)
        }
        guard let current, let index = candidates.firstIndex(where: { $0.folder.standardizedFileURL == current.standardizedFileURL })
        else { return candidates.first }
        return candidates[(index + 1) % candidates.count]
    }

    /// 删掉 `deleted` 这些项目以后，原来放 `current` 的显示器换成哪一张：壁纸库里排在它后面、
    /// 没被删的第一张能放的（到末尾绕回开头）。一张都不剩时返回 nil
    public static func replacement(
        for current: URL, deleting deleted: [URL], in projects: [WallpaperProject]
    ) -> WallpaperProject? {
        let gone = Set(deleted.map(\.standardizedFileURL.path))
        let candidates = playable(projects)
        let start = candidates.firstIndex { $0.folder.standardizedFileURL == current.standardizedFileURL }
            .map { $0 + 1 } ?? 0
        for offset in 0..<candidates.count {
            let project = candidates[(start + offset) % candidates.count]
            if !gone.contains(project.folder.standardizedFileURL.path) { return project }
        }
        return nil
    }
}
