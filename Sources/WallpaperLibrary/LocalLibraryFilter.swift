import Foundation

/// 本机项目里要从内容本身读出来的信息（分辨率、占用空间、加入时间）。读起来要打开场景包、视频，
/// 所以在后台算、按项目文件夹缓存（见 App 的 `ProjectDetailsIndex`）
public struct WallpaperProjectDetails: Codable, Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    /// 网页、自适应画布：没有固定尺寸
    public var isDynamic: Bool
    public var byteSize: Int64
    public var added: Date

    public init(width: Int?, height: Int?, isDynamic: Bool, byteSize: Int64, added: Date) {
        self.width = width
        self.height = height
        self.isDynamic = isDynamic
        self.byteSize = byteSize
        self.added = added
    }

    public var resolution: WallpaperResolution {
        WallpaperResolution(width: width, height: height, dynamic: isDynamic)
    }
}

/// 本机壁纸的筛选和排序：类型、分级、分辨率、搜索词
public struct LocalLibraryFilter: Equatable, Sendable, Codable {
    public enum Sort: String, CaseIterable, Sendable, Identifiable, Codable {
        case recentlyAdded, title, size
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .recentlyAdded: String(localized: "最近加入")
            case .title: String(localized: "按标题")
            case .size: String(localized: "占用空间")
            }
        }
    }

    public var sort: Sort = .recentlyAdded
    public var search = ""
    /// 只看某种类型；nil 是全部
    public var kind: WallpaperProject.Kind?
    /// 要看的分级（勾几种出现几种）。没写分级的项目按大众级算
    public var ratings: Set<WallpaperRating> = Set(WallpaperRating.allCases)
    /// 要看的分辨率；空表示不限。还没读出尺寸的项目在选了分辨率时先不显示
    public var resolutions: Set<WallpaperResolution> = []

    public init() {}

    /// `details` 的键是项目文件夹的标准路径。`added` 是扫描时就能拿到的加入时间（文件夹的创建时间）：
    /// 详情还在后台读的时候，"最近加入"按它排——刚下载的壁纸不能因为详情没读完就排到最后
    public func apply(
        _ projects: [WallpaperProject], details: [String: WallpaperProjectDetails], added: [String: Date] = [:]
    ) -> [WallpaperProject] {
        let text = search.trimmingCharacters(in: .whitespaces)
        let kept = projects.filter { project in
            if let kind, project.kind != kind { return false }
            if !ratings.contains(project.rating ?? .everyone) { return false }
            if !resolutions.isEmpty {
                guard let resolution = details[project.folder.path]?.resolution, resolutions.contains(resolution)
                else { return false }
            }
            return text.isEmpty || project.title.localizedCaseInsensitiveContains(text)
        }
        switch sort {
        case .title:
            return kept.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlyAdded:
            func date(_ project: WallpaperProject) -> Date {
                added[project.folder.path] ?? details[project.folder.path]?.added ?? .distantPast
            }
            return kept.sorted { date($0) > date($1) }
        case .size:
            return kept.sorted { (details[$0.folder.path]?.byteSize ?? 0) > (details[$1.folder.path]?.byteSize ?? 0) }
        }
    }
}
