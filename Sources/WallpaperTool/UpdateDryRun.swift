import Foundation
import WallpaperLibrary

/// 自动更新的全流程演练（不启动 App）：读仓库最新的正式发布 → 下载安装包和校验文件 → 核对 → 拷出新 App；
/// 给了 `target` 就把它替换成新版（拿一份副本试，别用正在用的那份）。发布之后用它确认这一版能被自动更新装上
func updateDryRun(repository: String, currentVersion: String, bundleIdentifier: String, target: URL?) async -> Int32 {
    do {
        let info = try await UpdateCheck.fetch(repository: repository)
        print("最新发布：\(info.version)  \(info.url.absoluteString)")
        print("安装包：\(info.package?.absoluteString ?? "没有（不能自动更新）")")
        print("校验文件：\(info.checksum?.absoluteString ?? "没有（不能自动更新）")")
        guard UpdateCheck.newer(info, currentVersion: currentVersion, skippedVersion: nil) != nil else {
            print("\(info.version) 不比 \(currentVersion) 新，不更新")
            return 0
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("WallPortUpdate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let started = Date()
        let team = target.flatMap { UpdateInstaller.teamIdentifier(of: $0) }
        let prepared = try await UpdateInstaller.prepare(
            info, bundleIdentifier: bundleIdentifier, currentVersion: currentVersion, teamIdentifier: team,
            workDirectory: work)
        print(String(
            format: "✓ 下载并核对好（%.1f 秒，签名%@）：%@", Date().timeIntervalSince(started),
            team.map { "要求团队 \($0)" } ?? "按临时签名核对", prepared.app.path))
        guard let target else { return 0 }
        if let reason = UpdateInstaller.replacementBlocker(for: target) {
            print("✗ 不能替换 \(target.path)：\(reason)")
            return 1
        }
        try UpdateInstaller.install(prepared, replacing: target)
        let installed = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]
        print("✓ 已把 \(target.path) 换成 \(installed as? String ?? "?")")
        return 0
    } catch {
        print("✗ \(error.localizedDescription)")
        return 1
    }
}
