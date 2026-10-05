import Foundation

/// 创意工坊预览图的下载：网格里只要第一帧，不用整张动图。
///
/// 预览图一半以上是 GIF 动图，一张 0.6–1 MB，第一帧却只有几十 KB（2026-10-01 量一页 30 张：GIF 的第一帧
/// 32–112 KB，整页全下要 20 MB）。所以先要前 128 KB：是 GIF、而且第一帧已经完整（按 GIF 的块结构判断）
/// 就到此为止；不是 GIF（JPEG 要整张才解得出来）或者第一帧还没完的，再把剩下的要回来。
/// Steam 的图片服务器支持按字节范围取（206 Partial Content）
public enum WorkshopPreview {
    /// 第一次要的字节数
    public static let firstRequestBytes = 128 * 1024

    /// 下预览图（够解出第一帧就行）。服务器不认范围请求时就是整张
    public static func data(for url: URL, client: any HTTPClient) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(firstRequestBytes - 1)", forHTTPHeaderField: "Range")
        let (head, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            try WorkshopCatalog.check(response)
            return head
        }
        // 整张就这么大，或者是第一帧已经完整的 GIF：够了
        if let total = totalLength(http), head.count >= total { return head }
        if gifFirstFrameEnd(in: head) != nil { return head }
        var rest = URLRequest(url: url)
        rest.setValue("bytes=\(head.count)-", forHTTPHeaderField: "Range")
        let (tail, tailResponse) = try await client.data(for: rest)
        guard let tailHTTP = tailResponse as? HTTPURLResponse, tailHTTP.statusCode == 206 else {
            // 第二次服务器给了整张：用整张
            try WorkshopCatalog.check(tailResponse)
            return tail
        }
        return head + tail
    }

    /// `Content-Range: bytes 0-131071/841855` 里的总长度
    static func totalLength(_ response: HTTPURLResponse) -> Int? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = range.lastIndex(of: "/")
        else { return nil }
        return Int(range[range.index(after: slash)...])
    }

    /// GIF 第一帧的图像数据结束在哪（这个位置之前的字节就能完整解出第一帧）；不是 GIF、或者第一帧还没下完时为 nil。
    ///
    /// 结构：文件头 6 字节 + 逻辑屏幕描述 7 字节（+ 全局调色板）；之后是若干扩展块（0x21，子块串）和图像块
    /// （0x2C：描述 9 字节 + 局部调色板 + LZW 码长 1 字节 + 子块串）。子块串是"长度 + 数据"一节一节，长度 0 结束
    public static func gifFirstFrameEnd(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return nil }  // "GIF"
        var index = 13
        if bytes[10] & 0x80 != 0 { index += 3 << ((Int(bytes[10]) & 7) + 1) }
        /// 跳过一串子块，返回结束标记之后的位置；数据不够时为 nil
        func skipSubBlocks(from start: Int) -> Int? {
            var position = start
            while position < bytes.count {
                let length = Int(bytes[position])
                position += 1
                if length == 0 { return position }
                position += length
            }
            return nil
        }
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:  // 扩展：标签 1 字节 + 子块串
                guard index + 2 <= bytes.count, let next = skipSubBlocks(from: index + 2) else { return nil }
                index = next
            case 0x2C:  // 图像
                guard index + 10 <= bytes.count else { return nil }
                var position = index + 10
                let packed = bytes[index + 9]
                if packed & 0x80 != 0 { position += 3 << ((Int(packed) & 7) + 1) }
                position += 1  // LZW 最小码长
                guard position <= bytes.count else { return nil }
                return skipSubBlocks(from: position)
            default:  // 结尾（0x3B）或者坏数据：没有能解的帧
                return nil
            }
        }
        return nil
    }
}
