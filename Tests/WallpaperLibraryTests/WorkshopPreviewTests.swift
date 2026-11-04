import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WallpaperLibrary

/// 网格里的预览图只要一帧：GIF 动图下到有一帧完整、看得见就停，别的格式下整张；第一帧是空帧时往后找
@Suite struct WorkshopPreviewTests {
    /// 服务器假装支持按字节范围取，记下每次要了哪一段
    private final class RangeServer: HTTPClient, @unchecked Sendable {
        let body: Data
        let contentType: String
        private(set) var ranges: [String] = []
        private let lock = NSLock()

        init(body: Data, contentType: String) {
            self.body = body
            self.contentType = contentType
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            lock.withLock { ranges.append(range) }
            let spec = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(spec.first ?? "") ?? 0
            let end = min(spec.count > 1 ? Int(spec[1]) ?? body.count - 1 : body.count - 1, body.count - 1)
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType, "Content-Range": "bytes \(start)-\(end)/\(body.count)"])!
            return (slice, response)
        }
    }

    private static let thumbnailSize = 64

    /// 一帧图：`pixel(x, y)` 给出 RGBA
    private func image(size: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let (r, g, b, a) = pixel(x, y)
                let offset = (y * size + x) * 4
                pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b; pixels[offset + 3] = a
            }
        }
        return try #require(context.makeImage())
    }

    private func solid(size: Int = 160, _ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255) throws -> CGImage {
        try image(size: size) { _, _ in (r, g, b, alpha) }
    }

    /// 噪点（压不小）：每帧约 25 KB（160 边长）
    private func noise(size: Int = 160, seed: UInt32) throws -> CGImage {
        var state = seed
        return try image(size: size) { _, _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (UInt8(state >> 24), UInt8((state >> 16) & 0xFF), UInt8((state >> 8) & 0xFF), 255)
        }
    }

    private func gif(_ frames: [CGImage]) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.gif.identifier as CFString, frames.count, nil))
        for frame in frames { CGImageDestinationAddImage(destination, frame, nil) }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func jpeg(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func source(_ data: Data) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithData(data as CFData, nil))
    }

    /// 缩略图的平均颜色（0–255）
    private func averageColor(_ image: CGImage) throws -> SIMD3<Double> {
        let side = 8
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: side * side * 4)
        var sum = SIMD3<Double>()
        for i in 0..<(side * side) {
            sum += SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2]))
        }
        return sum / Double(side * side)
    }

    @Test func gifFrameEndsMarkEveryCompleteFrame() throws {
        let gif = try gif((0..<8).map { try noise(seed: UInt32($0 + 1)) })
        let ends = WorkshopPreview.gifFrameEnds(in: gif)
        #expect(ends.count == 8)
        #expect(ends[0] < gif.count / 4)
        #expect(ends == ends.sorted())
        // 第一帧结束之前的这一段就能解出完整的第一帧
        let head = try source(gif.prefix(ends[0]))
        #expect(CGImageSourceCreateImageAtIndex(head, 0, nil)?.width == 160)
        // 少一个字节就不算完整；不是 GIF 也不算
        #expect(WorkshopPreview.gifFrameEnds(in: gif.prefix(ends[0] - 1)).isEmpty)
        #expect(WorkshopPreview.gifFrameEnds(in: gif.prefix(ends[2] + 5)).count == 3)
        #expect(WorkshopPreview.gifFrameEnds(in: Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 20))).isEmpty)
    }

    @Test func blankMeansAlmostAllBlackOrTransparent() throws {
        #expect(WorkshopPreview.isBlank(try solid(0, 0, 0)))
        // 全透明（预乘了透明度，颜色也是 0）
        #expect(WorkshopPreview.isBlank(try solid(0, 0, 0, alpha: 0)))
        // 视频淡入那种很暗、但不是全黑的一帧也算空帧
        #expect(WorkshopPreview.isBlank(try solid(16, 16, 16)))
        #expect(!WorkshopPreview.isBlank(try solid(40, 40, 40)))
        #expect(!WorkshopPreview.isBlank(try solid(255, 0, 0)))
        // 黑底上一小块亮的（约 4% 的面积，夜景里的灯那种）：不是空帧
        let lamp = try image(size: 160) { x, y in x < 32 && y < 32 ? (255, 220, 120, 255) : (0, 0, 0, 255) }
        #expect(!WorkshopPreview.isBlank(lamp))
    }

    @Test func blankFirstFrameIsSkipped() throws {
        // 视频壁纸的 GIF 预览：第一帧纯黑，第二帧起才有画面
        let preview = try gif([try solid(0, 0, 0), try solid(200, 30, 30), try solid(30, 200, 30)])
        let thumbnail = try #require(WorkshopPreview.thumbnail(of: try source(preview), maxPixelSize: Self.thumbnailSize))
        #expect(!WorkshopPreview.isBlank(thumbnail))
        let color = try averageColor(thumbnail)
        #expect(color.x > 150 && color.y < 80, "该用第二帧（红色），实际平均颜色 \(color)")

        // 第一帧本来就看得见：用第一帧
        let normal = try gif([try solid(30, 30, 200), try solid(200, 30, 30)])
        let first = try #require(WorkshopPreview.thumbnail(of: try source(normal), maxPixelSize: Self.thumbnailSize))
        #expect(try averageColor(first).z > 150)
    }

    @Test func allBlankFramesFallBackToTheFirstFrame() throws {
        let preview = try gif([try solid(0, 0, 0), try solid(0, 0, 0), try solid(5, 5, 5)])
        let thumbnail = try #require(WorkshopPreview.thumbnail(of: try source(preview), maxPixelSize: Self.thumbnailSize))
        #expect(WorkshopPreview.isBlank(thumbnail))
    }

    @Test func gifStopsAfterTheFirstRequestOtherFormatsFetchTheRest() async throws {
        // 每帧噪点约 25 KB，20 帧约 500 KB：第一帧在头 128 KB 里，一次就够；带回下到的这一段，要动起来时接着下
        let animated = try gif((0..<20).map { try noise(seed: UInt32($0 + 1)) })
        #expect(animated.count > WorkshopPreview.firstRequestBytes)
        let gifServer = RangeServer(body: animated, contentType: "image/gif")
        let gifPreview = try #require(try await WorkshopPreview.fetch(
            URL(string: "https://example.invalid/a")!, client: gifServer, maxPixelSize: Self.thumbnailSize))
        #expect(gifServer.ranges == ["bytes=0-131071"])
        #expect(gifPreview.thumbnail.width == Self.thumbnailSize)
        #expect(gifPreview.gif == animated.prefix(WorkshopPreview.firstRequestBytes))
        #expect(!gifPreview.isComplete)

        // 不是 GIF（JPEG 要整张才解得出来）：再要剩下的，拼成整张
        let photo = try jpeg(try noise(size: 600, seed: 7))
        #expect(photo.count > WorkshopPreview.firstRequestBytes)
        let jpegServer = RangeServer(body: photo, contentType: "image/jpeg")
        let jpegPreview = try #require(try await WorkshopPreview.fetch(
            URL(string: "https://example.invalid/b")!, client: jpegServer, maxPixelSize: Self.thumbnailSize))
        #expect(jpegServer.ranges == ["bytes=0-131071", "bytes=131072-"])
        #expect(jpegPreview.thumbnail.width == Self.thumbnailSize)
        #expect(jpegPreview.gif == nil)

        // 整张比第一次要的还小：一次就够
        let small = try jpeg(try solid(size: 32, 10, 120, 200))
        #expect(small.count < WorkshopPreview.firstRequestBytes)
        let smallServer = RangeServer(body: small, contentType: "image/jpeg")
        let smallPreview = try await WorkshopPreview.fetch(
            URL(string: "https://example.invalid/c")!, client: smallServer, maxPixelSize: Self.thumbnailSize)
        #expect(smallServer.ranges.count == 1)
        #expect(smallPreview != nil)

        // 小 GIF 一次就下完了：带回整张
        let smallGIF = try gif([try solid(size: 32, 200, 30, 30), try solid(size: 32, 30, 200, 30)])
        let smallGIFPreview = try #require(try await WorkshopPreview.fetch(
            URL(string: "https://example.invalid/f")!, client: RangeServer(body: smallGIF, contentType: "image/gif"),
            maxPixelSize: Self.thumbnailSize))
        #expect(smallGIFPreview.gif == smallGIF)
        #expect(smallGIFPreview.isComplete)
    }

    @Test func blankFirstFrameWithPictureInTheFirstRequestNeedsNoMore() async throws {
        // 纯黑的第一帧只有几百字节，后面的帧也在头 128 KB 里：不用再下
        let preview = try gif([try solid(0, 0, 0)] + (0..<20).map { try noise(seed: UInt32($0 + 1)) })
        #expect(preview.count > WorkshopPreview.firstRequestBytes)
        let server = RangeServer(body: preview, contentType: "image/gif")
        let fetched = try await WorkshopPreview.fetch(
            URL(string: "https://example.invalid/d")!, client: server, maxPixelSize: Self.thumbnailSize)
        #expect(server.ranges == ["bytes=0-131071"])
        #expect(!WorkshopPreview.isBlank(try #require(fetched?.thumbnail)))
    }

    @Test func onlyBlankFramesInTheFirstRequestFetchesTheRest() async throws {
        // 第二帧很大（480 边长的噪点，两百多 KB），头 128 KB 里只有纯黑的第一帧：要把剩下的也下回来
        let preview = try gif([try solid(size: 480, 0, 0, 0), try noise(size: 480, seed: 3)])
        let ends = WorkshopPreview.gifFrameEnds(in: preview)
        #expect(ends.count == 2 && ends[0] < WorkshopPreview.firstRequestBytes && ends[1] > WorkshopPreview.firstRequestBytes)
        let server = RangeServer(body: preview, contentType: "image/gif")
        let fetched = try #require(try await WorkshopPreview.fetch(
            URL(string: "https://example.invalid/e")!, client: server, maxPixelSize: Self.thumbnailSize))
        #expect(server.ranges == ["bytes=0-131071", "bytes=131072-"])
        #expect(!WorkshopPreview.isBlank(fetched.thumbnail))
        // 已经是整张了：动起来不用再下
        #expect(fetched.gif == preview)
        #expect(fetched.isComplete)
    }

    @Test func remainderContinuesFromTheHead() async throws {
        let animated = try gif((0..<20).map { try noise(seed: UInt32($0 + 1)) })
        let server = RangeServer(body: animated, contentType: "image/gif")
        let head = animated.prefix(WorkshopPreview.firstRequestBytes)
        let whole = try await WorkshopPreview.remainder(of: head, url: URL(string: "https://example.invalid/g")!, client: server)
        #expect(server.ranges == ["bytes=131072-"])
        #expect(whole == animated)
    }

    @Test func sniffingAsksForTheFirstBytesOnly() async throws {
        let animated = try gif([try solid(200, 30, 30), try solid(30, 200, 30)])
        let gifServer = RangeServer(body: animated, contentType: "image/gif")
        #expect(try await WorkshopPreview.isGIF(at: URL(string: "https://example.invalid/h")!, client: gifServer))
        #expect(gifServer.ranges == ["bytes=0-5"])
        let photoServer = RangeServer(body: try jpeg(try solid(10, 120, 200)), contentType: "image/jpeg")
        #expect(try await !WorkshopPreview.isGIF(at: URL(string: "https://example.invalid/i")!, client: photoServer))
    }

    @Test func leadingBlankFramesAreCounted() throws {
        let fadeIn = try gif([try solid(0, 0, 0), try solid(4, 4, 4), try solid(200, 30, 30), try solid(0, 0, 0)])
        // 中间、结尾的黑帧是画面本身（转场），只数开头的
        #expect(WorkshopPreview.leadingBlankFrames(in: try source(fadeIn)) == 2)
        #expect(WorkshopPreview.leadingBlankFrames(in: try source(try gif([try solid(200, 30, 30), try solid(0, 0, 0)]))) == 0)
        // 整张都是空帧：不跳（跳光了就什么也不显示）
        #expect(WorkshopPreview.leadingBlankFrames(in: try source(try gif([try solid(0, 0, 0), try solid(0, 0, 0)]))) == 0)
    }
}
