import DesktopHost
import Foundation

/// 壁纸库：扫描用户指定的文件夹，把里面的 WE 项目和直接放的 PNG / JPEG 图片都列出来。
///
/// 只看文件夹的直接子文件夹（WE 的创意工坊目录、用户从 Windows 拷来的 ~/wp 都是"一个项目一个文件夹"），
/// 也看直接放在文件夹里的图片；文件夹本身就是项目时也算。读不了的项目跳过，不影响其它项目。
public enum LibraryScanner {
    public static func scan(folders: [URL]) -> [WallpaperProject] {
        var seen = Set<String>()
        var projects: [WallpaperProject] = []
        for folder in folders {
            var candidates = [folder]
            if let children = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                candidates += children.filter { child in
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    return values?.isDirectory == true || values?.isRegularFile == true
                }
            }
            for candidate in candidates {
                let key = candidate.standardizedFileURL.path
                guard !seen.contains(key) else { continue }
                let project: WallpaperProject?
                if WallpaperProject.isImageFile(candidate) {
                    let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
                    project = values?.isRegularFile == true ? WallpaperProject(imageFile: candidate) : nil
                } else if FileManager.default.fileExists(
                    atPath: candidate.appendingPathComponent("project.json").path) {
                    project = try? WallpaperProject(folder: candidate)
                } else {
                    project = nil
                }
                guard let project else { continue }
                seen.insert(key)
                projects.append(project)
            }
        }
        return projects.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// 壁纸库包含哪些文件夹，存在设置里。没设置过时用统一文件夹里的 Workshop（存在的话）
public final class LibraryFolderStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "libraryFolders"
    private let fallback: URL
    /// 加入 / 移除文件夹后调用（参数是"加入 <路径>" / "移除 <路径>"），App 用它写日志
    public var onChange: ((String) -> Void)?

    public init(defaults: UserDefaults = AppFolder.settings, fallback: URL? = nil) {
        self.defaults = defaults
        self.fallback = fallback ?? AppFolder.workshop
    }

    public var folders: [URL] {
        if let paths = defaults.stringArray(forKey: key) {
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        return FileManager.default.fileExists(atPath: fallback.path) ? [fallback] : []
    }

    public func add(_ folder: URL) {
        var current = folders.map(\.standardizedFileURL.path)
        let path = folder.standardizedFileURL.path
        guard !current.contains(path) else { return }
        current.append(path)
        defaults.set(current, forKey: key)
        onChange?("加入 \(path)")
    }

    public func remove(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        let current = folders.map(\.standardizedFileURL.path)
        guard current.contains(path) else { return }
        defaults.set(current.filter { $0 != path }, forKey: key)
        onChange?("移除 \(path)")
    }
}
