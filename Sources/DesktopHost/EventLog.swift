import Foundation
import os

/// 诊断日志：同时写入系统日志和一个纯文本文件。
///
/// M0 的验收靠长时间运行之后回看记录，纯文本文件比系统日志更容易翻阅和分享。
/// 写入是同步的：频率很低（每分钟几条），换来的是进程退出或崩溃前的最后几行不会丢。
public final class EventLog: @unchecked Sendable {
    public let fileURL: URL

    private let logger = Logger(subsystem: "local.macwallpaper", category: "desktop")
    private let lock = NSLock()
    private let formatter: DateFormatter

    /// 超过这个大小就滚动一次，只保留上一份
    private static let maxFileSize = 5 * 1024 * 1024

    public static var defaultFileURL: URL {
        AppFolder.logs.appendingPathComponent("desktop.log")
    }

    public init(fileURL: URL = EventLog.defaultFileURL) {
        self.fileURL = fileURL
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
    }

    public func write(_ message: String) {
        logger.info("\(message, privacy: .public)")

        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func rotateIfNeeded() {
        let manager = FileManager.default
        guard let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > Self.maxFileSize
        else { return }
        let previous = fileURL.appendingPathExtension("1")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: fileURL, to: previous)
    }
}
