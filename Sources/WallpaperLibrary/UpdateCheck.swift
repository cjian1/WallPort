import Foundation

/// 检查更新：读 GitHub 上这个仓库最新的正式发布（Releases；草稿和预发布不算），版本号比现在的新就提示去下载。
/// 仓库写在 Info.plist 的 `WallPortGitHubRepo`（"用户名/仓库名"，`scripts/release.sh` 写进去）；没有时不检查。
/// 用的是 GitHub 不用登录的公开接口（`/repos/{仓库}/releases/latest`），每个 IP 每小时能问 60 次，一天一次绰绰有余
public struct UpdateInfo: Equatable, Sendable {
    /// 版本号（发布的标签去掉开头的 v，例如 v1.0.1 → 1.0.1）
    public var version: String
    /// 这一版的发布页（下载、更新说明都在那里）
    public var url: URL
    public var notes: String?
    /// 安装包（发布附件里的 .dmg）和它的 SHA-256 校验文件（`<安装包>.sha256`，`scripts/release.sh` 生成）。
    /// 两个都有、而且都在这个仓库的 `releases/download` 下时才自动下载；否则只能打开发布页
    public var package: URL?
    public var checksum: URL?

    public init(version: String, url: URL, notes: String? = nil, package: URL? = nil, checksum: URL? = nil) {
        self.version = version
        self.url = url
        self.notes = notes
        self.package = package
        self.checksum = checksum
    }
}

public enum UpdateCheck {
    public enum Failure: LocalizedError, Equatable {
        case insecure
        case badResponse(Int)
        case unreadable
        case invalidRepository
        case noRelease

        public var errorDescription: String? {
            switch self {
            case .insecure: String(localized: "更新地址不是 https，不检查")
            case .badResponse(let status): String(localized: "GitHub 返回 HTTP \(status)")
            case .unreadable: String(localized: "看不懂 GitHub 返回的内容")
            case .invalidRepository: String(localized: "检查更新用的仓库名不对")
            case .noRelease: String(localized: "这个仓库还没有发布任何版本")
            }
        }
    }

    /// "用户名/仓库名" → 最新正式发布的接口地址；名字里只能有字母、数字和 - _ .
    public static func latestReleaseURL(repository: String) -> URL? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(allowed.contains) })
        else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest")
    }

    /// 解析 GitHub 的发布信息（标签、发布页、说明、安装包附件）；发布页也必须是 https。
    /// 给了仓库时，安装包和校验文件只认这个仓库自己的发布附件（`https://github.com/<仓库>/releases/download/…`）
    public static func parseGitHubRelease(_ data: Data, repository: String? = nil) throws -> UpdateInfo {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data), release.draft != true,
              release.prerelease != true
        else { throw Failure.unreadable }
        guard release.html_url.scheme?.lowercased() == "https" else { throw Failure.insecure }
        var version = release.tag_name.trimmingCharacters(in: .whitespaces)
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        guard !version.isEmpty else { throw Failure.unreadable }
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 安装包：优先 WallPort-<版本>.dmg，没有就取第一个 .dmg；校验文件是同名加 .sha256
        let assets = (release.assets ?? []).filter { isReleaseAsset($0.browser_download_url, repository: repository) }
        let package = assets.first { $0.name == "WallPort-\(version).dmg" }
            ?? assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let checksum = package.flatMap { package in assets.first { $0.name == package.name + ".sha256" } }
        return UpdateInfo(
            version: version, url: release.html_url, notes: notes?.isEmpty == false ? notes : nil,
            package: checksum == nil ? nil : package?.browser_download_url, checksum: checksum?.browser_download_url)
    }

    /// 发布附件的下载地址：https、github.com、这个仓库的 releases/download 下面
    static func isReleaseAsset(_ url: URL, repository: String?) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com" else { return false }
        guard let repository else { return url.path.contains("/releases/download/") }
        return url.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/download/")
    }

    /// 版本号按数字一段一段比："1.10.0" 比 "1.9.2" 新，"1.0" 和 "1.0.0" 一样；
    /// 同样的数字带后缀（"1.0.0-beta"）的算比正式版旧
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ version: String) -> (numbers: [Int], suffix: String) {
            let parts = version.split(separator: "-", maxSplits: 1)
            let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, parts.count > 1 ? String(parts[1]) : "")
        }
        let (left, leftSuffix) = split(a), (right, rightSuffix) = split(b)
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0, y = index < right.count ? right[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (leftSuffix.isEmpty, rightSuffix.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): return leftSuffix == rightSuffix ? .orderedSame : (leftSuffix < rightSuffix ? .orderedAscending : .orderedDescending)
        }
    }

    /// 比当前版本新、而且不是用户说过"跳过"的那个版本时，返回它
    public static func newer(_ info: UpdateInfo, currentVersion: String, skippedVersion: String?) -> UpdateInfo? {
        guard compare(info.version, currentVersion) == .orderedDescending, info.version != skippedVersion else { return nil }
        return info
    }

    public static func fetch(repository: String, session: URLSession = .shared) async throws -> UpdateInfo {
        guard let url = latestReleaseURL(repository: repository) else { throw Failure.invalidRepository }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw Failure.noRelease }
        guard status == 200 else { throw Failure.badResponse(status) }
        return try parseGitHubRelease(data, repository: repository)
    }
}
