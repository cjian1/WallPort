import Foundation
import Testing
@testable import WallpaperLibrary

@Suite struct WorkshopTests {
    @Test func itemIDsComeFromFolderNames() {
        #expect(Workshop.itemID(ofProjectFolder: URL(fileURLWithPath: "/Users/me/wp/2350484035/")) == "2350484035")
        #expect(Workshop.itemID(ofProjectFolder: URL(fileURLWithPath: "/Users/me/wp/我的壁纸")) == nil)
        // 下载时的临时目录（`.downloading-<编号>`）不能被当成创意工坊条目
        #expect(Workshop.itemID(ofProjectFolder: URL(fileURLWithPath: "/tmp/.downloading-2350484035")) == nil)
    }

    /// 账户名称只放行 Steam 账户名的字符：填成昵称、邮箱、带空格的在本机就挡掉
    @Test func accountNamesAreRestricted() {
        #expect(Workshop.isValidAccountName("cj_2026.test-1"))
        #expect(!Workshop.isValidAccountName(""))
        #expect(!Workshop.isValidAccountName("a b"))
        #expect(!Workshop.isValidAccountName("me@example.com"))
        #expect(!Workshop.isValidAccountName("有中文"))
    }

    /// 下载到统一文件夹（~/WallPort/Workshop）；以前的三个位置还算创意工坊下载（统一文件夹里已经有同一个编号时旧的留在那里）
    @Test func downloadsGoIntoTheAppFolder() throws {
        #expect(Workshop.downloadDirectory.path.hasSuffix("/WallPort/Workshop"))
        let previous = Workshop.previousDownloadDirectories.map(\.path)
        #expect(previous.count == 3)
        #expect(previous[0].hasSuffix("MacWallpaper/SteamCMD/steamapps/workshop/content/431960"))
        #expect(previous[1].hasSuffix("MacWallpaper/Workshop"))
        #expect(previous[2].hasSuffix("Library/Application Support/Steam/steamapps/workshop/content/431960"))
        #expect(Workshop.downloadDirectories.first == Workshop.downloadDirectory)
        #expect(Workshop.downloadDirectories.count == 4)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workshop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("3807719502"), withIntermediateDirectories: true)
        #expect(!Workshop.containsItems(root), "没有 project.json 的不算")
        try Data("{}".utf8).write(to: root.appendingPathComponent("3807719502/project.json"))
        #expect(Workshop.containsItems(root))
    }

    /// 我的订阅：本机按类型、分级、搜索词筛，再排序
    @Test func subscriptionFilterFiltersAndSorts() {
        func item(_ id: String, _ title: String, _ tags: [String], subs: Int, size: Int64, updated: TimeInterval) -> WorkshopItem {
            WorkshopItem(
                id: id, title: title, previewURL: nil, subscriptions: subs, favorited: 0, fileSize: size,
                updated: Date(timeIntervalSince1970: updated), tags: tags)
        }
        let items = [
            item("1", "Bravo Lucy", ["Scene", "Everyone"], subs: 10, size: 300, updated: 100),
            item("2", "Charlie sea", ["Video", "Questionable"], subs: 50, size: 900, updated: 300),
            item("3", "Alpha clock", ["Web", "Mature"], subs: 30, size: 100, updated: 200),
            item("4", "某个程序", ["Application", "Everyone"], subs: 99, size: 1, updated: 400),
        ]
        var filter = WorkshopSubscriptionFilter()
        // 默认按订阅时间排（刚订阅的在最前），三种分级都看；应用程序类（Mac 上放不了）不列
        #expect(filter.sort == .recentlySubscribed)
        var subscribedLately = items
        subscribedLately[0].subscribedAt = Date(timeIntervalSince1970: 900)   // 1：最久没更新，但刚订阅
        subscribedLately[1].subscribedAt = Date(timeIntervalSince1970: 500)
        subscribedLately[2].subscribedAt = Date(timeIntervalSince1970: 100)
        #expect(filter.apply(subscribedLately).map(\.id) == ["1", "2", "3"])
        filter.sort = .lastUpdated
        #expect(filter.apply(items).map(\.id) == ["2", "3", "1"])
        filter.sort = .mostSubscribed
        #expect(filter.apply(items).map(\.id) == ["2", "3", "1"])
        filter.sort = .fileSize
        #expect(filter.apply(items).map(\.id) == ["2", "1", "3"])
        filter.sort = .title
        #expect(filter.apply(items).map(\.id) == ["3", "1", "2"])
        // 分级可以单选 Mature
        filter.ratings = ["Mature"]
        #expect(filter.apply(items).map(\.id) == ["3"])
        filter.ratings = ["Everyone", "Questionable"]
        filter.kind = "Video"
        #expect(filter.apply(items).map(\.id) == ["2"])
        filter.kind = nil
        filter.search = "lucy"
        #expect(filter.apply(items).map(\.id) == ["1"])
    }

    private func parameters(_ url: URL, _ name: String) -> [String] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == name }.compactMap(\.value)
    }

    /// 分级勾几种就出现几种（"或"）：交给服务器的是"排除没勾的"（requiredtags 是"同时带这些标签"，不能用）
    @Test func browseRatingsAreAnyOfTheChosen() {
        var query = WorkshopQuery()
        query.ratings = ["Questionable", "Mature"]
        let url = query.browseURL(page: 1)
        #expect(parameters(url, "excludedtags[]") == ["Everyone"])
        #expect(parameters(url, "requiredtags[]").isEmpty)
        query.ratings = ["Mature"]
        #expect(Set(parameters(query.browseURL(page: 1), "excludedtags[]")) == ["Everyone", "Questionable"])
        query.ratings = Set(WorkshopQuery.ratings)
        #expect(parameters(query.browseURL(page: 1), "excludedtags[]").isEmpty)
        // 类型仍然是"必须带"
        query.kind = "Scene"
        #expect(parameters(query.browseURL(page: 1), "requiredtags[]") == ["Scene"])

        func item(_ tags: [String]) -> WorkshopItem {
            WorkshopItem(id: "1", title: "", previewURL: nil, subscriptions: 0, favorited: 0, fileSize: 0, updated: nil, tags: tags)
        }
        query = WorkshopQuery()
        query.ratings = ["Questionable", "Mature"]
        #expect(query.accepts(item(["Scene", "Mature"])))
        #expect(query.accepts(item(["Scene", "Questionable"])))
        #expect(!query.accepts(item(["Scene", "Everyone"])))
    }

    /// 分辨率：勾了的任意一种；没勾的分辨率标签交给服务器排除，没有分辨率标签的算"其它"
    @Test func browseResolutionsAreAnyOfTheChosen() {
        var query = WorkshopQuery()
        query.ratings = Set(WorkshopQuery.ratings)
        query.resolutions = [.ultraHD, .quadHD]
        let excluded = Set(parameters(query.browseURL(page: 1), "excludedtags[]"))
        #expect(!excluded.contains("3840 x 2160") && !excluded.contains("2560 x 1440"))
        #expect(excluded.contains("1920 x 1080") && excluded.contains("Dynamic resolution"))
        func item(_ tags: [String]) -> WorkshopItem {
            WorkshopItem(id: "1", title: "", previewURL: nil, subscriptions: 0, favorited: 0, fileSize: 0, updated: nil, tags: tags)
        }
        #expect(query.accepts(item(["Scene", "Everyone", "3840 x 2160"])))
        #expect(!query.accepts(item(["Scene", "Everyone", "1920 x 1080"])))
        #expect(!query.accepts(item(["Scene", "Everyone"])))
        query.resolutions = [.other]
        #expect(query.accepts(item(["Scene", "Everyone"])))
        #expect(query.accepts(item(["Scene", "Everyone", "Other resolution"])))
    }

    /// 本机项目按尺寸归到和创意工坊一样的分辨率分类
    @Test func resolutionsAreClassifiedFromSize() {
        #expect(WallpaperResolution(width: 3840, height: 2160, dynamic: false) == .ultraHD)
        #expect(WallpaperResolution(width: 2560, height: 1440, dynamic: false) == .quadHD)
        #expect(WallpaperResolution(width: 1920, height: 1080, dynamic: false) == .fullHD)
        #expect(WallpaperResolution(width: 1366, height: 768, dynamic: false) == .standard)
        #expect(WallpaperResolution(width: 3440, height: 1440, dynamic: false) == .ultrawide)
        #expect(WallpaperResolution(width: 5120, height: 1440, dynamic: false) == .multiMonitor)
        #expect(WallpaperResolution(width: 1080, height: 1920, dynamic: false) == .portrait)
        #expect(WallpaperResolution(width: nil, height: nil, dynamic: true) == .dynamic)
        #expect(WallpaperResolution(width: nil, height: nil, dynamic: false) == .other)
        #expect(WallpaperResolution(workshopTags: ["Anime", "Portrait 1080 x 1920"]) == .portrait)
        #expect(WallpaperRating(tag: "questionable") == .questionable)
        #expect(WallpaperRating.mature.title == "限制级/成人级(R-18)")
    }

    /// 本机壁纸：类型、分级（没写分级的按大众级）、分辨率、搜索，再排序
    @Test func localLibraryFilterFiltersAndSorts() throws {
        func project(_ name: String, _ type: String, _ rating: String?) throws -> WallpaperProject {
            var json: [String: Any] = ["title": name, "type": type, "file": type == "video" ? "a.mp4" : "scene.json"]
            if let rating { json["contentrating"] = rating }
            return try WallpaperProject(
                folder: URL(fileURLWithPath: "/tmp/wp/\(name)"), projectJSON: JSONSerialization.data(withJSONObject: json))
        }
        let a = try project("Alpha", "scene", "Everyone")
        let b = try project("Bravo", "video", "Mature")
        let c = try project("Charlie", "scene", nil)
        #expect(b.rating == .mature)
        #expect(c.rating == nil)
        let details: [String: WallpaperProjectDetails] = [
            a.folder.path: .init(width: 3840, height: 2160, isDynamic: false, byteSize: 10, added: Date(timeIntervalSince1970: 1)),
            b.folder.path: .init(width: 1920, height: 1080, isDynamic: false, byteSize: 30, added: Date(timeIntervalSince1970: 3)),
            c.folder.path: .init(width: 2560, height: 1440, isDynamic: false, byteSize: 20, added: Date(timeIntervalSince1970: 2)),
        ]
        var filter = LocalLibraryFilter()
        #expect(filter.apply([a, b, c], details: details).map(\.title) == ["Bravo", "Charlie", "Alpha"])
        filter.sort = .size
        #expect(filter.apply([a, b, c], details: details).map(\.title) == ["Bravo", "Charlie", "Alpha"])
        filter.sort = .title
        #expect(filter.apply([c, b, a], details: details).map(\.title) == ["Alpha", "Bravo", "Charlie"])
        filter.ratings = [.everyone]
        #expect(filter.apply([a, b, c], details: details).map(\.title) == ["Alpha", "Charlie"])
        filter.ratings = [.mature]
        #expect(filter.apply([a, b, c], details: details).map(\.title) == ["Bravo"])
        filter.ratings = Set(WallpaperRating.allCases)
        filter.resolutions = [.ultraHD, .quadHD]
        #expect(filter.apply([a, b, c], details: details).map(\.title) == ["Alpha", "Charlie"])
        filter.resolutions = []
        filter.kind = .video
        #expect(filter.apply([a, b, c], details: details).map(\.title) == ["Bravo"])
    }
}
