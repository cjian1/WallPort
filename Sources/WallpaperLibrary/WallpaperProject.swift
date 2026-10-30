import Foundation

/// 一张本机壁纸：Wallpaper Engine 项目文件夹里的 project.json，或者壁纸库根目录里直接放的图片。
public struct WallpaperProject: Equatable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case scene, video, web, image, application, unknown
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

    /// 项目文件夹；散落图片没有项目文件夹，这里就是图片文件本身
    public let folder: URL
    /// 真正存放入口和素材的文件夹；依赖型预设指向它依赖的项目，普通项目等于 `folder`
    public let contentFolder: URL
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
    /// 依赖型创意工坊预设引用的基础项目编号
    public let dependencyID: String?
    /// `project.json` 里的 preset 原样 JSON
    public let preset: Data?

    public var isDependencyBackedPreset: Bool { dependencyID != nil && preset != nil }

    public init(folder: URL) throws {
        if Self.isImageFile(folder) {
            self.init(imageFile: folder)
            return
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")) else {
            throw LoadError.missingProjectFile
        }
        try self.init(folder: folder, projectJSON: data)
    }

    /// 壁纸库根目录里直接放的 PNG / JPEG。标题用文件名，预览和入口都是这张图。
    public init(imageFile: URL) {
        let file = imageFile.standardizedFileURL
        self.folder = file
        contentFolder = file
        title = file.deletingPathExtension().lastPathComponent
        kind = .image
        entry = file
        preview = file
        userProperties = nil
        supportsAudio = false
        rating = nil
        tags = []
        dependencyID = nil
        preset = nil
    }

    /// 目前直接支持常见的 PNG / JPEG 图片；文件夹型项目是否有效仍由 project.json 判断。
    public static func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }

    public init(folder: URL, projectJSON: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: projectJSON)) as? [String: Any] else {
            throw LoadError.invalidJSON
        }
        let general = root["general"] as? [String: Any]
        let entryPath = root["file"] as? String

        self.folder = folder.standardizedFileURL
        contentFolder = folder.standardizedFileURL
        title = (root["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        kind = Self.kind(declared: root["type"] as? String, entry: entryPath)
        entry = try entryPath.map { try Self.resolve($0, in: folder) }
        preview = (root["preview"] as? String).flatMap { try? Self.resolve($0, in: folder) }
        supportsAudio = (root["supportsaudioprocessing"] ?? general?["supportsaudioprocessing"]) as? Bool ?? false
        rating = WallpaperRating(tag: root["contentrating"] as? String)
        tags = (root["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        dependencyID = (root["dependency"] as? String)
            ?? (root["dependency"] as? NSNumber)?.stringValue
        preset = (root["preset"] as? [String: Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        userProperties = (general?["properties"] as? [String: Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    private init(
        folder: URL, contentFolder: URL, title: String, kind: Kind, entry: URL?, preview: URL?,
        userProperties: Data?, supportsAudio: Bool, rating: WallpaperRating?, tags: [String],
        dependencyID: String?, preset: Data?
    ) {
        self.folder = folder
        self.contentFolder = contentFolder
        self.title = title
        self.kind = kind
        self.entry = entry
        self.preview = preview
        self.userProperties = userProperties
        self.supportsAudio = supportsAudio
        self.rating = rating
        self.tags = tags
        self.dependencyID = dependencyID
        self.preset = preset
    }

    /// 把预设项目叠到基础项目上：身份仍用预设文件夹，入口和素材用基础项目。
    public func resolved(using base: WallpaperProject) -> WallpaperProject {
        WallpaperProject(
            folder: folder,
            contentFolder: base.contentFolder,
            title: title,
            kind: base.kind,
            entry: base.entry,
            preview: preview ?? base.preview,
            userProperties: Self.merging(base.userProperties, withPreset: preset),
            supportsAudio: supportsAudio || base.supportsAudio,
            rating: rating ?? base.rating,
            tags: tags.isEmpty ? base.tags : tags,
            dependencyID: dependencyID ?? base.dependencyID,
            preset: preset)
    }

    /// 按创意工坊文件夹编号解析整批项目中的依赖关系；循环依赖保持原样。
    public static func resolvingDependencies(in projects: [WallpaperProject]) -> [WallpaperProject] {
        var byID: [String: WallpaperProject] = [:]
        for project in projects where byID[project.folder.lastPathComponent] == nil {
            byID[project.folder.lastPathComponent] = project
        }
        var memo: [String: WallpaperProject] = [:]

        func resolve(_ project: WallpaperProject, path: Set<String>) -> WallpaperProject {
            let key = project.folder.standardizedFileURL.path
            if let cached = memo[key] { return cached }
            let ownID = project.folder.lastPathComponent
            guard let dependencyID = project.dependencyID,
                  dependencyID != ownID,
                  !path.contains(dependencyID),
                  let base = byID[dependencyID]
            else { return project }
            let nextPath = path.union([ownID])
            let resolvedBase = resolve(base, path: nextPath)
            let result = project.resolved(using: resolvedBase)
            memo[key] = result
            return result
        }

        return projects.map { resolve($0, path: []) }
    }

    /// 在已知下载目录中查找并解析直接依赖，供应用在扫描之外加载单个项目时使用。
    public func resolvingDependency(in directories: [URL], visited: Set<String> = []) -> WallpaperProject {
        let ownID = folder.lastPathComponent
        guard let dependencyID, dependencyID != ownID, !visited.contains(dependencyID) else { return self }
        for directory in directories {
            let baseFolder = directory.appendingPathComponent(dependencyID, isDirectory: true)
            guard FileManager.default.fileExists(atPath: baseFolder.appendingPathComponent("project.json").path),
                  let base = try? WallpaperProject(folder: baseFolder)
            else { continue }
            let resolvedBase = base.resolvingDependency(
                in: directories, visited: visited.union([ownID]))
            return resolved(using: resolvedBase)
        }
        return self
    }

    private static func merging(_ base: Data?, withPreset preset: Data?) -> Data? {
        guard let base, let preset,
              var properties = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any],
              let values = (try? JSONSerialization.jsonObject(with: preset)) as? [String: Any]
        else { return base }
        for (name, value) in values where !(value is NSNull) {
            guard var property = properties[name] as? [String: Any] else { continue }
            property["value"] = value
            properties[name] = property
        }
        return try? JSONSerialization.data(withJSONObject: properties)
    }

    /// 以 type 字段为准（大小写不敏感）；没写或认不出来时按入口文件的扩展名推断
    static func kind(declared: String?, entry: String?) -> Kind {
        if let declared, let kind = Kind(rawValue: declared.lowercased()), kind != .unknown {
            return kind
        }
        switch entry.map({ ($0 as NSString).pathExtension.lowercased() }) {
        case "html", "htm": return .web
        case "mp4", "m4v", "mov", "webm", "avi", "wmv", "mkv": return .video
        case "png", "jpg", "jpeg": return .image
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
