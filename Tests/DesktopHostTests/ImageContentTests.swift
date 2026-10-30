import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DesktopHost

@MainActor
@Suite struct ImageContentTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageContentTests-\(UUID().uuidString)", isDirectory: true)

    private func makePNG() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let url = root.appendingPathComponent("壁纸.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func loadsImageAndReportsWhenReady() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = EventLog(fileURL: root.appendingPathComponent("test.log"))
        let content = ImageContent(url: url, label: "测试屏", log: log) { _ in
            Issue.record("有效 PNG 不应载入失败")
        }
        await withCheckedContinuation { continuation in
            content.whenReady { continuation.resume() }
        }

        let snapshot = await content.snapshot()
        let image = try #require(snapshot)
        #expect(image.width == 4)
        #expect(image.height == 2)
    }

    @Test func fillsOrFitsWithoutDistortingAndCanPan() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let image = CGSize(width: 200, height: 100)

        let left = ImageContent.imageFrame(
            in: bounds, imageSize: image, fitsWhole: false, position: 0)
        #expect(left == CGRect(x: 0, y: 0, width: 200, height: 100))
        let right = ImageContent.imageFrame(
            in: bounds, imageSize: image, fitsWhole: false, position: 1)
        #expect(right == CGRect(x: -100, y: 0, width: 200, height: 100))
        let whole = ImageContent.imageFrame(
            in: bounds, imageSize: image, fitsWhole: true, position: 1)
        #expect(whole == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    /// 已经显示着的图片改显示方式要当场挪，不用重新载入（拖"画面位置"滑块时就是这样调用的）
    @Test func movesLoadedImageWhenDisplayChanges() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = EventLog(fileURL: root.appendingPathComponent("test.log"))
        let content = ImageContent(url: url, label: "测试屏", log: log) { _ in
            Issue.record("有效 PNG 不应载入失败")
        }
        await withCheckedContinuation { continuation in
            content.whenReady { continuation.resume() }
        }
        let adjustable: any FramingAdjustable = content
        content.view.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        content.view.layoutSubtreeIfNeeded()
        let imageLayer = try #require(content.view.layer?.sublayers?.first)
        #expect(imageLayer.frame == CGRect(x: -2, y: 0, width: 8, height: 4))

        adjustable.setDisplay(fitsWhole: false, position: 0, scale: 1)
        content.view.layoutSubtreeIfNeeded()
        #expect(imageLayer.frame == CGRect(x: 0, y: 0, width: 8, height: 4))
        adjustable.setDisplay(fitsWhole: false, position: 1, scale: 1)
        content.view.layoutSubtreeIfNeeded()
        #expect(imageLayer.frame == CGRect(x: -4, y: 0, width: 8, height: 4))
        adjustable.setDisplay(fitsWhole: true, position: 1, scale: 1)
        content.view.layoutSubtreeIfNeeded()
        #expect(imageLayer.frame == CGRect(x: 0, y: 1, width: 4, height: 2))
    }
}
