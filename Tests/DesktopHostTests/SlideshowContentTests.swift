import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DesktopHost

/// 壁坞自己放的图片幻灯片：挑下一张的规则、载入第一张、换下一张、坏图跳过、同步成系统壁纸的那一帧
@MainActor
@Suite struct SlideshowContentTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SlideshowContentTests-\(UUID().uuidString)", isDirectory: true)

    /// 每张一个纯色的小图，方便认出是哪一张
    private func makeImages(_ count: Int) throws -> [URL] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let context = try #require(CGContext(
                data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(count), green: 0.2, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
            let url = root.appendingPathComponent(String(format: "%04d.png", index + 1))
            let destination = try #require(
                CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
    }

    private func waitForIndex(_ content: SlideshowContent, _ index: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while content.currentIndexForTesting != index, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return content.currentIndexForTesting == index
    }

    @Test func sequentialOrderWrapsAround() {
        #expect(SlideshowContent.nextIndex(after: nil, count: 3, shuffles: false) == 0)
        #expect(SlideshowContent.nextIndex(after: 1, count: 3, shuffles: false) == 2)
        #expect(SlideshowContent.nextIndex(after: 2, count: 3, shuffles: false) == 0)
        #expect(SlideshowContent.nextIndex(after: 0, count: 1, shuffles: true) == 0)
    }

    /// 随机：不管随机数给什么，都不会连着放同一张，也不会越界
    @Test func shuffleNeverRepeatsTheCurrentSlide() {
        for current in 0..<4 {
            for roll in 0..<3 {
                let next = SlideshowContent.nextIndex(after: current, count: 4, shuffles: true) { _ in roll }
                #expect(next != current && (0..<4).contains(next))
            }
        }
    }

    @Test func intervalsAreDescribedInSecondsOrMinutes() {
        #expect(SlideshowContent.describe(10) == "10 秒")
        #expect(SlideshowContent.describe(90) == "90 秒")
        #expect(SlideshowContent.describe(300) == "5 分钟")
    }

    /// 第一张解好就能显示；换一张按顺序到下一张；坏图跳过；同步成系统壁纸的一帧是屏幕大小
    @Test func showsFirstSlideAdvancesAndSkipsBrokenFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var images = try makeImages(3)
        let broken = root.appendingPathComponent("0002-坏图.jpg")
        try Data("不是图片".utf8).write(to: broken)
        images.insert(broken, at: 1)
        let log = EventLog(fileURL: root.appendingPathComponent("test.log"))
        let content = SlideshowContent(
            files: images, interval: 600, shuffles: false, label: "测试屏", log: log,
            targetPixelSize: CGSize(width: 8, height: 8)
        ) { reason in Issue.record("能解的图片不该报错：\(reason)") }
        defer { content.tearDown() }
        await withCheckedContinuation { continuation in content.whenReady { continuation.resume() } }
        #expect(content.currentIndexForTesting == 0)

        content.advanceForTesting()
        #expect(await waitForIndex(content, 2), "第 2 个文件是坏图，应当跳到第 3 个")
        content.advanceForTesting()
        #expect(await waitForIndex(content, 3))
        content.advanceForTesting()
        #expect(await waitForIndex(content, 0), "放完一轮回到第一张")

        content.setDisplay(fitsWhole: true, position: 0.5, scale: 0.5)
        let frame = try #require(await content.snapshot())
        #expect(frame.width == 8 && frame.height == 8)
    }

    @Test func reportsFailureWhenNothingCanBeDecoded() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("坏图.png")
        try Data("不是图片".utf8).write(to: broken)
        let log = EventLog(fileURL: root.appendingPathComponent("test.log"))
        let (failures, continuation) = AsyncStream.makeStream(of: String.self)
        let content = SlideshowContent(
            files: [broken], interval: 60, shuffles: false, label: "测试屏", log: log
        ) { continuation.yield($0) }
        defer { content.tearDown() }
        var iterator = failures.makeAsyncIterator()
        let reason = await iterator.next()
        #expect(reason?.isEmpty == false)
    }
}
