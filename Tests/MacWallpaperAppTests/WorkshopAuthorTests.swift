import Foundation
import os
import Testing
@testable import MacWallpaperApp
import WallpaperLibrary

@MainActor
@Suite struct WorkshopAuthorTests {
    private final class StubHTTP: HTTPClient, @unchecked Sendable {
        private let handler: @Sendable (URLRequest) -> (status: Int, body: Data)
        private let lock = NSLock()
        private var urls: [URL] = []

        init(handler: @escaping @Sendable (URLRequest) -> (status: Int, body: Data)) {
            self.handler = handler
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            if let url = request.url { lock.withLock { urls.append(url) } }
            let result = handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (result.body, response)
        }

        var requestedURLs: [URL] { lock.withLock { urls } }
    }

    private func model(_ server: StubHTTP) -> WorkshopModel {
        WorkshopModel(
            libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in },
            catalog: WorkshopCatalog(http: server))
    }

    /// 作者昵称按需读取并缓存；同一页网格不需要为每张图重复请求资料。
    @Test func authorNameIsLoadedOnceAndCached() async {
        let steamID = "76561199453602723"
        let server = StubHTTP { _ in
            (200, Data("<profile><steamID><![CDATA[Y]]></steamID></profile>".utf8))
        }
        let model = model(server)
        await model.loadAuthorName(steamID)
        await model.loadAuthorName(steamID)

        #expect(model.authorName(for: steamID) == "Y")
        #expect(server.requestedURLs.count == 1)
    }

    /// 作者作品按页追加、跨页去重；空页表示结束。
    @Test func authorWorksAppendAndDeduplicatePages() async throws {
        let steamID = "76561199453602723"
        let details = Data(#"""
        {"response":{"publishedfiledetails":[
          {"result":1,"publishedfileid":"111111111","creator":"76561199453602723","title":"A","subscriptions":1,"favorited":0,"file_size":"1","tags":[{"tag":"Video"}]},
          {"result":1,"publishedfileid":"222222222","creator":"76561199453602723","title":"B","subscriptions":1,"favorited":0,"file_size":"1","tags":[{"tag":"Scene"}]},
          {"result":1,"publishedfileid":"333333333","creator":"76561199453602723","title":"C","subscriptions":1,"favorited":0,"file_size":"1","tags":[{"tag":"Web"}]}
        ]}}
        """#.utf8)
        let server = StubHTTP { request in
            if request.httpMethod == "POST" { return (200, details) }
            if request.url?.path.hasSuffix("/profiles/\(steamID)") == true {
                return (200, Data("<profile><steamID><![CDATA[Y]]></steamID></profile>".utf8))
            }
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "p" }?.value
            switch page {
            case "1": return (200, Data("""
                <a href="/sharedfiles/filedetails/?id=111111111"></a>
                <a href="/sharedfiles/filedetails/?id=222222222"></a>
                """.utf8))
            case "2": return (200, Data("""
                <a href="/sharedfiles/filedetails/?id=222222222"></a>
                <a href="/sharedfiles/filedetails/?id=333333333"></a>
                """.utf8))
            default: return (200, Data("<html>No items</html>".utf8))
            }
        }
        let model = model(server)
        await model.openAuthor(steamID, name: "Y")
        #expect(model.authorWorks.map(\.id) == ["111111111", "222222222"])
        #expect(model.hasMoreAuthorWorks)

        await model.loadMoreAuthorWorks()
        #expect(model.authorWorks.map(\.id) == ["111111111", "222222222", "333333333"])
        #expect(model.hasMoreAuthorWorks)

        await model.loadMoreAuthorWorks()
        #expect(model.authorWorks.map(\.id) == ["111111111", "222222222", "333333333"])
        #expect(!model.hasMoreAuthorWorks)
    }

    /// 作品页读取失败后点「重试」要真的再读（失败时为了停住自动加载把"还有更多"关掉了，重试要重新打开）。
    @Test func retryAfterAFailedAuthorPageLoadsIt() async {
        let steamID = "76561199453602723"
        let details = Data(#"""
        {"response":{"publishedfiledetails":[
          {"result":1,"publishedfileid":"111111111","creator":"76561199453602723","title":"A","subscriptions":1,"favorited":0,"file_size":"1","tags":[{"tag":"Video"}]}
        ]}}
        """#.utf8)
        let failing = OSAllocatedUnfairLock(initialState: true)
        let server = StubHTTP { request in
            if request.httpMethod == "POST" { return (200, details) }
            if failing.withLock({ $0 }) { return (500, Data()) }
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "p" }?.value
            return page == "1"
                ? (200, Data(#"<a href="/sharedfiles/filedetails/?id=111111111"></a>"#.utf8))
                : (200, Data("<html>No items</html>".utf8))
        }
        let model = model(server)
        await model.openAuthor(steamID, name: "Y")
        #expect(model.authorWorks.isEmpty)
        #expect(model.authorWorksError != nil)

        failing.withLock { $0 = false }
        // 原来「重试」按钮调的就是它：失败后"还有更多"已经关掉，什么也不读
        await model.loadMoreAuthorWorks()
        #expect(model.authorWorks.isEmpty)
        await model.retryAuthorWorks()
        #expect(model.authorWorksError == nil)
        #expect(model.authorWorks.map(\.id) == ["111111111"])
    }

    /// 页码超出范围时页面可能重复给已经列出的条目：没有新条目就当到头，不再显示"还有"。
    @Test func aPageWithNothingNewEndsTheList() async {
        let steamID = "76561199453602723"
        let details = Data(#"""
        {"response":{"publishedfiledetails":[
          {"result":1,"publishedfileid":"111111111","creator":"76561199453602723","title":"A","subscriptions":1,"favorited":0,"file_size":"1","tags":[{"tag":"Video"}]}
        ]}}
        """#.utf8)
        let server = StubHTTP { request in
            request.httpMethod == "POST"
                ? (200, details)
                : (200, Data(#"<a href="/sharedfiles/filedetails/?id=111111111"></a>"#.utf8))
        }
        let model = model(server)
        await model.openAuthor(steamID, name: "Y")
        #expect(model.hasMoreAuthorWorks)
        await model.loadMoreAuthorWorks()
        #expect(model.authorWorks.map(\.id) == ["111111111"])
        #expect(!model.hasMoreAuthorWorks)
    }

    /// 资料页读取失败不阻断作者作品浏览，界面仍有可点击的 SteamID。
    @Test func authorNameFailureFallsBackToSteamID() async {
        let steamID = "76561199453602723"
        let server = StubHTTP { _ in (500, Data()) }
        let model = model(server)
        await model.loadAuthorName(steamID)
        #expect(model.authorName(for: steamID) == steamID)
    }
}
