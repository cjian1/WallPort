import Foundation
import Testing
@testable import DesktopHost

@Suite struct EventLogTests {
    /// 壁纸常驻后台一跑就是几周：写着写着超过上限也要滚动，不能等到下次启动
    @Test func rotatesWhileRunningOnceTheFileGetsTooBig() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eventlog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("desktop.log")
        let log = EventLog(fileURL: file, maxFileSize: 2_000)
        for index in 0..<100 { log.write("第 \(index) 行：显示器参数变化") }

        let current = try Data(contentsOf: file).count
        let previous = try Data(contentsOf: file.appendingPathExtension("1")).count
        #expect(current <= 2_200, "当前文件该在上限附近重新开始，实际 \(current) 字节")
        #expect(previous > 2_000, "滚动出去的上一份该是写满的那份")
        let last = try String(contentsOf: file, encoding: .utf8)
        #expect(last.contains("第 99 行"), "最新的一行留在当前文件里")
    }
}
