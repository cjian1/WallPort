import CoreGraphics
import Foundation
import ImageIO

/// 预览图的缩略图（创意工坊网格、本机壁纸库的卡片）：只要一帧，不用整张动图。
///
/// 预览图一半以上是 GIF 动图，一张 0.6–1 MB，一帧却只有几十 KB（2026-10-01 量一页 30 张：GIF 的第一帧
/// 32–112 KB，整页全下要 20 MB）。所以先要前 128 KB：是 GIF、而且下完的帧里已经有能看的一帧（按 GIF 的块结构判断
/// 哪几帧完整）就到此为止；不是 GIF（JPEG 要整张才解得出来）或者还没有能看的帧，再把剩下的要回来。
/// Steam 的图片服务器支持按字节范围取（206 Partial Content）
///
/// **第一帧可能是空的**：不少视频壁纸的 GIF 预览第一帧是纯黑的（2026-11-03 量网格里 3 张黑卡片：第一帧平均亮度 0，
/// 第二帧起 100–157；壁坞缓存的 1710 张缩略图里 64 张是这样的全黑图），只取第一帧的话网格里就是一块黑。
/// 所以按顺序找第一帧看得见的（`isBlank`），前 `frameSearchLimit` 帧都是空的才用第一帧
public enum WorkshopPreview {
    /// 第一次要的字节数
    public static let firstRequestBytes = 128 * 1024
    /// 最多往后找几帧（GIF 预览一般 50 帧、每帧 0.04 秒；纯黑的第一帧只有几百字节，前 128 KB 里通常有六七帧）
    static let frameSearchLimit = 30

    /// 下预览图并做成缩略图（长边不超过 `maxPixelSize`），够用就不再往下下。服务器不认范围请求时就是整张
    public static func thumbnail(for url: URL, client: any HTTPClient, maxPixelSize: Int) async throws -> CGImage? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(firstRequestBytes - 1)", forHTTPHeaderField: "Range")
        let (head, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            try WorkshopCatalog.check(response)
            return thumbnail(of: head, maxPixelSize: maxPixelSize)
        }
        // 整张就这么大：够了
        if let total = totalLength(http), head.count >= total { return thumbnail(of: head, maxPixelSize: maxPixelSize) }
        // GIF：下完的帧里有能看的一帧就够了；要找的帧都下完了、也都是空的，再往下下也没用
        let complete = gifFrameEnds(in: head).count
        if complete > 0, let source = CGImageSourceCreateWithData(head as CFData, nil),
           let pick = firstShowableFrame(of: source, frames: complete, maxPixelSize: maxPixelSize),
           pick.showable || complete >= frameSearchLimit {
            return pick.image
        }
        var rest = URLRequest(url: url)
        rest.setValue("bytes=\(head.count)-", forHTTPHeaderField: "Range")
        let (tail, tailResponse) = try await client.data(for: rest)
        guard let tailHTTP = tailResponse as? HTTPURLResponse, tailHTTP.statusCode == 206 else {
            // 第二次服务器给了整张：用整张
            try WorkshopCatalog.check(tailResponse)
            return thumbnail(of: tail, maxPixelSize: maxPixelSize)
        }
        return thumbnail(of: head + tail, maxPixelSize: maxPixelSize)
    }

    /// 缩略图：第一帧看得见的（动图的第一帧是空帧时往后找），都是空的就用第一帧
    public static func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        firstShowableFrame(of: source, frames: CGImageSourceGetCount(source), maxPixelSize: maxPixelSize)?.image
    }

    static func thumbnail(of data: Data, maxPixelSize: Int) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { thumbnail(of: $0, maxPixelSize: maxPixelSize) }
    }

    /// 前 `frames` 帧里（最多看 `frameSearchLimit` 帧）第一帧看得见的；都是空帧时 `showable` 为 false，图用第一帧
    private static func firstShowableFrame(
        of source: CGImageSource, frames: Int, maxPixelSize: Int
    ) -> (image: CGImage, showable: Bool)? {
        var first: CGImage?
        for index in 0..<min(frames, frameSearchLimit) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            if !isBlank(image) { return (image, true) }
            if first == nil { first = image }
        }
        return first.map { ($0, false) }
    }

    /// 空帧：几乎全黑或者全透明——缩到 32×32，亮度超过 24（满分 255）的格子不到 1%。
    /// 2026-11-03 量壁坞缓存的 1710 张缩略图：64 张全黑的最亮的格子也不超过 18；最暗的正常图也有 2% 的格子是亮的
    public static func isBlank(_ image: CGImage) -> Bool {
        let side = 32
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        // 透明的地方按黑算（预乘了透明度，透明的格子颜色是 0）
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        context.clear(bounds)
        context.draw(image, in: bounds)
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * side)
        var lit = 0
        for y in 0..<side {
            for x in 0..<side {
                let pixel = pixels + y * context.bytesPerRow + x * 4
                // 亮度 × 1000（BT.601 权重），和 24 × 1000 比
                if 299 * Int(pixel[0]) + 587 * Int(pixel[1]) + 114 * Int(pixel[2]) > 24_000 { lit += 1 }
            }
        }
        return lit * 100 < side * side
    }

    /// `Content-Range: bytes 0-131071/841855` 里的总长度
    static func totalLength(_ response: HTTPURLResponse) -> Int? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = range.lastIndex(of: "/")
        else { return nil }
        return Int(range[range.index(after: slash)...])
    }

    /// GIF 里已经完整的每一帧的图像数据结束在哪（这个位置之前的字节就能完整解出这一帧和它前面的帧）；
    /// 不是 GIF、或者第一帧还没下完时是空的。
    ///
    /// 结构：文件头 6 字节 + 逻辑屏幕描述 7 字节（+ 全局调色板）；之后是若干扩展块（0x21，子块串）和图像块
    /// （0x2C：描述 9 字节 + 局部调色板 + LZW 码长 1 字节 + 子块串）。子块串是"长度 + 数据"一节一节，长度 0 结束
    public static func gifFrameEnds(in data: Data) -> [Int] {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return [] }  // "GIF"
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
        var ends: [Int] = []
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:  // 扩展：标签 1 字节 + 子块串
                guard index + 2 <= bytes.count, let next = skipSubBlocks(from: index + 2) else { return ends }
                index = next
            case 0x2C:  // 图像
                guard index + 10 <= bytes.count else { return ends }
                var position = index + 10
                let packed = bytes[index + 9]
                if packed & 0x80 != 0 { position += 3 << ((Int(packed) & 7) + 1) }
                position += 1  // LZW 最小码长
                guard position <= bytes.count, let end = skipSubBlocks(from: position) else { return ends }
                ends.append(end)
                index = end
            default:  // 结尾（0x3B）或者坏数据：后面没有帧了
                return ends
            }
        }
        return ends
    }
}
