import Foundation
import Testing
@testable import WallpaperLibrary

/// 假的 GitHub：按地址回固定的内容（安装包、校验文件）
private final class FakeReleaseServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [URL: Data] = [:]
    static let lock = NSLock()

    static func serve(_ files: [URL: Data]) { lock.withLock { self.files = files } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.lock.withLock { Self.files[url] }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeReleaseServer.self]
        return URLSession(configuration: configuration)
    }
}

/// 下载、核对、拷出、替换。安装包是测试现做的：一个临时签名的小 App 打成 dmg
@Suite(.serialized) struct UpdateInstallerTests {
    private static let bundleID = "io.example.wallport"
    private static let package = URL(string: "https://github.com/someone/wallport/releases/download/v1.2.0/WallPort-1.2.0.dmg")!
    private static let checksum = URL(string: "https://github.com/someone/wallport/releases/download/v1.2.0/WallPort-1.2.0.dmg.sha256")!

    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstaller-\(UUID().uuidString)")

    private func run(_ tool: String, _ arguments: [String]) throws {
        let result = try UpdateInstaller.run(tool, arguments)
        try #require(result.status == 0, "\(tool) \(arguments)：\(result.output)")
    }

    /// 一个最小的 App：Info.plist + 一个可执行的脚本，临时签名
    private func makeApp(at url: URL, bundleID: String = bundleID, version: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": "1",
            "CFBundleExecutable": "WallPort", "CFBundlePackageType": "APPL", "CFBundleName": "WallPort",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/WallPort")
        try Data("#!/bin/sh\necho \(version)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }

    /// 把 App 打成 dmg（和 release.sh 一样：UDZO，里面就是 WallPort.app）
    private func makeDMG(containing app: URL) throws -> Data {
        let stage = folder.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [app.path, stage.appendingPathComponent("WallPort.app").path])
        let dmg = folder.appendingPathComponent("\(UUID().uuidString).dmg")
        try run("/usr/bin/hdiutil", ["create", "-volname", "WallPort", "-srcfolder", stage.path, "-format", "UDZO", "-quiet", dmg.path])
        return try Data(contentsOf: dmg)
    }

    private func info(version: String = "1.2.0") -> UpdateInfo {
        UpdateInfo(
            version: version, url: URL(string: "https://github.com/someone/wallport/releases/tag/v\(version)")!,
            package: Self.package, checksum: Self.checksum)
    }

    /// 发布 `dmg`；`checksumOf` 给了就用它算校验值（模拟校验值和安装包对不上）
    private func publish(_ dmg: Data, checksumOf: Data? = nil) throws {
        let hashFile = folder.appendingPathComponent("hash-\(UUID().uuidString)")
        try (checksumOf ?? dmg).write(to: hashFile)
        let hash = try UpdateInstaller.sha256(of: hashFile)
        FakeReleaseServer.serve([
            Self.package: dmg,
            Self.checksum: Data("\(hash)  WallPort-1.2.0.dmg\n".utf8),
        ])
    }

    private func prepare(_ info: UpdateInfo, currentVersion: String = "1.1.0") async throws -> UpdateInstaller.Prepared {
        try await UpdateInstaller.prepare(
            info, bundleIdentifier: Self.bundleID, currentVersion: currentVersion, teamIdentifier: nil,
            workDirectory: folder.appendingPathComponent("work"), session: FakeReleaseServer.session)
    }

    /// 一次完整的更新：校验值对不上的不用；对得上的下载、核对、拷出新 App，再替换"正在用的"那份。
    /// （做 dmg 要好几秒，整个流程只做这一个；别的情况直接核对 App）
    @Test func downloadsVerifiesAndReplacesTheApp() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let built = folder.appendingPathComponent("build/WallPort.app")
        try makeApp(at: built, version: "1.2.0")
        let dmg = try makeDMG(containing: built)

        // 安装包和发布的校验值对不上（下载出错、被截断、被换掉）：不用它
        try publish(dmg, checksumOf: Data("别的东西".utf8))
        await #expect(throws: UpdateInstaller.Failure.checksumMismatch) { try await prepare(info()) }

        try publish(dmg)
        let prepared = try await prepare(info())
        #expect(prepared.version == "1.2.0")
        #expect(Bundle(url: prepared.app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.2.0")

        let installed = folder.appendingPathComponent("Applications/WallPort.app")
        try makeApp(at: installed, version: "1.1.0")
        #expect(UpdateInstaller.replacementBlocker(for: installed) == nil)
        try UpdateInstaller.install(prepared, replacing: installed)
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        #expect(info?["CFBundleShortVersionString"] as? String == "1.2.0")
        // 替换后的签名照样完整
        try UpdateInstaller.checkSignature(of: installed, bundleIdentifier: Self.bundleID, teamIdentifier: nil)
    }

    private func validate(_ app: URL) throws {
        try UpdateInstaller.validate(
            app: app, bundleIdentifier: Self.bundleID, version: "1.2.0", currentVersion: "1.1.0", teamIdentifier: nil)
    }

    /// 安装包里是别的 App（Bundle ID 不同）、或者版本和发布写的不一样：不用它
    @Test func rejectsTheWrongApp() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("good/WallPort.app")
        try makeApp(at: good, version: "1.2.0")
        try validate(good)

        let other = folder.appendingPathComponent("other/WallPort.app")
        try makeApp(at: other, bundleID: "io.example.other", version: "1.2.0")
        #expect(throws: UpdateInstaller.Failure.self) { try validate(other) }

        let mislabeled = folder.appendingPathComponent("mislabeled/WallPort.app")
        try makeApp(at: mislabeled, version: "1.1.5")
        #expect(throws: UpdateInstaller.Failure.self) { try validate(mislabeled) }
    }

    /// 签名之后又被改过的 App：签名核对不过；临时签名的 App 也满足不了"某个团队签的"要求
    @Test func rejectsAnAppModifiedAfterSigning() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let built = folder.appendingPathComponent("build/WallPort.app")
        try makeApp(at: built, version: "1.2.0")
        #expect(throws: UpdateInstaller.Failure.self) {
            try UpdateInstaller.checkSignature(of: built, bundleIdentifier: Self.bundleID, teamIdentifier: "ABCDE12345")
        }
        try Data("#!/bin/sh\necho changed\n".utf8).write(to: built.appendingPathComponent("Contents/MacOS/WallPort"))
        #expect {
            try validate(built)
        } throws: { error in
            guard case UpdateInstaller.Failure.invalidSignature = error else { return false }
            return true
        }
    }

    /// 不会降级，也不会"更新"成同一版
    @Test func refusesVersionsThatAreNotNewer() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: UpdateInstaller.Failure.notNewer("1.2.0")) { try await prepare(info(), currentVersion: "1.2.0") }
        await #expect(throws: UpdateInstaller.Failure.noPackage) {
            try await prepare(UpdateInfo(version: "1.3.0", url: Self.package))
        }
    }

    /// 校验文件的格式（`shasum -a 256` 的输出）
    @Test func parsesChecksumFiles() throws {
        let hash = String(repeating: "ab", count: 32)
        #expect(try UpdateInstaller.parseChecksum("\(hash.uppercased())  WallPort-1.2.0.dmg\n", fileName: "WallPort-1.2.0.dmg") == hash)
        #expect(try UpdateInstaller.parseChecksum("\(hash) *WallPort-1.2.0.dmg", fileName: "WallPort-1.2.0.dmg") == hash)
        #expect(throws: UpdateInstaller.Failure.checksumMissing) {
            try UpdateInstaller.parseChecksum("\(hash)  别的文件.dmg", fileName: "WallPort-1.2.0.dmg")
        }
        #expect(throws: UpdateInstaller.Failure.checksumMissing) {
            try UpdateInstaller.parseChecksum("abc  WallPort-1.2.0.dmg", fileName: "WallPort-1.2.0.dmg")
        }
    }

    /// 从安装包里直接打开（App Translocation）时不能替换
    @Test func translocatedAppsCannotBeReplaced() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/WallPort.app")
        #expect(UpdateInstaller.replacementBlocker(for: translocated) != nil)
    }

    /// 发布信息里的附件：只认这个仓库的发布附件，别的地址一律不下载
    @Test func onlyTrustsThisRepositorysReleaseAssets() throws {
        func release(_ dmg: String, _ sha: String) -> Data {
            Data("""
                {"tag_name": "v1.2.0", "html_url": "https://github.com/someone/wallport/releases/tag/v1.2.0",
                 "assets": [{"name": "WallPort-1.2.0.dmg", "browser_download_url": "\(dmg)"},
                            {"name": "WallPort-1.2.0.dmg.sha256", "browser_download_url": "\(sha)"}]}
                """.utf8)
        }
        let good = try UpdateCheck.parseGitHubRelease(
            release(Self.package.absoluteString, Self.checksum.absoluteString), repository: "someone/wallport")
        #expect(good.package == Self.package)
        #expect(good.checksum == Self.checksum)
        for (dmg, sha) in [
            ("https://github.com/attacker/wallport/releases/download/v1.2.0/WallPort-1.2.0.dmg", Self.checksum.absoluteString),
            ("http://github.com/someone/wallport/releases/download/v1.2.0/WallPort-1.2.0.dmg", Self.checksum.absoluteString),
            ("https://example.com/someone/wallport/releases/download/v1.2.0/WallPort-1.2.0.dmg", Self.checksum.absoluteString),
        ] {
            #expect(try UpdateCheck.parseGitHubRelease(release(dmg, sha), repository: "someone/wallport").package == nil, "\(dmg)")
        }
        // 没有校验文件就不自动下载
        let noChecksum = try UpdateCheck.parseGitHubRelease(Data("""
            {"tag_name": "v1.2.0", "html_url": "https://github.com/someone/wallport/releases/tag/v1.2.0",
             "assets": [{"name": "WallPort-1.2.0.dmg", "browser_download_url": "\(Self.package.absoluteString)"}]}
            """.utf8), repository: "someone/wallport")
        #expect(noChecksum.package == nil)
    }
}
