import Foundation
import Testing
@testable import WallpaperLibrary

/// 筛选条件要"记住"：存进 UserDefaults、读回来一模一样（切换页面、重启 App 不回默认）
@Suite struct FilterDefaultsTests {
    private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: "FilterDefaultsTests-\(name)")!
    }

    @Test func workshopQueryRoundTrips() {
        var query = WorkshopQuery()
        query.sort = .mostRecent
        query.kind = "Video"
        query.ratings = ["Questionable", "Mature"]          // 不是默认的"只看大众级"
        query.resolutions = [.ultraHD, .ultrawide]
        query.search = "blue archive"
        let defaults = scratchDefaults()
        FilterDefaults.save(query, key: "workshop.browse", defaults: defaults)
        #expect(FilterDefaults.load(WorkshopQuery.self, key: "workshop.browse", defaults: defaults) == query)
    }

    @Test func subscriptionFilterRoundTrips() {
        var filter = WorkshopSubscriptionFilter()
        filter.sort = .fileSize
        filter.kind = "Scene"
        filter.ratings = ["Everyone", "Mature"]
        filter.resolutions = [.fullHD]
        let defaults = scratchDefaults()
        FilterDefaults.save(filter, key: "workshop.subscriptions", defaults: defaults)
        #expect(FilterDefaults.load(
            WorkshopSubscriptionFilter.self, key: "workshop.subscriptions", defaults: defaults) == filter)
    }

    @Test func libraryFilterRoundTrips() {
        var filter = LocalLibraryFilter()
        filter.sort = .title
        filter.kind = .video
        filter.ratings = [.mature]
        filter.resolutions = [.quadHD]
        filter.search = "rio"
        let defaults = scratchDefaults()
        FilterDefaults.save(filter, key: "library", defaults: defaults)
        #expect(FilterDefaults.load(LocalLibraryFilter.self, key: "library", defaults: defaults) == filter)
    }

    /// 没存过时读回 nil（由调用方用默认值），不同键互不影响
    @Test func missingValueIsNil() {
        let defaults = scratchDefaults()
        #expect(FilterDefaults.load(WorkshopQuery.self, key: "never-saved", defaults: defaults) == nil)
    }
}
