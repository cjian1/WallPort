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

@MainActor
@Suite struct WorkshopDownloadCancellationTests {
    private func model() -> WorkshopModel {
        WorkshopModel(
            libraryFolders: { [] },
            onDownloaded: { _ in },
            onUnsubscribed: { _ in })
    }

    /// 取消订阅其中一个正在下载的壁纸，只把这一项从队列拿掉，其他壁纸继续下载。
    @Test func cancellingOneDownloadKeepsTheRestOfTheQueue() {
        let model = model()
        model.showQueueForLayoutTest([
            .init(id: "1", state: .downloading),
            .init(id: "2", state: .downloading),
            .init(id: "3", state: .waiting),
        ], paused: false)

        model.cancelDownload("1")

        #expect(model.queue.map(\.id) == ["2", "3"])
        #expect(model.state(of: "1") == nil)
        #expect(model.state(of: "2") == .downloading)
        #expect(model.state(of: "3") == .waiting)
    }

    /// 用户从右键菜单取消订阅时，走的是 `setSubscribed(false)`；它要在联系 Steam 前先停掉本机下载。
    @Test func unsubscribingRemovesOnlyThatDownloadBeforeContactingSteam() async {
        let model = model()
        model.showQueueForLayoutTest([
            .init(id: "1", state: .downloading),
            .init(id: "2", state: .downloading),
            .init(id: "3", state: .waiting),
        ], paused: false)

        let result = await model.setSubscribed(false, id: "1")

        guard case .notLoggedIn = result else {
            Issue.record("测试没有登录，Steam 调用应返回 notLoggedIn")
            return
        }
        #expect(model.queue.map(\.id) == ["2", "3"])
    }

    /// 正在联网下载的那一项也要停；取消后队列里下一项继续，不必重启整个 App。
    @Test func cancellingTheActiveDownloadStopsItAndContinuesWithTheNext() async {
        let (startEvents, startContinuation) = AsyncStream.makeStream(of: String.self)
        let (cancelEvents, cancelContinuation) = AsyncStream.makeStream(of: String.self)
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            startContinuation.yield(id)
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelContinuation.yield(id)
                throw error
            }
            return directory.appendingPathComponent(id)
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        let model = WorkshopModel(
            libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation)
        var starts = startEvents.makeAsyncIterator()
        var cancellations = cancelEvents.makeAsyncIterator()

        model.download(["1", "2"])
        #expect(await starts.next() == "1")
        model.cancelDownload("1")
        #expect(await cancellations.next() == "1")
        #expect(await starts.next() == "2")

        model.cancelDownload("2")
        #expect(await cancellations.next() == "2")
        #expect(model.queue.isEmpty)
    }

    /// 从同一批里取消一个尚未开始的项，不能把它算成“下载失败”。
    @Test func cancellingAWaitingItemDoesNotReportItAsFailed() async {
        let (startEvents, startContinuation) = AsyncStream.makeStream(of: String.self)
        let (releaseEvents, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let (downloadedEvents, downloadedContinuation) = AsyncStream.makeStream(of: URL.self)
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            startContinuation.yield(id)
            for await _ in releaseEvents { break }
            return directory.appendingPathComponent(id)
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        let model = WorkshopModel(
            libraryFolders: { [] },
            onDownloaded: { downloadedContinuation.yield($0) },
            onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation)
        var starts = startEvents.makeAsyncIterator()
        var downloads = downloadedEvents.makeAsyncIterator()

        model.download(["1", "2"])
        #expect(await starts.next() == "1")
        model.cancelDownload("2")
        releaseContinuation.yield(())
        #expect(await downloads.next() != nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isDownloading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.isDownloading)
        #expect(model.state(of: "1") == .done)
        #expect(model.message?.contains("失败") == false)
    }

    /// 「优先下载」应把目标放到等待队列最前，但不打断正在下载的项目。
    @Test func prioritizingAWaitingDownloadRunsItAfterTheActiveOne() async {
        let (startEvents, startContinuation) = AsyncStream.makeStream(of: String.self)
        let (releaseEvents, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            startContinuation.yield(id)
            for await _ in releaseEvents { break }
            return directory.appendingPathComponent(id)
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        let model = WorkshopModel(
            libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation)
        var starts = startEvents.makeAsyncIterator()

        model.download(["1", "2", "3"])
        #expect(await starts.next() == "1")
        model.prioritizeDownload("3")
        releaseContinuation.yield(())
        #expect(await starts.next() == "3")
        releaseContinuation.yield(())
        #expect(await starts.next() == "2")
        releaseContinuation.yield(())
    }

    /// 暂停等待中的项目后，它不会在轮到它时启动；其他项目继续。
    @Test func pausingAWaitingDownloadSkipsIt() async {
        let (startEvents, startContinuation) = AsyncStream.makeStream(of: String.self)
        let (releaseEvents, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            startContinuation.yield(id)
            for await _ in releaseEvents { break }
            return directory.appendingPathComponent(id)
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        let model = WorkshopModel(
            libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation)
        var starts = startEvents.makeAsyncIterator()

        model.download(["1", "2", "3"])
        #expect(await starts.next() == "1")
        model.pauseDownload("2")
        releaseContinuation.yield(())
        #expect(await starts.next() == "3")
        releaseContinuation.yield(())
        #expect(model.state(of: "2") == .paused)
    }

    /// 暂停正在下载的项目要中断当前传输，并让下一项继续。
    @Test func pausingTheActiveDownloadStopsItAndContinues() async {
        let (startEvents, startContinuation) = AsyncStream.makeStream(of: String.self)
        let (releaseEvents, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            startContinuation.yield(id)
            if id == "1" {
                try await Task.sleep(for: .milliseconds(200))
            } else {
                for await _ in releaseEvents { break }
            }
            return directory.appendingPathComponent(id)
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        let model = WorkshopModel(
            libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation)
        var starts = startEvents.makeAsyncIterator()

        model.download(["1", "2"])
        #expect(await starts.next() == "1")
        model.pauseDownload("1")
        #expect(await starts.next() == "2")
        #expect(model.state(of: "1") == .paused)
        releaseContinuation.yield(())
    }

    /// 继续单项暂停后，它重新进入正常等待队列并可开始下载。
    @Test func resumingAPausedDownloadStartsItAgain() async {
        let (startEvents, startContinuation) = AsyncStream.makeStream(of: String.self)
        let (releaseEvents, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            startContinuation.yield(id)
            for await _ in releaseEvents { break }
            return directory.appendingPathComponent(id)
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        let model = WorkshopModel(
            libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation)
        var starts = startEvents.makeAsyncIterator()

        model.download(["1", "2"])
        #expect(await starts.next() == "1")
        model.pauseDownload("2")
        model.resumeDownload("2")
        releaseContinuation.yield(())
        #expect(await starts.next() == "2")
        releaseContinuation.yield(())
    }

    /// 下载完成的预设如果缺少基础项目，基础项目会自动排进下载队列，且只下载一次。
    @Test func downloadingPresetQueuesItsMissingDependency() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopDependency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (startEvents, startContinuation) = AsyncStream.makeStream(of: String.self)
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = id == "3825824301"
                ? #"{"title":"Preset","dependency":"884307090","preset":{"wallpapermode":2}}"#
                : #"{"title":"Base","type":"web","file":"index.html"}"#
            try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
            startContinuation.yield(id)
            return folder
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        let model = WorkshopModel(
            libraryFolders: { [root] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation, downloadDirectory: root)
        var starts = startEvents.makeAsyncIterator()

        model.download(["3825824301"])
        #expect(await starts.next() == "3825824301")
        #expect(await starts.next() == "884307090")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isDownloading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isDownloading)
        #expect(model.queue.map(\.id) == ["3825824301", "884307090"])
    }

    /// 自动补的基础项目排到等待的最前：同步订阅时队里还有别的，也先下它，预设好尽快能放。
    @Test func missingDependencyJumpsAheadOfOtherWaitingDownloads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopDependency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (startEvents, startContinuation) = AsyncStream.makeStream(of: String.self)
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = id == "3825824301"
                ? #"{"title":"Preset","dependency":"884307090","preset":{"wallpapermode":2}}"#
                : #"{"title":"Other","type":"web","file":"index.html"}"#
            try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
            startContinuation.yield(id)
            return folder
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        let model = WorkshopModel(
            libraryFolders: { [root] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation, downloadDirectory: root)
        var starts = startEvents.makeAsyncIterator()

        model.download(["3825824301", "111111111", "222222222"])
        #expect(await starts.next() == "3825824301")
        #expect(await starts.next() == "884307090")
        #expect(await starts.next() == "111111111")
        #expect(await starts.next() == "222222222")
    }

    /// 下载失败要告诉 App（在等这件基础壁纸的预设会换成写着原因的提示），其他项目照常下完。
    @Test func failedDownloadIsReportedAndTheQueueContinues() async throws {
        struct Broken: Error {}
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let operation: @Sendable (
            String, URL, SteamCMSession, (@Sendable (Double) -> Void)?
        ) async throws -> URL = { id, directory, _, _ in
            if id == "884307090" { throw Broken() }
            return directory.appendingPathComponent(id, isDirectory: true)
        }
        let session = SteamCMSession(
            accountName: "someone", steamID: "76561198000000001",
            refreshToken: "header.payload.signature")
        var failed: [String] = []
        let model = WorkshopModel(
            libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            initialSession: session, downloadOperation: operation, downloadDirectory: root,
            onDownloadFailed: { failed.append($0) })

        model.download(["884307090", "111111111"])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isDownloading || model.state(of: "111111111") != .done, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(failed == ["884307090"])
        if case .failed? = model.state(of: "884307090") {} else { Issue.record("基础壁纸应当标成下载失败") }
        #expect(model.state(of: "111111111") == .done)
    }
}
