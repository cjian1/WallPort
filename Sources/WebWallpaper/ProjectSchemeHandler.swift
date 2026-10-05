import Foundation
import UniformTypeIdentifiers
import WebKit

/// 把 wallpaper://project/<相对路径> 映射到项目文件夹里的文件。
///
/// 不直接用 file:// 加载，是因为 file:// 页面里用 fetch/XHR 读同目录的文件会被 WebKit 拦下，
/// 而不少网页壁纸（尤其是 WebGL 库的资源加载器）正是这样读贴图和配置的。
/// 走自定义协议后这些请求是同源的，同时访问范围被限制在项目文件夹之内。
@MainActor
final class ProjectSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "wallpaper"
    nonisolated static let host = "project"
    /// 开放区间请求（bytes=0-，视频加载时常见）一次最多回这么多字节，否则会把整个视频读进内存。
    /// 回得少一些，WebKit 会按 Content-Range 接着要。不带 Range 的普通请求总是完整返回
    nonisolated static let maxChunk = 4 * 1024 * 1024

    private let folder: URL

    init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    nonisolated static func url(for relativePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + relativePath
        return components.url
    }

    /// 请求对应的项目内文件；越出项目文件夹、不存在或是目录时返回 nil。
    /// 比较的是展开符号链接以后的真实路径：壁纸文件夹里放一个指向外面的链接（例如指向 ~ 的），
    /// 只按字面路径比较的话网页就能顺着它读到用户别的文件。指向文件夹里面的链接、文件夹本身是链接，照常可用
    nonisolated static func file(for url: URL, in folder: URL) -> URL? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let relative = String(url.path.drop(while: { $0 == "/" }))
        guard !relative.isEmpty else { return nil }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        return file
    }

    nonisolated static func mimeType(for file: URL) -> String {
        let fileExtension = file.pathExtension.lowercased()
        // WebAssembly.instantiateStreaming 要求准确的类型；系统类型表里未必有这两项
        if let known = ["wasm": "application/wasm", "mjs": "text/javascript"][fileExtension] { return known }
        let type = UTType(filenameExtension: fileExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        // 自定义协议的文本不写 charset 时，WebKit 可能按 Latin-1 解码，中文会乱码
        return type?.conforms(to: .text) == true ? mime + "; charset=utf-8" : mime
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.file(for: url, in: folder) else {
            respond(task, status: 404, headers: [:], body: Data())
            return
        }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let size = Int(try handle.seekToEnd())
            var headers = ["Content-Type": Self.mimeType(for: file), "Accept-Ranges": "bytes"]

            let range: ClosedRange<Int>?
            if let header = task.request.value(forHTTPHeaderField: "Range") {
                guard let parsed = ByteRange.parse(header, fileSize: size, maxLength: Self.maxChunk) else {
                    respond(task, status: 416, headers: ["Content-Range": "bytes */\(size)"], body: Data())
                    return
                }
                range = parsed
            } else {
                range = nil
            }

            if let range {
                try handle.seek(toOffset: UInt64(range.lowerBound))
                let body = try handle.read(upToCount: range.count) ?? Data()
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
                respond(task, status: 206, headers: headers, body: body)
            } else {
                try handle.seek(toOffset: 0)
                respond(task, status: 200, headers: headers, body: try handle.readToEnd() ?? Data())
            }
        } catch {
            task.didFailWithError(error)
        }
    }

    /// 每个请求都在 start 里同步答完，没有进行中的任务需要取消
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, status: Int, headers: [String: String], body: Data) {
        var headers = headers
        headers["Content-Length"] = String(body.count)
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}

/// HTTP Range 请求头，只支持单个区间
enum ByteRange {
    /// 解析 "bytes=a-b"、"bytes=a-"、"bytes=-n"。只有开放区间（bytes=a-）会被截到 openEndedLimit 字节，
    /// 写明了终点的请求按原样回答。越界或格式不对返回 nil
    static func parse(_ header: String, fileSize: Int, maxLength openEndedLimit: Int) -> ClosedRange<Int>? {
        let prefix = "bytes="
        guard fileSize > 0, openEndedLimit > 0, header.hasPrefix(prefix) else { return nil }
        let spec = header.dropFirst(prefix.count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let endText = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        let last = fileSize - 1

        if startText.isEmpty {
            guard let suffix = Int(endText), suffix > 0 else { return nil }
            return max(0, fileSize - suffix)...last
        }
        guard let start = Int(startText), start >= 0, start <= last else { return nil }
        if endText.isEmpty {
            return start...min(last, start + openEndedLimit - 1)
        }
        guard let end = Int(endText), end >= start else { return nil }
        return start...min(end, last)
    }
}
