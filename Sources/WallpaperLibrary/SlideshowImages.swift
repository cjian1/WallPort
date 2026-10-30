import DesktopHost
import Foundation

extension WallpaperProject {
    /// 幻灯片放的图片格式
    static let slideshowImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
    ]

    /// 网页壁纸正在用的图片文件夹里的图片（壁坞自己放幻灯片用）。"正在用"是指目录类属性的显示条件成立
    /// （例如"完美壁纸"的 customdirectory 只在"幻灯片模式"下生效）、值是本机文件夹。相对路径相对于项目自己的文件夹：
    /// 分享依赖型预设时，WE 把选中的文件夹打包成预设的 directories/<属性名>。不是网页壁纸、没有这样的文件夹时返回空
    public func slideshowImages(overrides: [String: PropertyValue] = [:]) -> [URL] {
        guard kind == .web else { return [] }
        let values = propertyValues(overrides: overrides)
        for property in properties
        where property.kind == .directory && UserProperty.conditionHolds(property.condition, values: values) {
            guard case .string(let path)? = values[property.name], let directory = localDirectory(path) else { continue }
            let images = DirectoryFiles.list(in: directory)
                .filter { Self.slideshowImageExtensions.contains($0.pathExtension.lowercased()) }
            if !images.isEmpty { return images }
        }
        return []
    }

    /// 属性值指向的本机文件夹；作者电脑上的 Windows 路径、不存在的文件夹不算
    private func localDirectory(_ path: String) -> URL? {
        guard !path.isEmpty, !path.contains("\\"), path.range(of: "^[A-Za-z]:", options: .regularExpression) == nil
        else { return nil }
        let directory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : folder.appendingPathComponent(path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return directory
    }
}
