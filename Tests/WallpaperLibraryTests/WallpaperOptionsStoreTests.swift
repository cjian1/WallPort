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
}
