import Foundation
import Testing
@testable import WallpaperLibrary

/// 检查更新：GitHub 发布信息的解析、仓库名的检查、按版本号比新旧、跳过的版本不再提示
@Suite struct UpdateCheckTests {
    @Test func parsesTheLatestGitHubRelease() throws {
        let json = #"""
            {"tag_name": "v1.0.1", "name": "壁坞 1.0.1", "html_url": "https://github.com/someone/wallport/releases/tag/v1.0.1",
             "body": "修了一些问题\r\n", "draft": false, "prerelease": false, "assets": []}
            """#
        let info = try UpdateCheck.parseGitHubRelease(Data(json.utf8))
        #expect(info == UpdateInfo(
            version: "1.0.1", url: URL(string: "https://github.com/someone/wallport/releases/tag/v1.0.1")!, notes: "修了一些问题"))
        #expect(UpdateCheck.newer(info, currentVersion: "1.0.0", skippedVersion: nil) == info)
        #expect(UpdateCheck.newer(info, currentVersion: "1.0.1", skippedVersion: nil) == nil, "同一版")
        #expect(UpdateCheck.newer(info, currentVersion: "1.2", skippedVersion: nil) == nil, "本机更新")
        #expect(UpdateCheck.newer(info, currentVersion: "1.0.0", skippedVersion: "1.0.1") == nil, "用户跳过了这一版")
    }

    @Test func comparesVersionsNumerically() {
        #expect(UpdateCheck.compare("1.10.0", "1.9.2") == .orderedDescending)
        #expect(UpdateCheck.compare("1.0", "1.0.0") == .orderedSame)
        #expect(UpdateCheck.compare("2", "10") == .orderedAscending)
        #expect(UpdateCheck.compare("1.0.0-beta", "1.0.0") == .orderedAscending, "预发布比正式版旧")
        #expect(UpdateCheck.compare("1.0.1-beta", "1.0.0") == .orderedDescending)
    }

    @Test func checksRepositoryNames() {
        #expect(UpdateCheck.latestReleaseURL(repository: "someone/wall-port.app")?.absoluteString
            == "https://api.github.com/repos/someone/wall-port.app/releases/latest")
        for bad in ["someone", "a/b/c", "/repo", "owner/", "../etc", "owner/..", "owner/re po", "owner/仓库", "owner/a?b"] {
            #expect(UpdateCheck.latestReleaseURL(repository: bad) == nil, "\(bad)")
        }
    }

    @Test func rejectsInsecureDraftsAndBrokenReplies() async {
        #expect(throws: UpdateCheck.Failure.insecure) {
            try UpdateCheck.parseGitHubRelease(Data(#"{"tag_name": "v2", "html_url": "http://example.com/r"}"#.utf8))
        }
        #expect(throws: UpdateCheck.Failure.unreadable) {
            try UpdateCheck.parseGitHubRelease(Data(#"{"tag_name": "v2", "html_url": "https://github.com/a/b", "draft": true}"#.utf8))
        }
        #expect(throws: UpdateCheck.Failure.unreadable) { try UpdateCheck.parseGitHubRelease(Data("<html>".utf8)) }
        await #expect(throws: UpdateCheck.Failure.invalidRepository) {
            try await UpdateCheck.fetch(repository: "not a repo")
        }
    }
}
