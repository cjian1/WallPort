import AppKit

/// 发布相关的文件和地址：隐私政策、使用条款（App/Legal，打包时由 scripts/fill-legal.sh 填上发布者、联系方式），
/// 以及发布脚本写进 Info.plist 的网站、支持地址
@MainActor
enum PublisherInfo {
    enum Document: String {
        case privacy = "Privacy", terms = "Terms"
    }

    /// 打包进 App 的 Contents/Resources/Legal；开发时（可执行文件不在 .app 里）用仓库里的 App/Legal（占位没填）
    static func url(of document: Document) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Legal/\(document.rawValue).html"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("App/Legal/\(document.rawValue).html"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 在浏览器里打开（离线也能看，和这一版一起发布的那份）
    static func open(_ document: Document) {
        guard let url = url(of: document) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 发布在哪个 GitHub 仓库（"用户名/仓库名"，发布脚本按 GITHUB_REPO 写进 Info.plist）；开发版没有
    static var gitHubRepository: String? {
        (Bundle.main.object(forInfoDictionaryKey: "WallPortGitHubRepo") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 项目主页：发布脚本给了 WEBSITE_URL 就用它，否则是 GitHub 仓库页；开发版没有
    static var websiteURL: URL? {
        infoURL("WallPortWebsiteURL") ?? gitHubRepository.flatMap { URL(string: "https://github.com/\($0)") }
    }

    /// 反馈问题：发布脚本给了 SUPPORT_URL（网页或 mailto:）就用它，否则是 GitHub 仓库的 Issues；开发版没有
    static var supportURL: URL? {
        infoURL("WallPortSupportURL") ?? gitHubRepository.flatMap { URL(string: "https://github.com/\($0)/issues/new/choose") }
    }

    private static func infoURL(_ key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap(URL.init(string:))
    }
}
