import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import MacWallpaperApp
import WallpaperLibrary

/// 预览图的磁盘缓存和动图：缩略图的名字记着原图是不是 GIF，GIF 的整张鼠标停过才下；以前的版本存的缩略图照用，
/// 要动起来时问一下原图是不是 GIF；动图播放时开头的空帧不显示
@Suite struct ThumbnailCacheTests {
    private let url = URL(string: "https://images.example.invalid/ugc/1/ABCDEF/")!

    /// 服务器假装支持按字节范围取，记下每次要了哪一段（不带范围的记成"整张"）
    private final class RangeServer: HTTPClient, @unchecked Sendable {
        let body: Data
        private(set) var ranges: [String] = []
        private let lock = NSLock()

        init(body: Data) { self.body = body }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let range = request.value(forHTTPHeaderField: "Range")
            lock.withLock { ranges.append(range ?? "整张") }
            guard let range else {
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            let spec = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(spec.first ?? "") ?? 0
            let end = min(spec.count > 1 ? Int(spec[1]) ?? body.count - 1 : body.count - 1, body.count - 1)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(start)-\(end)/\(body.count)"])!
            return (body.subdata(in: start..<(end + 1)), response)
        }
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, side: Int = 64) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    /// 噪点（压不小）：160 边长每帧约 25 KB
    private func noise(seed: UInt32, side: Int = 160) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: side * side * 4)
        var state = seed
        for i in 0..<(side * side) {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[i * 4] = UInt8(state >> 24); pixels[i * 4 + 1] = UInt8((state >> 16) & 0xFF)
            pixels[i * 4 + 2] = UInt8((state >> 8) & 0xFF); pixels[i * 4 + 3] = 255
        }
        return try #require(context.makeImage())
    }

    private func encode(_ frames: [CGImage], as type: UTType) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, frames.count, nil))
        for frame in frames { CGImageDestinationAddImage(destination, frame, nil) }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 视频壁纸那种预览：第一帧纯黑，后面红、绿
    private func blackFirstGIF() throws -> Data {
        try encode([try solid(0, 0, 0), try solid(200, 30, 30), try solid(30, 200, 30)], as: .gif)
    }

    private func photo() throws -> Data {
        try encode([try solid(200, 120, 40)], as: .jpeg)
    }

    private func exists(_ directory: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    // MARK: 缩略图

    @Test func thumbnailsAreSavedUnderTheKindOfTheirPreview() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 大 GIF：只下了开头 128 KB，缩略图存成 GIF 的，整张不下；开头这一段带回去（鼠标停上来时接着下）
        let big = try encode((0..<20).map { try noise(seed: UInt32($0 + 1)) }, as: .gif)
        let bigServer = RangeServer(body: big)
        let bigStill = try #require(await ThumbnailCache.loadStill(url, client: bigServer, directory: directory))
        #expect(bigServer.ranges == ["bytes=0-131071"])
        #expect(bigStill.gifHead?.count == WorkshopPreview.firstRequestBytes)
        #expect(exists(directory, ThumbnailCache.gifThumbnailName(url)))
        #expect(!exists(directory, ThumbnailCache.gifName(url)))
        // 下次直接读磁盘
        guard case .gif? = ThumbnailCache.diskEntry(for: url, in: directory) else {
            Issue.record("缩略图应当记着原图是 GIF")
            return
        }
        #expect(await ThumbnailCache.loadStill(url, client: bigServer, directory: directory) != nil)
        #expect(bigServer.ranges.count == 1)

        // 小 GIF 一次就下完了：整张也存上
        let small = URL(string: "https://images.example.invalid/ugc/2/SMALL/")!
        let smallStill = try #require(await ThumbnailCache.loadStill(
            small, client: RangeServer(body: try blackFirstGIF()), directory: directory))
        #expect(smallStill.gifHead == nil)
        #expect(!WorkshopPreview.isBlank(smallStill.image))
        #expect(exists(directory, ThumbnailCache.gifThumbnailName(small)) && exists(directory, ThumbnailCache.gifName(small)))

        // 静态图
        let still = URL(string: "https://images.example.invalid/ugc/3/PHOTO/")!
        _ = try #require(await ThumbnailCache.loadStill(still, client: RangeServer(body: try photo()), directory: directory))
        #expect(exists(directory, ThumbnailCache.stillName(still)))
        guard case .still? = ThumbnailCache.diskEntry(for: still, in: directory) else {
            Issue.record("缩略图应当记着原图是静态图")
            return
        }
    }

    @Test func wholeGIFRebuildsAPrunedThumbnail() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try blackFirstGIF().write(to: directory.appendingPathComponent(ThumbnailCache.gifName(url)))

        guard case .gif(let image)? = ThumbnailCache.diskEntry(for: url, in: directory) else {
            Issue.record("应当从整张 GIF 重做缩略图")
            return
        }
        #expect(!WorkshopPreview.isBlank(image))
        #expect(exists(directory, ThumbnailCache.gifThumbnailName(url)))
    }

    @Test func oldThumbnailsAreShownAndSettledOnceAsked() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try photo().write(to: directory.appendingPathComponent(ThumbnailCache.oldNames(url)[0]))
        guard case .unknown(let image)? = ThumbnailCache.diskEntry(for: url, in: directory) else {
            Issue.record("以前的版本存的缩略图应当照用")
            return
        }
        #expect(!WorkshopPreview.isBlank(image))

        ThumbnailCache.settleOldThumbnail(url, in: directory, isGIF: false)
        #expect(exists(directory, ThumbnailCache.stillName(url)))
        #expect(!exists(directory, ThumbnailCache.oldNames(url)[0]))

        let other = URL(string: "https://images.example.invalid/ugc/4/OLD/")!
        try photo().write(to: directory.appendingPathComponent(ThumbnailCache.oldNames(other)[1]))
        ThumbnailCache.settleOldThumbnail(other, in: directory, isGIF: true)
        #expect(exists(directory, ThumbnailCache.gifThumbnailName(other)))
        #expect(!exists(directory, ThumbnailCache.oldNames(other)[1]))
    }

    @Test func oldBlackThumbnailIsDroppedSoItGetsRedone() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent(ThumbnailCache.oldNames(url)[1])
        try encode([try solid(0, 0, 0)], as: .jpeg).write(to: legacy)

        #expect(ThumbnailCache.diskEntry(for: url, in: directory) == nil)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func pruningDropsTheLeastRecentlyUsedFirst() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 四个 64 KB 的文件，最早用的是 a；上限 200 KB：删到 150 KB 以下，要删掉最早的两个
        for (index, name) in ["a", "b", "c", "d"].enumerated() {
            let file = directory.appendingPathComponent(name)
            try Data(repeating: 1, count: 64 * 1024).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)], ofItemAtPath: file.path)
        }
        ThumbnailCache.pruneDisk(directory, limit: 200 * 1024)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == ["c", "d"])
    }

    // MARK: 动起来

    @Test func headIsContinuedAndTheWholeGIFIsSaved() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gif = try blackFirstGIF()
        let server = RangeServer(body: gif)
        let head = gif.prefix(gif.count / 2)

        let animation = try #require(await ThumbnailCache.loadAnimation(url, head: head, client: server, directory: directory))
        #expect(server.ranges == ["bytes=\(head.count)-"])
        #expect(animation.data == gif)
        #expect(animation.leadingBlankFrames == 1)
        #expect(exists(directory, ThumbnailCache.gifName(url)))

        // 下次直接读磁盘，不联网
        let again = try #require(await ThumbnailCache.loadAnimation(url, head: nil, client: server, directory: directory))
        #expect(again.data == gif)
        #expect(server.ranges.count == 1)
    }

    @Test func knownGIFThumbnailDownloadsWithoutAsking() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 缩略图存成了 GIF 的（上次打开时下的开头那段已经不在内存里了）：直接整张下
        try photo().write(to: directory.appendingPathComponent(ThumbnailCache.gifThumbnailName(url)))
        let gif = try blackFirstGIF()
        let server = RangeServer(body: gif)
        let animation = try #require(await ThumbnailCache.loadAnimation(url, head: nil, client: server, directory: directory))
        #expect(server.ranges == ["整张"])
        #expect(animation.data == gif)
        #expect(exists(directory, ThumbnailCache.gifName(url)))
    }

    @Test func unknownOldThumbnailAsksWhetherItIsAGIF() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 原图是 JPEG：只问前几个字节，缩略图改成静态图的名字，以后不再问
        try photo().write(to: directory.appendingPathComponent(ThumbnailCache.oldNames(url)[0]))
        let photoServer = RangeServer(body: try photo())
        #expect(await ThumbnailCache.loadAnimation(url, head: nil, client: photoServer, directory: directory) == nil)
        #expect(photoServer.ranges == ["bytes=0-5"])
        #expect(exists(directory, ThumbnailCache.stillName(url)))
        #expect(await ThumbnailCache.loadAnimation(url, head: nil, client: photoServer, directory: directory) == nil)
        #expect(photoServer.ranges.count == 1)

        // 原图是 GIF：问过以后整张下，缩略图改成 GIF 的名字
        let other = URL(string: "https://images.example.invalid/ugc/5/123456/")!
        try photo().write(to: directory.appendingPathComponent(ThumbnailCache.oldNames(other)[0]))
        let gif = try blackFirstGIF()
        let gifServer = RangeServer(body: gif)
        let animation = try #require(await ThumbnailCache.loadAnimation(other, head: nil, client: gifServer, directory: directory))
        #expect(gifServer.ranges == ["bytes=0-5", "整张"])
        #expect(animation.data == gif)
        #expect(exists(directory, ThumbnailCache.gifName(other)) && exists(directory, ThumbnailCache.gifThumbnailName(other)))
        #expect(!exists(directory, ThumbnailCache.oldNames(other)[0]))
    }

    @Test func stillPreviewsAndSingleFramesDoNotAnimate() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 已知是静态图：不联网
        try photo().write(to: directory.appendingPathComponent(ThumbnailCache.stillName(url)))
        let server = RangeServer(body: Data())
        #expect(await ThumbnailCache.loadAnimation(url, head: nil, client: server, directory: directory) == nil)
        #expect(server.ranges.isEmpty)

        #expect(AnimatedPreview(data: try encode([try solid(200, 30, 30)], as: .gif)) == nil)
        #expect(AnimatedPreview(data: try photo()) == nil)
        #expect(AnimatedPreview(data: try encode([try solid(200, 30, 30), try solid(30, 200, 30)], as: .gif)) != nil)
    }

    @Test func localGIFPreviewAnimatesFromTheFile() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.gif")
        try blackFirstGIF().write(to: file)
        let server = RangeServer(body: Data())
        let animation = try #require(await ThumbnailCache.loadAnimation(file, head: nil, client: server, directory: nil))
        #expect(animation.leadingBlankFrames == 1)
        #expect(server.ranges.isEmpty)

        let still = directory.appendingPathComponent("preview.jpg")
        try photo().write(to: still)
        #expect(await ThumbnailCache.loadAnimation(still, head: nil, client: server, directory: nil) == nil)
    }

    // MARK: 播放

    @MainActor
    @Test func blankLeadingFramesAreNeverShown() throws {
        let preview = try #require(AnimatedPreview(data: try blackFirstGIF()))
        let view = AnimatedImageView()
        view.requiresVisibleWindow = false
        view.preview = preview
        let black = try solid(0, 0, 0)
        let red = try solid(200, 30, 30)
        view.show(frame: 0, image: black)
        #expect(view.frameImage == nil)
        view.show(frame: 1, image: red)
        #expect(view.frameImage === red)
        // 转一圈回到开头：空帧不换，留着上一帧
        view.show(frame: 0, image: black)
        #expect(view.frameImage === red)
    }

    @MainActor
    @Test func playbackRunsAndStopsWithThePreview() async throws {
        let preview = try #require(AnimatedPreview(data: try blackFirstGIF()))
        let view = AnimatedImageView()
        view.requiresVisibleWindow = false
        view.preview = preview
        #expect(view.isPlaying)
        // 系统在主线程上按 GIF 的帧间隔回调：等它换上第一张看得见的帧（给足时间，全量测试并行时也不误报）
        let deadline = Date().addingTimeInterval(5)
        while view.frameImage == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let frame = try #require(view.frameImage)
        #expect(!WorkshopPreview.isBlank(frame))
        view.preview = nil
        #expect(!view.isPlaying)
        #expect(view.frameImage == nil)

        // 窗口看不见时不播
        let hidden = AnimatedImageView()
        hidden.preview = preview
        #expect(!hidden.isPlaying)
    }

    private func animatedView(in view: NSView) -> AnimatedImageView? {
        if let found = view as? AnimatedImageView { return found }
        return view.subviews.lazy.compactMap(animatedView(in:)).first
    }

    @MainActor
    @Test func animationAppearsOnlyWhileTheMouseIsOverThePreview() async throws {
        // 系统设置里打开了"减弱动态效果"时本来就不动
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.gif")
        try blackFirstGIF().write(to: file)
        // 窗口不显示到屏幕上；鼠标进出用合成的事件交给宿主视图
        let host = NSHostingView(rootView: ThumbnailImage(url: file).frame(width: 260, height: 118))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func mouse(at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        // 和真的鼠标一样：先进入跟踪区再移动；离开时先移出去再退出跟踪区
        func enter(at point: NSPoint) {
            host.mouseEntered(with: mouse(at: point))
            host.mouseMoved(with: mouse(at: point))
        }
        func leave(to point: NSPoint) {
            host.mouseMoved(with: mouse(at: point))
            host.mouseExited(with: mouse(at: point))
        }
        func wait(until condition: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            return condition()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: ThumbnailImage.hoverDelay * 2)
        #expect(animatedView(in: host) == nil)

        enter(at: NSPoint(x: 130, y: 80))
        #expect(try await wait { animatedView(in: host) != nil }, "鼠标停在预览图上应当拿来动图")
        leave(to: NSPoint(x: 130, y: 150))
        #expect(try await wait { animatedView(in: host) == nil }, "鼠标移开应当撤掉动图")
    }
}
