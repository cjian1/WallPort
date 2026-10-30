import Foundation

/// 文件夹里的文件（含子文件夹），按路径的自然顺序（2 在 10 前面）。跳过隐藏文件（访达留下的 .DS_Store）
/// 和 Windows 的缩略图缓存。网页壁纸的目录类属性、壁坞自己放的幻灯片都用它
public enum DirectoryFiles {
    private static let junk: Set<String> = ["thumbs.db", "desktop.ini"]

    public static func list(in folder: URL, limit: Int = 5000) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        while files.count < limit, let file = enumerator.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !junk.contains(file.lastPathComponent.lowercased())
            else { continue }
            files.append(file.standardizedFileURL)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
