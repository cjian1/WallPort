import Foundation
import Testing
@testable import WallpaperLibrary

@Suite struct AssignmentStoreTests {
    private let suiteName = "AssignmentStoreTests-\(UUID().uuidString)"

    private func withStore(_ body: (AssignmentStore, UserDefaults) -> Void) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AssignmentStore(defaults: defaults), defaults)
    }

    /// 启动时要提前读一下每块屏幕用的壁纸（申请文件访问授权），没接上的屏幕也算，认不出来的值跳过
    @Test func storedSourcesListEveryDisplay() {
        withStore { store, defaults in
            let video = URL(fileURLWithPath: "/Users/me/Movies/海浪.mp4")
            let project = URL(fileURLWithPath: "/Users/me/Documents/wp/123", isDirectory: true)
            store.setSource(.video(video), forDisplay: "B")
            store.setSource(.project(project), forDisplay: "A")
            store.setSource(.systemWallpaper, forDisplay: "C")
            var all = defaults.dictionary(forKey: "displayAssignments") ?? [:]
            all["D"] = "scene:/whatever"
            defaults.set(all, forKey: "displayAssignments")
            #expect(store.storedSources == [.project(project), .video(video), .systemWallpaper])
        }
    }

    @Test func unknownDisplayDefaultsToTestPattern() {
        withStore { store, _ in
            #expect(store.source(forDisplay: "never-seen") == .systemWallpaper)
        }
    }

    @Test func assignmentsAreKeptPerDisplay() {
        withStore { store, _ in
            let video = URL(fileURLWithPath: "/Users/me/Movies/海浪 loop.mp4")
            store.setSource(.video(video), forDisplay: "A")
            store.setSource(.systemWallpaper, forDisplay: "B")
            #expect(store.source(forDisplay: "A") == .video(video))
            #expect(store.source(forDisplay: "B") == .systemWallpaper)
        }
    }

    @Test func laterAssignmentReplacesEarlierOne() {
        withStore { store, _ in
            store.setSource(.video(URL(fileURLWithPath: "/a.mp4")), forDisplay: "A")
            store.setSource(.systemWallpaper, forDisplay: "A")
            #expect(store.source(forDisplay: "A") == .systemWallpaper)
        }
    }

    @Test func unreadableStoredValueFallsBackToTestPattern() {
        withStore { store, defaults in
            defaults.set(["A": "scene:/whatever", "B": "video:"], forKey: "displayAssignments")
            #expect(store.source(forDisplay: "A") == .systemWallpaper)
            #expect(store.source(forDisplay: "B") == .systemWallpaper)
        }
    }

    @Test func storageValueRoundTripsPathsWithColonsAndSpaces() {
        let source = WallpaperSource.video(URL(fileURLWithPath: "/Volumes/外置盘/a:b c.mov"))
        #expect(WallpaperSource(storageValue: source.storageValue) == source)
    }

    /// 没单独设置过的屏幕（刚插上的 HDMI / DP 副屏）沿用主显示器上现在用的那张
    @Test func newDisplayInheritsTheMainDisplaysWallpaper() {
        withStore { store, _ in
            let scene = URL(fileURLWithPath: "/Users/me/wp/3521337568", isDirectory: true)
            store.setSource(.project(scene), forDisplay: "内置屏")
            let inherited = store.inheritedSource(forDisplay: "刚插上的副屏", mainDisplayKey: "内置屏")
            #expect(inherited == .project(scene))
        }
    }

    /// 主显示器没设置过时，退到别的屏幕上已经设过的；"不放动态壁纸"不算数
    @Test func inheritanceSkipsTheTestPatternAndPrefersTheMainDisplay() {
        withStore { store, _ in
            let video = URL(fileURLWithPath: "/Volumes/盘/a.mov")
            store.setSource(.systemWallpaper, forDisplay: "主屏")
            store.setSource(.video(video), forDisplay: "侧屏")
            #expect(store.inheritedSource(forDisplay: "新屏", mainDisplayKey: "主屏") == .video(video))

            // 主屏设过东西就优先用主屏的
            let scene = URL(fileURLWithPath: "/Users/me/wp/3204656477", isDirectory: true)
            store.setSource(.project(scene), forDisplay: "主屏")
            #expect(store.inheritedSource(forDisplay: "新屏", mainDisplayKey: "主屏") == .project(scene))
        }
    }

    /// 全都没设置过（或者都设成不放）时还是不放动态壁纸
    @Test func inheritanceFallsBackToTheTestPattern() {
        withStore { store, _ in
            #expect(store.inheritedSource(forDisplay: "新屏", mainDisplayKey: nil) == .systemWallpaper)
            store.setSource(.systemWallpaper, forDisplay: "主屏")
            #expect(store.inheritedSource(forDisplay: "新屏", mainDisplayKey: "主屏") == .systemWallpaper)
            // 已经单独设置过的屏幕不会被自己影响
            #expect(store.inheritedSource(forDisplay: "主屏", mainDisplayKey: "主屏") == .systemWallpaper)
        }
    }

    /// 认不出来的旧值算"没设置过"，可以继承别的屏幕
    @Test func unreadableOwnValueIsTreatedAsUnset() {
        withStore { store, defaults in
            let video = URL(fileURLWithPath: "/a.mov")
            defaults.set(["主屏": "video:/a.mov", "旧屏": "scene:/whatever"], forKey: "displayAssignments")
            #expect(store.storedSource(forDisplay: "旧屏") == nil)
            #expect(store.storedSource(forDisplay: " никогда") == nil)
            #expect(store.storedSource(forDisplay: "主屏") == .video(video))
            #expect(store.inheritedSource(forDisplay: "旧屏", mainDisplayKey: "主屏") == .video(video))
        }
    }
}

/// 设置面板"显示内容"里关掉的内容按项目存
@Suite struct HiddenElementStoreTests {
    @Test func hiddenElementsArePerProjectAndResettable() {
        let name = "HiddenElementStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HiddenElementStore(defaults: defaults)
        let a = URL(fileURLWithPath: "/Users/me/wp/1", isDirectory: true)
        let b = URL(fileURLWithPath: "/Users/me/wp/2", isDirectory: true)
        store.setHidden(true, element: "particles:Ember", in: a)
        store.setHidden(true, element: "effect:nitro", in: a)
        store.setHidden(true, element: "text:5", in: b)
        store.setHidden(false, element: "effect:nitro", in: a)
        #expect(store.hidden(for: URL(fileURLWithPath: "/Users/me/wp/1/")) == ["particles:Ember"])
        #expect(store.hidden(for: b) == ["text:5"])
        store.reset(a)
        #expect(store.hidden(for: a).isEmpty)
        #expect(store.hidden(for: b) == ["text:5"])
    }

    /// 以前存的 "testPattern"（那时没设壁纸的屏幕显示测试图案）照样认得，当作不放动态壁纸；新写的是 "system"
    @Test func oldTestPatternValueMeansSystemWallpaper() {
        #expect(WallpaperSource(storageValue: "testPattern") == .systemWallpaper)
        #expect(WallpaperSource(storageValue: "system") == .systemWallpaper)
        #expect(WallpaperSource.systemWallpaper.storageValue == "system")
    }

}
