import DesktopHost
import Foundation

/// 每个壁纸自己的播放选项（不是作者声明的属性，是壁坞加的）：声音和画面怎么放到屏幕上
public struct WallpaperOptions: Codable, Equatable, Sendable {
    /// 这个壁纸不出声（菜单栏的"播放壁纸声音"是总开关，关着时所有壁纸都不出声）
    public var isMuted = false
    /// 音量，0–1
    public var volume: Double = 1
    /// 完整显示：壁纸比例和屏幕不同时整张放进屏幕、两边留黑；默认铺满屏幕（裁掉多出来的部分，和 WE 一样）
    public var fitsWhole = false
    /// 铺满时看哪一部分：被裁的方向上 0 是最左 / 最上，1 是最右 / 最下，0.5 居中
    public var position: Double = 0.5

    public init(isMuted: Bool = false, volume: Double = 1, fitsWhole: Bool = false, position: Double = 0.5) {
        self.isMuted = isMuted
        self.volume = volume
        self.fitsWhole = fitsWhole
        self.position = position
    }

    /// 实际该用的音量（静音时是 0）
    public var effectiveVolume: Float { isMuted ? 0 : Float(min(max(volume, 0), 1)) }
    public var clampedPosition: Double { min(max(position, 0), 1) }
}

/// 按项目文件夹存每个壁纸的播放选项（UserDefaults 里一个字典：路径 → JSON）
public final class WallpaperOptionsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "wallpaperOptions"

    public init(defaults: UserDefaults = AppFolder.settings) {
        self.defaults = defaults
    }

    private func storageKey(_ folder: URL) -> String { folder.standardizedFileURL.path }

    public func options(for folder: URL) -> WallpaperOptions {
        guard let data = (defaults.dictionary(forKey: key) ?? [:])[storageKey(folder)] as? Data,
              let options = try? JSONDecoder().decode(WallpaperOptions.self, from: data)
        else { return WallpaperOptions() }
        return options
    }

    public func set(_ options: WallpaperOptions, for folder: URL) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[storageKey(folder)] = options == WallpaperOptions() ? nil : try? JSONEncoder().encode(options)
        defaults.set(all, forKey: key)
    }

    public func reset(_ folder: URL) {
        set(WallpaperOptions(), for: folder)
    }
}
