import Foundation

/// "导出诊断信息"：把概况和日志打成一个 zip，用户发给开发者。导出之前去掉能认出人的东西：
/// Steam 账号名换成〈账号〉、用户主目录换成 ~；登录凭证、完整的设置文件不打包
public enum Diagnostics {
    /// 账号名只按整词换（账号名由字母、数字和 `_ . -` 组成），免得把别的词里碰巧相同的几个字母也换掉
    public static func sanitize(_ text: String, accounts: [String], home: String) -> String {
        var result = text
        let homePath = home.hasSuffix("/") ? String(home.dropLast()) : home
        if !homePath.isEmpty { result = result.replacingOccurrences(of: homePath, with: "~") }
        for account in Set(accounts) where !account.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: account)
            guard let pattern = try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9_.-])\(escaped)(?![A-Za-z0-9_.-])", options: [.caseInsensitive])
            else { continue }
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "〈账号〉")
        }
        return result
    }

    /// 系统给这个进程写的崩溃报告（`~/Library/Logs/DiagnosticReports` 里 `<进程名>-日期.ips` 这种），
    /// `since` 之后的，从新到旧最多 `limit` 份。用户说"闪退了"时，开发者靠它知道崩在哪
    public static func crashReports(
        in directory: URL, process: String, since: Date, limit: Int = 5, fileManager: FileManager = .default
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let reports = files.compactMap { file -> (url: URL, date: Date)? in
            let name = file.lastPathComponent
            guard name.hasPrefix(process + "-") || name.hasPrefix(process + "_"),
                  ["ips", "crash"].contains(file.pathExtension),
                  let date = try? file.resourceValues(forKeys: keys).contentModificationDate, date >= since
            else { return nil }
            return (file, date)
        }
        return reports.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }

    /// 写一个 zip：`概况.txt` 加上处理过的日志（日志文件不存在就跳过）
    public static func export(
        summary: String, logs: [URL], accounts: [String], home: String, to zip: URL,
        fileManager: FileManager = .default
    ) throws {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("WallPort-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let content = folder.appendingPathComponent(zip.deletingPathExtension().lastPathComponent, isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
        try sanitize(summary, accounts: accounts, home: home)
            .write(to: content.appendingPathComponent("概况.txt"), atomically: true, encoding: .utf8)
        for log in logs {
            guard let data = fileManager.contents(atPath: log.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            try sanitize(text, accounts: accounts, home: home)
                .write(to: content.appendingPathComponent(log.lastPathComponent), atomically: true, encoding: .utf8)
        }
        try? fileManager.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", content.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(localized: "压缩失败（ditto 返回 \(ditto.terminationStatus)）")])
        }
    }
}
