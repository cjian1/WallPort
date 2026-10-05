import Foundation

/// Wallpaper Engine 自带素材（Windows 上 `wallpaper_engine/assets` 的副本：着色器、材质、粒子预设……）。
/// 场景壁纸要用；壁坞不分发它们，由用户从自己的 WE 安装里拷过来，导入时拷进统一文件夹的 `Assets/`
public enum WallpaperEngineAssets {
    /// 认得出的标志：这几个子文件夹都在
    static let requiredFolders = ["shaders", "materials"]

    /// 用户选的文件夹就是素材文件夹，或者选的是 WE 的安装目录（里面有 `assets`）：返回素材文件夹；都不是时 nil
    public static func locate(in folder: URL) -> URL? {
        for candidate in [folder, folder.appendingPathComponent("assets", isDirectory: true)] where isAssetsFolder(candidate) {
            return candidate
        }
        return nil
    }

    public static func isAssetsFolder(_ folder: URL) -> Bool {
        requiredFolders.allSatisfy { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// 拷进 `destination`：先拷到旁边的临时文件夹，拷完再换上；中途失败时原来的不动
    public static func install(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let source = source.standardizedFileURL, destination = destination.standardizedFileURL
        guard source != destination else { return }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).importing", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.copyItem(at: source, to: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}
