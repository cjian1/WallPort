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
    /// 等比缩放：在铺满 / 完整显示的基础上再缩小或放大（1 是原样，见 `Framing.scaleRange`）
    public var scale: Double = 1
    /// 幻灯片（带图片文件夹的网页预设）由壁坞自己放；关掉就按网页原样放
    public var playsSlidesNatively = true
    /// 壁坞放幻灯片时多少秒换一张
    public var slideInterval: Double = 60
    /// 壁坞放幻灯片时随机挑下一张（否则按文件名顺序）
    public var shufflesSlides = false

    public init(
        isMuted: Bool = false, volume: Double = 1, fitsWhole: Bool = false, position: Double = 0.5, scale: Double = 1,
        playsSlidesNatively: Bool = true, slideInterval: Double = 60, shufflesSlides: Bool = false
    ) {
        self.isMuted = isMuted
        self.volume = volume
        self.fitsWhole = fitsWhole
        self.position = position
        self.scale = scale
        self.playsSlidesNatively = playsSlidesNatively
        self.slideInterval = slideInterval
        self.shufflesSlides = shufflesSlides
    }

    /// 旧版本存的选项没有后来加的字段：缺的用默认值，不能因为少一项就整个读不出来（那样静音、显示方式全丢）
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WallpaperOptions()
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? defaults.isMuted
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? defaults.volume
        fitsWhole = try container.decodeIfPresent(Bool.self, forKey: .fitsWhole) ?? defaults.fitsWhole
        position = try container.decodeIfPresent(Double.self, forKey: .position) ?? defaults.position
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? defaults.scale
        playsSlidesNatively = try container.decodeIfPresent(Bool.self, forKey: .playsSlidesNatively)
            ?? defaults.playsSlidesNatively
        slideInterval = try container.decodeIfPresent(Double.self, forKey: .slideInterval) ?? defaults.slideInterval
        shufflesSlides = try container.decodeIfPresent(Bool.self, forKey: .shufflesSlides) ?? defaults.shufflesSlides
    }

    /// 实际该用的音量（静音时是 0）
    public var effectiveVolume: Float { isMuted ? 0 : Float(min(max(volume, 0), 1)) }
    public var clampedPosition: Double { min(max(position, 0), 1) }
    public var clampedScale: Double { min(max(scale, Framing.scaleRange.lowerBound), Framing.scaleRange.upperBound) }
    public var clampedSlideInterval: Double { min(max(slideInterval, SlideshowContent.minimumInterval), 24 * 3600) }
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
