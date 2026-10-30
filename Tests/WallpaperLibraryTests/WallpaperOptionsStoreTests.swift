import Foundation
import Testing
@testable import WallpaperLibrary

/// 每个壁纸自己的播放选项（静音、音量、显示方式）：按文件夹存、默认值不占地方、恢复默认就删掉
@Suite struct WallpaperOptionsStoreTests {
    @Test func optionsAreStoredPerFolderAndDefaultsAreRemoved() throws {
        // 用临时目录里的文件当设置（绝对路径的套件不会在 ~/Library/Preferences 留文件）
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperOptions-\(UUID().uuidString)").path
        let defaults = try #require(UserDefaults(suiteName: path))
        defer { try? FileManager.default.removeItem(atPath: path + ".plist") }
        let store = WallpaperOptionsStore(defaults: defaults)
        let first = URL(fileURLWithPath: "/tmp/wallpapers/1", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/wallpapers/2", isDirectory: true)
        #expect(store.options(for: first) == WallpaperOptions())

        store.set(WallpaperOptions(isMuted: true, volume: 0.3, fitsWhole: false, position: 0), for: first)
        store.set(WallpaperOptions(fitsWhole: true), for: second)
        #expect(store.options(for: first) == WallpaperOptions(isMuted: true, volume: 0.3, position: 0))
        #expect(store.options(for: second).fitsWhole)
        #expect(store.options(for: first).effectiveVolume == 0, "静音时实际音量是 0")

        store.reset(first)
        #expect(store.options(for: first) == WallpaperOptions())
        #expect((defaults.dictionary(forKey: "wallpaperOptions") ?? [:]).count == 1, "恢复默认的不占地方")
    }

    /// 旧版本存的选项没有缩放、幻灯片这些后来加的字段：照样读出来，缺的用默认值（不能整个读不出来、把静音之类丢掉）
    @Test func optionsSavedByOlderVersionsKeepTheirValues() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperOptions-\(UUID().uuidString)").path
        let defaults = try #require(UserDefaults(suiteName: path))
        defer { try? FileManager.default.removeItem(atPath: path + ".plist") }
        let folder = URL(fileURLWithPath: "/tmp/wallpapers/old", isDirectory: true)
        let old = Data(#"{"isMuted":true,"volume":0.4,"fitsWhole":true,"position":0.25}"#.utf8)
        defaults.set([folder.standardizedFileURL.path: old], forKey: "wallpaperOptions")

        let options = WallpaperOptionsStore(defaults: defaults).options(for: folder)
        #expect(options == WallpaperOptions(isMuted: true, volume: 0.4, fitsWhole: true, position: 0.25))
        #expect(options.scale == 1 && options.playsSlidesNatively && options.slideInterval == 60 && !options.shufflesSlides)
    }

    @Test func scaleAndSlideIntervalAreClamped() {
        #expect(WallpaperOptions(scale: 9).clampedScale == 2)
        #expect(WallpaperOptions(scale: 0.1).clampedScale == 0.5)
        #expect(WallpaperOptions(slideInterval: 0.5).clampedSlideInterval == 2)
    }
}
