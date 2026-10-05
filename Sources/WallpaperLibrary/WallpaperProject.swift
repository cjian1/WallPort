import Foundation

/// Wallpaper Engine 项目文件夹里 project.json 的元数据。只解析展示和播放要用的字段，其余忽略。
public struct WallpaperProject: Equatable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case scene, video, web, application, unknown
    }

    public enum LoadError: Error, LocalizedError, Equatable {
        case missingProjectFile
        case invalidJSON
        case entryOutsideFolder(String)

        public var errorDescription: String? {
            switch self {
            case .missingProjectFile: return String(localized: "文件夹里没有 project.json")
            case .invalidJSON: return String(localized: "project.json 不是有效的 JSON")
            case .entryOutsideFolder(let path): return String(localized: "入口文件指向项目文件夹之外：\(path)")
            }
        }
    }

    public let folder: URL
    public let title: String
    public let kind: Kind
    /// 入口文件（视频、index.html、scene.json 等）的完整路径
    public let entry: URL?
    public let preview: URL?
    /// general.properties 原样序列化成 JSON，交给网页壁纸的 applyUserProperties
    public let userProperties: Data?
    /// 声明了要用音频数据（supportsaudioprocessing）
    public let supportsAudio: Bool
    /// 分级（project.json 的 contentrating）；没写的是 nil
    public let rating: WallpaperRating?
    /// 作者给的标签（Anime、Game…）
    public let tags: [String]

    public init(folder: URL) throws {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")) else {
            throw LoadError.missingProjectFile
        }
        try self.init(folder: folder, projectJSON: data)
    }

    public init(folder: URL, projectJSON: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: projectJSON)) as? [String: Any] else {
            throw LoadError.invalidJSON
        }
        let general = root["general"] as? [String: Any]
        let entryPath = root["file"] as? String

        self.folder = folder.standardizedFileURL
        title = (root["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        kind = Self.kind(declared: root["type"] as? String, entry: entryPath)
        entry = try entryPath.map { try Self.resolve($0, in: folder) }
        preview = (root["preview"] as? String).flatMap { try? Self.resolve($0, in: folder) }
        supportsAudio = (root["supportsaudioprocessing"] ?? general?["supportsaudioprocessing"]) as? Bool ?? false
        rating = WallpaperRating(tag: root["contentrating"] as? String)
        tags = (root["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        userProperties = (general?["properties"] as? [String: Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    /// 以 type 字段为准（大小写不敏感）；没写或认不出来时按入口文件的扩展名推断
    static func kind(declared: String?, entry: String?) -> Kind {
        if let declared, let kind = Kind(rawValue: declared.lowercased()), kind != .unknown {
            return kind
        }
        switch entry.map({ ($0 as NSString).pathExtension.lowercased() }) {
        case "html", "htm": return .web
        case "mp4", "m4v", "mov", "webm", "avi", "wmv", "mkv": return .video
        case "json", "pkg": return .scene
        case "exe": return .application
        default: return .unknown
        }
    }

    /// 把 project.json 里的相对路径转成文件夹内的完整路径。兼容 Windows 的反斜杠，拒绝用 ../ 跑出文件夹
    static func resolve(_ relative: String, in folder: URL) throws -> URL {
        let base = folder.standardizedFileURL
        let url = base.appendingPathComponent(relative.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw LoadError.entryOutsideFolder(relative) }
        return url
    }
}
