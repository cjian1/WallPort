import Foundation

/// 发 HTTP 请求的接口：测试里换成假的
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// 真正联网的实现。不带 Cookie（要登录的请求自己在请求头里带），也不存 Cookie，免得和别处混在一起
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    /// - Parameter connectionsPerHost: 同一台服务器最多同时连几条（默认 6）。预览图一页 30 张，多开几条快些
    public init(connectionsPerHost: Int? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        if let connectionsPerHost { configuration.httpMaximumConnectionsPerHost = connectionsPerHost }
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// 创意工坊里的一张壁纸（`ISteamRemoteStorage/GetPublishedFileDetails` 的结果）
public struct WorkshopItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let previewURL: URL?
    public let subscriptions: Int
    public let favorited: Int
    public let fileSize: Int64
    public let updated: Date?
    public let tags: [String]
    /// 当前账号订阅它的时间（只有"我的订阅"列表里有）
    public var subscribedAt: Date?

    public init(
        id: String, title: String, previewURL: URL?, subscriptions: Int, favorited: Int, fileSize: Int64, updated: Date?,
        tags: [String], subscribedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.subscriptions = subscriptions
        self.favorited = favorited
        self.fileSize = fileSize
        self.updated = updated
        self.tags = tags
        self.subscribedAt = subscribedAt
    }

    /// 类型标签：Scene / Video / Web / Application
    public var kind: String? { tags.first { WorkshopQuery.kinds.contains($0) } }
    /// 分级标签：Everyone / Questionable / Mature
    public var rating: String? { tags.first { WorkshopQuery.ratings.contains($0) } }
    /// 分辨率（按标签归类）
    public var resolution: WallpaperResolution { WallpaperResolution(workshopTags: tags) }
    /// 应用程序类壁纸在 macOS 上放不了
    public var isPlayableOnMac: Bool { kind != "Application" }
}

/// 浏览创意工坊的条件
public struct WorkshopQuery: Equatable, Sendable, Codable {
    public enum Sort: String, CaseIterable, Sendable, Identifiable, Codable {
        case trendWeek, trendMonth, trendYear, mostSubscribed, mostRecent, lastUpdated
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .trendWeek: String(localized: "本周最热")
            case .trendMonth: String(localized: "本月最热")
            case .trendYear: String(localized: "今年最热")
            case .mostSubscribed: String(localized: "订阅最多")
            case .mostRecent: String(localized: "最新发布")
            case .lastUpdated: String(localized: "最近更新")
            }
        }

        /// 浏览页的 browsesort 和 days
        var parameters: (sort: String, days: Int?) {
            switch self {
            case .trendWeek: ("trend", 7)
            case .trendMonth: ("trend", 30)
            case .trendYear: ("trend", 365)
            case .mostSubscribed: ("totaluniquesubscribers", nil)
            case .mostRecent: ("mostrecent", nil)
            case .lastUpdated: ("lastupdated", nil)
            }
        }
    }

    public static let kinds = ["Scene", "Video", "Web", "Application"]
    public static let ratings = ["Everyone", "Questionable", "Mature"]

    public var sort: Sort = .trendWeek
    public var search = ""
    /// 只看某种类型（Scene / Video / Web）；nil 是全部
    public var kind: String?
    /// 要看的分级（默认只看 Everyone）。勾几种就出现几种（"或"），不是要同时带这几个标签
    public var ratings: Set<String> = ["Everyone"]
    /// 要看的分辨率；空表示不限
    public var resolutions: Set<WallpaperResolution> = []

    public init() {}

    /// 公开的浏览页（不用登录）：每页 30 个，从中读出条目编号
    public func browseURL(page: Int) -> URL {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        let (sort, days) = sort.parameters
        var items = [
            URLQueryItem(name: "appid", value: Workshop.appID),
            URLQueryItem(name: "browsesort", value: sort),
            URLQueryItem(name: "actualsort", value: sort),
            URLQueryItem(name: "section", value: "readytouseitems"),
            URLQueryItem(name: "p", value: String(max(1, page))),
        ]
        if let days { items.append(URLQueryItem(name: "days", value: String(days))) }
        let text = search.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { items.append(URLQueryItem(name: "searchtext", value: text)) }
        // requiredtags[] 是"同时带这些标签"，所以只用于类型。分级、分辨率要的是"勾了的任意一种"，
        // 用 excludedtags[] 把没勾的排除掉（2026-09-29 实测：排除 Everyone 后一页 28 条全是 Questionable / Mature；
        // 以前勾两种时交给本机筛，一页 30 条里常常只剩两三条）
        if let kind { items.append(URLQueryItem(name: "requiredtags[]", value: kind)) }
        for tag in excludedTags { items.append(URLQueryItem(name: "excludedtags[]", value: tag)) }
        components.queryItems = items
        return components.url!
    }

    /// 交给服务器排除的标签：没勾的分级；选了分辨率时，没选的分辨率
    var excludedTags: [String] {
        var tags = Self.ratings.filter { !ratings.contains($0) }
        if !resolutions.isEmpty, resolutions.count < WallpaperResolution.allCases.count {
            tags += WallpaperResolution.allCases.filter { !resolutions.contains($0) }.flatMap(\.workshopTags)
        }
        return ratings.isEmpty ? [] : tags
    }

    /// 回来以后再筛一遍（服务器排除不了的：没有分辨率标签的算"其它"；在 Mac 上放不了的应用程序类）
    public func accepts(_ item: WorkshopItem) -> Bool {
        guard item.isPlayableOnMac else { return false }
        if let kind, item.kind != kind { return false }
        if !resolutions.isEmpty, !resolutions.contains(item.resolution) { return false }
        guard let rating = item.rating else { return ratings.contains("Everyone") }
        return ratings.contains(rating)
    }
}

/// "我的订阅"的筛选和排序：订阅列表一次读全（几百个），在本机筛，不用每改一次条件就去问 Steam
public struct WorkshopSubscriptionFilter: Equatable, Sendable, Codable {
    public enum Sort: String, CaseIterable, Sendable, Identifiable, Codable {
        case recentlySubscribed, lastUpdated, mostSubscribed, title, fileSize
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .recentlySubscribed: String(localized: "最近订阅")
            case .lastUpdated: String(localized: "最近更新")
            case .mostSubscribed: String(localized: "订阅最多")
            case .title: String(localized: "按标题")
            case .fileSize: String(localized: "文件最大")
            }
        }
    }

    /// 默认按订阅时间：刚订阅的在最前面（按"最近更新"的话，作者很久没更新的条目会排到几百个之后）
    public var sort: Sort = .recentlySubscribed
    public var search = ""
    /// 只看某种类型（Scene / Video / Web）；nil 是全部
    public var kind: String?
    /// 要看的分级（自己订阅的，默认三种都看）
    public var ratings: Set<String> = Set(WorkshopQuery.ratings)
    /// 要看的分辨率；空表示不限
    public var resolutions: Set<WallpaperResolution> = []

    public init() {}

    public func apply(_ items: [WorkshopItem]) -> [WorkshopItem] {
        var query = WorkshopQuery()
        query.kind = kind
        query.ratings = ratings
        query.resolutions = resolutions
        let text = search.trimmingCharacters(in: .whitespaces)
        let kept = items.filter { item in
            query.accepts(item) && (text.isEmpty || item.title.localizedCaseInsensitiveContains(text))
        }
        switch sort {
        case .recentlySubscribed:
            return kept.sorted { ($0.subscribedAt ?? .distantPast) > ($1.subscribedAt ?? .distantPast) }
        case .lastUpdated:
            return kept.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
        case .mostSubscribed:
            return kept.sorted { $0.subscriptions > $1.subscriptions }
        case .title:
            return kept.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .fileSize:
            return kept.sorted { $0.fileSize > $1.fileSize }
        }
    }
}

/// 创意工坊的目录：浏览（公开页面，不用登录）和条目详情（公开接口，不用 key）
public struct WorkshopCatalog: Sendable {
    private let http: any HTTPClient

    public init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// 一页浏览结果（最多 30 个；筛掉分级、应用程序类以后可能更少）。`reachedEnd` 表示这一页已经没有条目了
    public func page(_ page: Int, of query: WorkshopQuery) async throws -> (items: [WorkshopItem], reachedEnd: Bool) {
        var request = URLRequest(url: query.browseURL(page: page))
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await http.data(for: request)
        try Self.check(response)
        let ids = Self.itemIDs(inBrowsePage: String(decoding: data, as: UTF8.self))
        guard !ids.isEmpty else { return ([], true) }
        let items = try await details(ids)
        return (items.filter(query.accepts), false)
    }

    /// 浏览页里的条目编号（按页面顺序，去重）
    public static func itemIDs(inBrowsePage html: String) -> [String] {
        var seen = Set<String>()
        return html.matches(of: #/sharedfiles/filedetails/\?id=(\d{6,20})/#).compactMap { match in
            let id = String(match.1)
            return seen.insert(id).inserted ? id : nil
        }
    }

    /// 条目详情（标题、预览图、订阅数、标签…），按给的顺序返回；查不到的（已删除、不公开）跳过
    public func details(_ ids: [String]) async throws -> [WorkshopItem] {
        let valid = ids.filter(Workshop.isItemID)
        guard !valid.isEmpty else { return [] }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = [("itemcount", String(valid.count))]
        for (index, id) in valid.enumerated() { fields.append(("publishedfileids[\(index)]", id)) }
        request.httpBody = FormEncoding.encode(fields)
        let (data, response) = try await http.data(for: request)
        try Self.check(response)
        return try Self.parseDetails(data, order: valid)
    }

    static func parseDetails(_ data: Data, order: [String]) throws -> [WorkshopItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = (root["response"] as? [String: Any])?["publishedfiledetails"] as? [[String: Any]]
        else { throw WorkshopError(String(localized: "创意工坊返回的数据看不懂")) }
        var byID: [String: WorkshopItem] = [:]
        for file in files {
            guard (file["result"] as? NSNumber)?.intValue == 1, let id = file["publishedfileid"] as? String else { continue }
            func number(_ key: String) -> Int64 {
                if let value = file[key] as? NSNumber { return value.int64Value }
                if let value = file[key] as? String { return Int64(value) ?? 0 }
                return 0
            }
            let updated = number("time_updated")
            byID[id] = WorkshopItem(
                id: id, title: (file["title"] as? String) ?? id,
                previewURL: (file["preview_url"] as? String).flatMap(URL.init(string:)),
                subscriptions: Int(number("subscriptions")), favorited: Int(number("favorited")),
                fileSize: number("file_size"), updated: updated > 0 ? Date(timeIntervalSince1970: TimeInterval(updated)) : nil,
                tags: (file["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String })
        }
        return order.compactMap { byID[$0] }
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkshopError(String(localized: "Steam 返回 HTTP \(http.statusCode)"))
        }
    }
}

/// application/x-www-form-urlencoded
enum FormEncoding {
    static func encode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let body = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
