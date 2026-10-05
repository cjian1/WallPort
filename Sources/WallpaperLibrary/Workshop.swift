import DesktopHost
import Foundation

/// Steam 创意工坊（Wallpaper Engine 的 appid 431960）的编号、网址和本机下载目录。
///
/// 浏览走公开网页和 Web API（`WorkshopCatalog`），登录 / 订阅 / 下载走 Steam 客户端协议（`WorkshopNative`）。
public enum Workshop {
    public static let appID = "431960"

    /// 条目的详情页（"在 Steam 上查看"用默认浏览器打开）
    public static func itemURL(_ id: String) -> URL {
        URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
    }

    /// 从创意工坊下载的条目放在这里：统一文件夹里的 `Workshop`（每个条目一个以编号命名的文件夹），
    /// 整个文件夹加进壁纸库；同步订阅只看这里有没有
    public static var downloadDirectory: URL { AppFolder.workshop }

    /// 以前放创意工坊下载的地方（M7 时 SteamCMD 的目录结构、MacWallpaper/Workshop、Steam 的 WE 文件夹），
    /// 启动时由 `AppFolderMigration` 挪过来；统一文件夹里已经有同一个编号时旧的留在原处，照样算"从创意工坊下载的"
    public static var previousDownloadDirectories: [URL] {
        AppFolderMigration.Legacy(home: FileManager.default.homeDirectoryForCurrentUser).workshopDirectories
    }

    /// 所有放着创意工坊下载的目录（现在的在前）
    public static var downloadDirectories: [URL] { [downloadDirectory] + previousDownloadDirectories }

    /// 这个目录里有没有创意工坊的项目（按编号命名、带 project.json 的文件夹）
    public static func containsItems(_ directory: URL) -> Bool {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return children.contains { child in
            itemID(ofProjectFolder: child) != nil
                && FileManager.default.fileExists(atPath: child.appendingPathComponent("project.json").path)
        }
    }

    /// 这些文件夹里已经有的创意工坊条目：按编号命名、带 project.json 的子文件夹。
    /// 要逐个读磁盘（壁纸库几百个条目时约 6 毫秒），放在后台线程调，别在界面刷新时反复调
    public static func localItemIDs(in folders: [URL]) -> Set<String> {
        var ids: Set<String> = []
        for folder in folders {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children {
                guard let id = itemID(ofProjectFolder: child),
                      FileManager.default.fileExists(atPath: child.appendingPathComponent("project.json").path)
                else { continue }
                ids.insert(id)
            }
        }
        return ids
    }

    public enum SubscribeResult: Equatable, Sendable {
        case done
        case notLoggedIn
        case failed(String)
    }

    /// 项目文件夹名就是创意工坊编号时返回它（WE 在 Windows 上、创意工坊下载目录里的文件夹都按编号命名）
    public static func itemID(ofProjectFolder folder: URL) -> String? {
        let name = folder.standardizedFileURL.lastPathComponent
        return isItemID(name) ? name : nil
    }

    /// 创意工坊编号：纯数字，现在的编号都是 9–10 位
    public static func isItemID(_ text: String) -> Bool {
        (6...20).contains(text.count) && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber)
    }

    /// Steam 账户名称（登录用的名字，不是昵称）只有字母、数字和 `_ . -`；
    /// 在发给 Steam 之前先挡掉明显填错的（比如填了昵称、邮箱）
    public static func isValidAccountName(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }
}

/// 创意工坊相关的错误（浏览页、详情接口）
public struct WorkshopError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
