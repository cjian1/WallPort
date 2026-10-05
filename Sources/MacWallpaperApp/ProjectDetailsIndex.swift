import AVFoundation
import DesktopHost
import Foundation
import WallpaperFormats
import WallpaperLibrary

/// 本机项目的尺寸、占用空间、加入时间：要打开场景包 / 视频才知道，所以在后台读，存盘缓存
/// （`~/Library/Application Support/MacWallpaper/project-details.json`；project.json 改过才重读）
actor ProjectDetailsIndex {
    private struct Entry: Codable {
        /// project.json 的修改时间：变了说明项目换了，要重读
        var stamp: Date
        var details: WallpaperProjectDetails
    }

    static let shared = ProjectDetailsIndex()

    private let fileURL: URL
    private var cache: [String: Entry]

    init(fileURL: URL = AppFolder.data.appendingPathComponent("project-details.json")) {
        self.fileURL = fileURL
        cache = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// 缓存里已有、而且没过期的
    func known(_ projects: [WallpaperProject]) -> [String: WallpaperProjectDetails] {
        var result: [String: WallpaperProjectDetails] = [:]
        for project in projects {
            let key = project.folder.path
            if let entry = cache[key], entry.stamp == Self.stamp(project) { result[key] = entry.details }
        }
        return result
    }

    /// 把还不知道的读出来，每读完一批交给 `update`（界面边读边刷新）
    func fill(
        _ projects: [WallpaperProject], update: @Sendable ([String: WallpaperProjectDetails]) async -> Void
    ) async {
        let missing = projects.filter { project in cache[project.folder.path]?.stamp != Self.stamp(project) }
        guard !missing.isEmpty else { return }
        var batch: [String: WallpaperProjectDetails] = [:]
        for project in missing {
            if Task.isCancelled { break }
            let details = await Self.read(project)
            cache[project.folder.path] = Entry(stamp: Self.stamp(project), details: details)
            batch[project.folder.path] = details
            if batch.count >= 20 {
                await update(batch)
                batch = [:]
            }
        }
        if !batch.isEmpty { await update(batch) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func stamp(_ project: WallpaperProject) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: project.folder.appendingPathComponent("project.json").path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    // MARK: - 读一个项目

    static func read(_ project: WallpaperProject) async -> WallpaperProjectDetails {
        let folder = project.folder
        let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path)
        let added = attributes?[.creationDate] as? Date ?? .distantPast
        var width: Int?
        var height: Int?
        var dynamic = false
        switch project.kind {
        case .web:
            dynamic = true
        case .scene:
            if let size = sceneSize(project) {
                width = size.width
                height = size.height
                dynamic = size.dynamic
            }
        case .video:
            if let entry = project.entry, let size = await videoSize(entry) {
                width = size.width
                height = size.height
            }
        case .application, .unknown:
            break
        }
        return WallpaperProjectDetails(
            width: width, height: height, isDynamic: dynamic, byteSize: folderSize(folder), added: added)
    }

    /// 场景画布：`general.orthogonalprojection` 的宽高；写 `auto` 或是 3D（透视）场景的，按"自适应"算
    static func sceneSize(_ project: WallpaperProject) -> (width: Int?, height: Int?, dynamic: Bool)? {
        let name = project.entry?.lastPathComponent ?? "scene.json"
        var data = try? Data(contentsOf: project.folder.appendingPathComponent(name))
        if data == nil, let package = try? ScenePackage(contentsOf: project.folder.appendingPathComponent("scene.pkg")) {
            data = package.contents(of: name)
        }
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = root["general"] as? [String: Any]
        else { return nil }
        guard let ortho = general["orthogonalprojection"] as? [String: Any] else { return (nil, nil, true) }
        func number(_ value: Any?) -> Int? {
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return SceneValue.int(value) }
            return nil
        }
        if let width = number(ortho["width"]), let height = number(ortho["height"]), width > 0, height > 0 {
            return (width, height, false)
        }
        return (nil, nil, true)
    }

    /// 视频画面尺寸（按旋转后的方向）。系统读不了的格式（webm 之类）就不知道
    static func videoSize(_ url: URL) async -> (width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return (Int(abs(rect.width).rounded()), Int(abs(rect.height).rounded()))
    }

    static func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
