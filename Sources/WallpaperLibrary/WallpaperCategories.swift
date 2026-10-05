import Foundation

/// 分级（WE 的 Everyone / Questionable / Mature），界面上按用户习惯的叫法显示
public enum WallpaperRating: String, CaseIterable, Sendable, Identifiable, Codable {
    case everyone = "Everyone"
    case questionable = "Questionable"
    case mature = "Mature"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .everyone: String(localized: "大众级(G)")
        case .questionable: String(localized: "家长指导级(PG-13)")
        case .mature: String(localized: "限制级/成人级(R-18)")
        }
    }

    /// project.json 的 `contentrating`、创意工坊的标签（大小写不敏感）；认不出来的返回 nil
    public init?(tag: String?) {
        guard let tag, let rating = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(tag) == .orderedSame })
        else { return nil }
        self = rating
    }
}

/// 分辨率的分类。创意工坊用标签表示（`3840 x 2160`、`Ultrawide 3440 x 1440`…，2026-09-29 抽了 362 个条目核对写法），
/// 本机的项目按内容本身的尺寸（场景画布、视频画面）归到同一套分类里，两边的筛选就能用同一组勾选
public enum WallpaperResolution: String, CaseIterable, Sendable, Identifiable, Codable {
    case standard, fullHD, quadHD, ultraHD, ultrawide, multiMonitor, portrait, dynamic, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: String(localized: "标清 / 720p")
        case .fullHD: "1080p"
        case .quadHD: String(localized: "2K（1440p）")
        case .ultraHD: String(localized: "4K（2160p）")
        case .ultrawide: String(localized: "超宽屏")
        case .multiMonitor: String(localized: "双屏 / 三屏")
        case .portrait: String(localized: "竖屏")
        case .dynamic: String(localized: "自适应（动态）")
        case .other: String(localized: "其它")
        }
    }

    /// 创意工坊上对应的标签
    public var workshopTags: [String] {
        switch self {
        case .standard: ["Standard Definition", "1280 x 720", "1366 x 768"]
        case .fullHD: ["1920 x 1080"]
        case .quadHD: ["2560 x 1440"]
        case .ultraHD: ["3840 x 2160"]
        case .ultrawide: ["Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440"]
        case .multiMonitor:
            ["Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160",
             "Triple Standard Definition", "Triple 4096 x 768", "Triple 5760 x 1080", "Triple 7680 x 1440",
             "Triple 11520 x 2160"]
        case .portrait:
            ["Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920", "Portrait 1440 x 2560",
             "Portrait 2160 x 3840"]
        case .dynamic: ["Dynamic resolution"]
        case .other: ["Other resolution"]
        }
    }

    public static let allWorkshopTags: [String] = allCases.flatMap(\.workshopTags)

    /// 创意工坊条目的分辨率（看标签；没有分辨率标签的算"其它"）
    public init(workshopTags tags: [String]) {
        self = Self.allCases.first { resolution in resolution.workshopTags.contains { tags.contains($0) } } ?? .other
    }

    /// 本机项目按尺寸归类：网页、自适应画布是"动态"；竖着的是竖屏；很宽的是超宽 / 多屏；其余按高度分档
    public init(width: Int?, height: Int?, dynamic: Bool) {
        if dynamic { self = .dynamic; return }
        guard let width, let height, width > 0, height > 0 else { self = .other; return }
        let ratio = Double(width) / Double(height)
        switch true {
        case ratio < 0.95: self = .portrait
        case ratio >= 3.0: self = .multiMonitor
        case ratio >= 2.1: self = .ultrawide
        case height >= 2000: self = .ultraHD
        case height >= 1300: self = .quadHD
        case height >= 1000: self = .fullHD
        default: self = .standard
        }
    }
}
