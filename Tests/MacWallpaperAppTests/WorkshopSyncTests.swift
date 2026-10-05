import Foundation
import Testing
@testable import MacWallpaperApp
import WallpaperLibrary

/// 同步订阅：最近订阅的先下（Steam 回来的顺序是按作者最后更新时间排的）
@MainActor
@Suite struct WorkshopSyncTests {
    private func item(_ id: String, updated: Double, subscribed: Double?) -> WorkshopItem {
        WorkshopItem(
            id: id, title: id, previewURL: nil, subscriptions: 0, favorited: 0, fileSize: 0,
            updated: Date(timeIntervalSince1970: updated), tags: [],
            subscribedAt: subscribed.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func newestSubscriptionsComeFirst() {
        // Steam 的顺序：作者最近更新的在前；"old" 是很久没更新、但刚订阅的
        let fromSteam = [
            item("recentlyUpdated", updated: 900, subscribed: 100),
            item("middle", updated: 800, subscribed: 300),
            item("unknown1", updated: 700, subscribed: nil),
            item("old", updated: 10, subscribed: 999),
            item("unknown2", updated: 5, subscribed: nil),
        ]
        #expect(WorkshopModel.newestSubscriptionsFirst(fromSteam).map(\.id)
            == ["old", "middle", "recentlyUpdated", "unknown1", "unknown2"])
    }
}

/// 浏览创意工坊时的年龄确认：没确认过，存下的筛选里勾了家长指导级 / 限制级也只看大众级
@MainActor
@Suite(.serialized) struct AgeConfirmationTests {
    @Test func unconfirmedBrowsingStaysEveryone() {
        let before = AgeConfirmation.isConfirmed
        defer { AgeConfirmation.isConfirmed = before }
        var saved = WorkshopQuery()
        saved.ratings = ["Everyone", "Questionable", "Mature"]
        AgeConfirmation.isConfirmed = false
        #expect(AgeConfirmation.restricted(saved).ratings == ["Everyone"])
        AgeConfirmation.isConfirmed = true
        #expect(AgeConfirmation.restricted(saved).ratings == saved.ratings)
        #expect(WorkshopQuery().ratings == ["Everyone"], "新装的默认只看大众级")
    }
}

/// 本机壁纸库的"最近加入"：从创意工坊下载的按订阅时间排。文件夹创建时间是下载时间——同步时按
/// "最近订阅的先下"整批下载，最新订阅的反而最早创建，按创建时间排就落到了最后
@Suite struct RecentlyAddedOrderTests {
    @Test func workshopDownloadsSortBySubscriptionTime() throws {
        let root = URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        func project(_ name: String) throws -> WallpaperProject {
            try WallpaperProject(
                folder: root.appendingPathComponent(name, isDirectory: true),
                projectJSON: Data(#"{"title": "\#(name)", "type": "video", "file": "a.mp4"}"#.utf8))
        }
        let old = try project("1000001"), new = try project("1000002"), mine = try project("我的壁纸")
        let now = Date()
        // 下载顺序：新订阅的先下（创建得最早），老订阅的后下
        let created = [
            new.folder.path: now.addingTimeInterval(-300), old.folder.path: now.addingTimeInterval(-100),
            mine.folder.path: now.addingTimeInterval(-200),
        ]
        let subscribed = ["1000001": now.addingTimeInterval(-86400 * 30), "1000002": now.addingTimeInterval(-60)]
        let added = LibraryModel.addedDates(
            created, projects: [old, new, mine], subscriptionDates: subscribed,
            isWorkshopDownload: { Workshop.itemID(ofProjectFolder: $0.folder) != nil })
        var filter = LocalLibraryFilter()
        filter.sort = .recentlyAdded
        let order = filter.apply([old, new, mine], details: [:], added: added).map(\.title)
        // 刚订阅的在最前；自己拷来的按创建时间；一个月前订阅的在最后
        #expect(order == ["1000002", "我的壁纸", "1000001"])
    }
}
