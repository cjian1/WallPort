import Foundation
import Testing
@testable import WallpaperLibrary

@Suite struct WorkshopAuthorCatalogTests {
    private final class StubHTTP: HTTPClient, @unchecked Sendable {
        private let handler: @Sendable (URLRequest) -> (status: Int, body: Data)
        private let lock = NSLock()
        private var requestedURLs: [URL] = []

        init(handler: @escaping @Sendable (URLRequest) -> (status: Int, body: Data)) {
            self.handler = handler
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            if let url = request.url { lock.withLock { requestedURLs.append(url) } }
            let result = handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (result.body, response)
        }

        var urls: [URL] { lock.withLock { requestedURLs } }
    }

    /// 公开详情里的 creator 是作者 SteamID；原有条目字段继续正常解析。
    @Test func detailsParseCreatorSteamID() throws {
        let json = Data(#"""
        {"response":{"publishedfiledetails":[{
          "result":1,"publishedfileid":"3807008481","creator":"76561199453602723",
          "title":"Ronova - Face Check","preview_url":"https://example.invalid/p.jpg",
          "subscriptions":12,"favorited":3,"file_size":"99","time_updated":"100",
          "tags":[{"tag":"Video"},{"tag":"Everyone"}]
        }]}}
        """#.utf8)
        let item = try #require(WorkshopCatalog.parseDetails(json, order: ["3807008481"]).first)
        #expect(item.creatorID == "76561199453602723")
        #expect(item.title == "Ronova - Face Check")
    }

    /// 公开资料 XML 的 CDATA 昵称；资料页没有昵称时用 SteamID，不中断作者作品浏览。
    @Test func authorProfileReadsNicknameAndFallsBackToSteamID() async throws {
        let steamID = "76561199453602723"
        let withName = StubHTTP { request in
            #expect(request.url?.path == "/profiles/\(steamID)")
            return (200, Data("""
                <?xml version="1.0"?><profile>
                <steamID64>\(steamID)</steamID64>
                <steamID><![CDATA[Y]]></steamID>
                <privacyState>public</privacyState>
                </profile>
                """.utf8))
        }
        let author = try await WorkshopCatalog(http: withName).author(steamID)
        #expect(author.name == "Y")
        #expect(author.profileURL.absoluteString == "https://steamcommunity.com/profiles/\(steamID)/")

        let privateProfile = StubHTTP { _ in
            (200, Data("<profile><steamID64>\(steamID)</steamID64><privacyState>private</privacyState></profile>".utf8))
        }
        #expect(try await WorkshopCatalog(http: privateProfile).author(steamID).name == steamID)
    }

    /// 作者作品页复用浏览页的条目编号解析；空页是末页，详情按页面顺序返回。
    @Test func authorWorksPaginateAndFetchDetails() async throws {
        let steamID = "76561199453602723"
        let details = Data(#"""
        {"response":{"publishedfiledetails":[
          {"result":1,"publishedfileid":"111111111","creator":"76561199453602723","title":"A","subscriptions":2,"favorited":0,"file_size":"1","tags":[{"tag":"Video"}]},
          {"result":1,"publishedfileid":"222222222","creator":"76561199453602723","title":"B","subscriptions":3,"favorited":0,"file_size":"1","tags":[{"tag":"Scene"}]}
        ]}}
        """#.utf8)
        let server = StubHTTP { request in
            if request.httpMethod == "POST" { return (200, details) }
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "p" }?.value
            if page == "1" {
                return (200, Data("""
                    <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=111111111"></a>
                    <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=222222222"></a>
                    """.utf8))
            }
            return (200, Data("<html>No items</html>".utf8))
        }
        let catalog = WorkshopCatalog(http: server)
        let first = try await catalog.authorWorks(steamID, page: 1)
        #expect(first.items.map(\.id) == ["111111111", "222222222"])
        #expect(!first.reachedEnd)
        let last = try await catalog.authorWorks(steamID, page: 2)
        #expect(last.items.isEmpty)
        #expect(last.reachedEnd)
        #expect(server.urls.contains {
            $0.path == "/profiles/\(steamID)/myworkshopfiles"
                && URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains { $0.name == "appid" && $0.value == "431960" } == true
        })
    }
}
