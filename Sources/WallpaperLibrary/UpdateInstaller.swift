import CryptoKit
import Foundation
import Security

/// 自动更新：把 GitHub 发布里的安装包（.dmg）下载下来、逐项核对、拷出新的 App，再原子地替换正在用的那份。
///
/// 核对的顺序（任何一步不对就放弃，正在用的 App 一点不动）：
/// 1. 下载地址只认这个仓库自己的发布附件（见 `UpdateCheck.isReleaseAsset`），走 https；
/// 2. 安装包的 SHA-256 和同一个发布里的校验文件（`<安装包>.sha256`）一致——防下载出错、被截断；
/// 3. 只读挂载 dmg，拷出里面的 App：Bundle ID 和现在的一样、版本号等于发布的版本而且比现在新（不会被降级）；
/// 4. 代码签名完整（`SecStaticCodeCheckValidity`，严格模式、含嵌套代码）。现在的 App 带开发者证书签名时，
///    还要求新版是同一个团队签的；现在是临时签名时没有身份可比，只能靠前面几条。
///
/// 下载时用 URLSession，不带"来自互联网"的隔离标记；替换后重新打开不会再被 Gatekeeper 拦一次。
/// 临时签名的版本每次签名都不一样，系统会重新询问文件访问等权限（和手动替换一样）。
public enum UpdateInstaller {
    public enum Failure: LocalizedError, Equatable {
        case noPackage
        case notNewer(String)
        case download(String)
        case checksumMissing
        case checksumMismatch
        case mount(String)
        case noApp
        case wrongApp(String)
        case invalidSignature(String)
        case cannotReplace(String)

        public var errorDescription: String? {
            switch self {
            case .noPackage: String(localized: "这个版本的发布里没有安装包或校验文件")
            case .notNewer(let version): String(localized: "\(version) 不比现在的版本新")
            case .download(let reason): String(localized: "下载失败：\(reason)")
            case .checksumMissing: String(localized: "校验文件里没有这个安装包的 SHA-256")
            case .checksumMismatch: String(localized: "下载的安装包和发布的校验值对不上")
            case .mount(let reason): String(localized: "打不开安装包：\(reason)")
            case .noApp: String(localized: "安装包里没有找到 App")
            case .wrongApp(let reason): String(localized: "安装包里的 App 不对：\(reason)")
            case .invalidSignature(let reason): String(localized: "新版的代码签名不对：\(reason)")
            case .cannotReplace(let reason): String(localized: "没法替换现在的 App：\(reason)")
            }
        }
    }

    /// 下载好、核对过的新版本
    public struct Prepared: Equatable, Sendable {
        public let version: String
        /// 拷出来的新 App（在 `workDirectory/<版本>/` 下）
        public let app: URL
    }

    /// 下载并核对 `info` 这一版，返回拷出来的新 App。
    /// - Parameters:
    ///   - bundleIdentifier: 现在这个 App 的 Bundle ID，新版必须一样
    ///   - teamIdentifier: 现在这个 App 签名的团队；nil 表示临时签名（没有身份可比）
    ///   - workDirectory: 放下载和拷出来的 App 的地方（`~/WallPort/Cache/Updates`）
    public static func prepare(
        _ info: UpdateInfo, bundleIdentifier: String, currentVersion: String, teamIdentifier: String?,
        workDirectory: URL, session: URLSession = .shared
    ) async throws -> Prepared {
        guard let package = info.package, let checksum = info.checksum else { throw Failure.noPackage }
        guard UpdateCheck.compare(info.version, currentVersion) == .orderedDescending else {
            throw Failure.notNewer(info.version)
        }
        let manager = FileManager.default
        let folder = workDirectory.appendingPathComponent(info.version, isDirectory: true)
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let expected = try parseChecksum(
            String(decoding: try await download(checksum, session: session, limit: 64 * 1024), as: UTF8.self),
            fileName: package.lastPathComponent)
        let dmg = folder.appendingPathComponent(package.lastPathComponent)
        try await downloadFile(package, to: dmg, session: session)
        guard try sha256(of: dmg) == expected else { throw Failure.checksumMismatch }

        let app = try extractApp(fromDMG: dmg, into: folder, bundleIdentifier: bundleIdentifier)
        try? manager.removeItem(at: dmg)
        try validate(
            app: app, bundleIdentifier: bundleIdentifier, version: info.version, currentVersion: currentVersion,
            teamIdentifier: teamIdentifier)
        return Prepared(version: info.version, app: app)
    }

    // MARK: - 下载

    private static func download(_ url: URL, session: URLSession, limit: Int) async throws -> Data {
        let (data, response) = try await session.data(for: request(url))
        try check(response)
        guard data.count <= limit else { throw Failure.download(String(localized: "校验文件太大")) }
        return data
    }

    private static func downloadFile(_ url: URL, to destination: URL, session: URLSession) async throws {
        let (temporary, response) = try await session.download(for: request(url))
        try check(response)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func request(_ url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.download("HTTP \(status)") }
        // 跳转以后的地址（GitHub 把附件放在别的主机上）也必须是 https
        guard response.url?.scheme?.lowercased() == "https" else { throw Failure.download(String(localized: "不是 https")) }
    }

    // MARK: - 校验值

    /// `shasum -a 256` 的输出（"<64 位十六进制>  <文件名>"，一行一个）里找出这个文件的校验值
    static func parseChecksum(_ text: String, fileName: String) throws -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            // 文件名前面可能带 "*"（二进制模式）
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard name == fileName, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            return hash
        }
        throw Failure.checksumMissing
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 拷出 App

    /// 只读挂载 dmg（不在访达里显示、不自动打开），把里面 Bundle ID 对得上的 App 拷出来，再推出
    static func extractApp(fromDMG dmg: URL, into folder: URL, bundleIdentifier: String) throws -> URL {
        let manager = FileManager.default
        let mount = folder.appendingPathComponent("mount", isDirectory: true)
        try manager.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, "-quiet",
        ])
        guard attach.status == 0 else { throw Failure.mount(attach.output) }
        defer {
            if (try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]))?.status != 0 {
                _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            }
            try? manager.removeItem(at: mount)
        }
        let candidates = ((try? manager.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" && !isSymbolicLink($0) }
        guard let source = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == bundleIdentifier })
            ?? candidates.first
        else { throw Failure.noApp }
        let app = folder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try? manager.removeItem(at: app)
        // ditto 原样拷：符号链接、扩展属性、代码签名都保留
        let copy = try run("/usr/bin/ditto", [source.path, app.path])
        guard copy.status == 0 else { throw Failure.mount(copy.output) }
        return app
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    // MARK: - 核对 App

    static func validate(
        app: URL, bundleIdentifier: String, version: String, currentVersion: String, teamIdentifier: String?
    ) throws {
        guard let bundle = Bundle(url: app), let info = NSDictionary(
            contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else { throw Failure.noApp }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == bundleIdentifier else {
            throw Failure.wrongApp(String(localized: "Bundle ID 是 \(identifier)，不是 \(bundleIdentifier)"))
        }
        let packaged = info["CFBundleShortVersionString"] as? String ?? ""
        guard packaged == version else {
            throw Failure.wrongApp(String(localized: "版本是 \(packaged)，发布写的是 \(version)"))
        }
        guard UpdateCheck.compare(packaged, currentVersion) == .orderedDescending else { throw Failure.notNewer(packaged) }
        guard bundle.executableURL.map({ FileManager.default.isExecutableFile(atPath: $0.path) }) == true else {
            throw Failure.noApp
        }
        try checkSignature(of: app, bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
    }

    /// 代码签名完整（严格模式、所有架构、嵌套代码）；给了团队时还要求是这个团队、这个 Bundle ID 的开发者证书签名
    static func checkSignature(of app: URL, bundleIdentifier: String, teamIdentifier: String?) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure.invalidSignature(String(localized: "读不出签名"))
        }
        var requirement: SecRequirement?
        if let teamIdentifier {
            let text = "anchor apple generic and identifier \"\(bundleIdentifier)\""
                + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                throw Failure.invalidSignature(String(localized: "签名要求写错了"))
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw Failure.invalidSignature(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")
        }
    }

    /// 签名所属的团队（开发者证书签名才有）；`app` 为 nil 时看正在运行的这个 App
    public static func teamIdentifier(of app: URL? = nil) -> String? {
        var code: SecStaticCode?
        if let app {
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess else { return nil }
        } else {
            var running: SecCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                  SecCodeCopyStaticCode(running, [], &code) == errSecSuccess
            else { return nil }
        }
        var information: CFDictionary?
        guard let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - 替换

    /// 不能替换 `app` 的原因；nil 表示可以。直接从 .dmg、或者没挪过地方的下载文件夹里打开时，macOS 把 App 放在
    /// 随机的只读位置运行（App Translocation），替换的是临时副本；所在文件夹或 App 本身写不进去时也不行
    public static func replacementBlocker(for app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") { return String(localized: "App 在临时位置运行（从安装包里直接打开的）") }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return String(localized: "App 在只读的磁盘上")
        }
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: app.deletingLastPathComponent().path),
              manager.isWritableFile(atPath: app.path)
        else { return String(localized: "没有写 \(app.deletingLastPathComponent().path) 的权限") }
        return nil
    }

    /// 用核对过的新版替换 `app`：先在同一个卷上拷一份（APFS 上是克隆，几乎不花时间），再原子交换，
    /// 中途失败的话旧的原样留着。正在运行的进程不受影响，退出后再打开就是新版
    public static func install(_ prepared: Prepared, replacing app: URL) throws {
        if let reason = replacementBlocker(for: app) { throw Failure.cannotReplace(reason) }
        let manager = FileManager.default
        let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? manager.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        try manager.copyItem(at: prepared.app, to: staged)
        do {
            _ = try manager.replaceItemAt(app, withItemAt: staged)
        } catch {
            throw Failure.cannotReplace(error.localizedDescription)
        }
    }

    // MARK: - 工具

    /// 跑一个系统工具，等它结束，返回退出码和输出（stdout + stderr）
    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
