import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WallpaperLibrary

/// 网格里的预览图只要第一帧：GIF 动图下到第一帧完整就停，别的格式下整张
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

    /// 自己画的多帧 GIF：每帧是不同的噪点（压不小），整张比第一帧大很多
    private func animatedGIF(frames: Int, size: Int = 160) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.gif.identifier as CFString, frames, nil))
        var seed: UInt32 = 12345
        for _ in 0..<frames {
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[i] = UInt8(seed >> 24); pixels[i + 1] = UInt8((seed >> 16) & 0xFF); pixels[i + 2] = UInt8((seed >> 8) & 0xFF)
                pixels[i + 3] = 255
            }
            let context = try #require(CGContext(
                data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func gifFirstFrameEndsWellBeforeTheFile() throws {
        let gif = try animatedGIF(frames: 8)
        let end = try #require(WorkshopPreview.gifFirstFrameEnd(in: gif))
        #expect(end < gif.count / 4)
        // 前面这一段就能解出完整的第一帧
        let source = try #require(CGImageSourceCreateWithData(gif.prefix(end) as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 160)
        // 少一个字节就不算完整；不是 GIF 也不算
        #expect(WorkshopPreview.gifFirstFrameEnd(in: gif.prefix(end - 1)) == nil)
        #expect(WorkshopPreview.gifFirstFrameEnd(in: Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 20))) == nil)
    }

    @Test func gifStopsAfterTheFirstRequestOtherFormatsFetchTheRest() async throws {
        // 每帧噪点约 25 KB，20 帧约 500 KB：第一帧在头 128 KB 里，一次就够
        let gif = try animatedGIF(frames: 20)
        #expect(gif.count > WorkshopPreview.firstRequestBytes)
        let gifServer = RangeServer(body: gif, contentType: "image/gif")
        let gifData = try await WorkshopPreview.data(for: URL(string: "https://example.invalid/a")!, client: gifServer)
        #expect(gifServer.ranges == ["bytes=0-131071"])
        #expect(gifData.count == WorkshopPreview.firstRequestBytes)

        // 不是 GIF：再要剩下的，拼成整张
        let other = Data((0..<300_000).map { UInt8($0 % 251) })
        let otherServer = RangeServer(body: other, contentType: "image/jpeg")
        let otherData = try await WorkshopPreview.data(for: URL(string: "https://example.invalid/b")!, client: otherServer)
        #expect(otherServer.ranges == ["bytes=0-131071", "bytes=131072-"])
        #expect(otherData == other)

        // 整张比第一次要的还小：一次就够
        let small = Data(repeating: 7, count: 1000)
        let smallServer = RangeServer(body: small, contentType: "image/png")
        #expect(try await WorkshopPreview.data(for: URL(string: "https://example.invalid/c")!, client: smallServer) == small)
        #expect(smallServer.ranges.count == 1)
    }
}
