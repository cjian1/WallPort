import Foundation
import Testing
@testable import DesktopHost

/// 导出诊断信息：账号名、用户主目录在导出前去掉；zip 里有概况和日志
@Suite struct DiagnosticsTests {
    @Test func sanitizeRemovesAccountsAndHome() {
        let log = """
            创意工坊：用存着的会话登上 Steam（账号 examplegamer）
            壁纸库：文件夹加入 /Users/alice/WallPort/Workshop
            账号 ExampleGamer 的订阅；alk 字体、id=examplegamer2 不是账号
            """
        let clean = Diagnostics.sanitize(log, accounts: ["examplegamer", "al"], home: "/Users/alice")
        #expect(!clean.contains("examplegamer）") && clean.contains("账号 〈账号〉）"))
        #expect(clean.contains("账号 〈账号〉 的订阅"), "大小写不同也换")
        #expect(clean.contains("~/WallPort/Workshop") && !clean.contains("/Users/alice"))
        #expect(clean.contains("alk 字体") && clean.contains("examplegamer2"), "只换整词")
    }

    /// 只挑这个进程的、最近的崩溃报告，从新到旧
    @Test func picksRecentCrashReportsOfThisProcess() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        func report(_ name: String, daysAgo: Double) throws {
            let url = folder.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: url.path)
        }
        try report("WallPort-2026-10-01-120000.ips", daysAgo: 1)
        try report("WallPort-2026-09-30-120000.ips", daysAgo: 2)
        try report("WallPort-2026-08-01-120000.ips", daysAgo: 60)
        try report("WallPortHelper-2026-10-01-120000.ips", daysAgo: 1)
        try report("Safari-2026-10-01-120000.ips", daysAgo: 1)
        try report("WallPort-2026-10-01-120000.txt", daysAgo: 1)
        let picked = Diagnostics.crashReports(
            in: folder, process: "WallPort", since: now.addingTimeInterval(-30 * 86400), limit: 5)
        #expect(picked.map(\.lastPathComponent) == ["WallPort-2026-10-01-120000.ips", "WallPort-2026-09-30-120000.ips"])
        #expect(Diagnostics.crashReports(in: folder, process: "WallPort", since: .distantPast, limit: 1).count == 1)
    }

    @Test func exportWritesAZip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("desktop.log")
        try "账号 alice 登录\n".write(to: log, atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("壁坞诊断信息.zip")
        try Diagnostics.export(
            summary: "版本 1.0", logs: [log, root.appendingPathComponent("desktop.log.1")], accounts: ["alice"],
            home: "/Users/nobody", to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, root.appendingPathComponent("out").path]
        try unzip.run()
        unzip.waitUntilExit()
        let folder = root.appendingPathComponent("out/壁坞诊断信息")
        #expect(try String(contentsOf: folder.appendingPathComponent("概况.txt"), encoding: .utf8) == "版本 1.0")
        #expect(try String(contentsOf: folder.appendingPathComponent("desktop.log"), encoding: .utf8) == "账号 〈账号〉 登录\n")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("desktop.log.1").path))
    }
}
