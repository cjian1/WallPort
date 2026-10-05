import AVFoundation
import CoreVideo
import Foundation
import Metal
import Testing
@testable import SceneRenderer

/// 视频贴图：离线出图时取准确的那一帧；桌面上只取后台解好的帧，从不等
@Suite struct VideoTextureTests {
    static let frameRate = 30
    static let frameCount = 60

    /// 2 秒、每秒 30 帧的 H.264：第 i 帧整张是灰度 i × 4（读一个像素就知道是第几帧）
    private func makeVideo() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoTextureTests-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<Self.frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!
            let value = UInt8(index * 4)
            for y in 0..<64 {
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixels)).assumingMemoryBound(to: UInt8.self)
                for x in 0..<64 { row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = value; row[x * 4 + 3] = 255 }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(Self.frameRate)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return try Data(contentsOf: url)
    }

    /// 贴图中间那个像素的灰度 → 第几帧
    private func frameIndex(_ texture: any MTLTexture) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1), mipmapLevel: 0)
        return Int((Double(pixel[1]) / 4).rounded())
    }

    private func loadedVideo() async throws -> VideoTexture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let video = try #require(VideoTexture(data: try await makeVideo(), device: device, maxDimension: 64))
        // 时长、视频轨在后台读，读到之前返回 nil
        for _ in 0..<500 where video.texture(at: 0, waits: true) == nil { try await Task.sleep(for: .milliseconds(10)) }
        return video
    }

    /// 离线：每个时刻都是"不晚于这一刻的最后一帧"，时间倒退、跨过循环也对
    @Test func waitingGivesTheExactFrame() async throws {
        let video = try await loadedVideo()
        let duration = Double(Self.frameCount) / Double(Self.frameRate)
        for time in [0.0, 0.51, 1.0, 1.99, 0.3, 0.31, 2.5, 5.9, 1.2] {
            let texture = try #require(video.texture(at: Float(time), waits: true))
            let expected = Int(((time.truncatingRemainder(dividingBy: duration)) * Double(Self.frameRate) + 0.001).rounded(.down))
            #expect(frameIndex(texture) == expected, "第 \(time) 秒")
        }
    }

    /// 桌面：按真实时间取，调用从不卡；显示的帧跟得上（最多落后几帧），过了结尾接着从头播
    @Test func nonWaitingNeverBlocksAndKeepsUp() async throws {
        let video = try await loadedVideo()
        let start = Date()
        var slowest = 0.0
        var lags: [Int] = []
        var seen = Set<Int>()
        while Date().timeIntervalSince(start) < 3 {
            let time = Date().timeIntervalSince(start)
            let called = Date()
            let texture = video.texture(at: Float(time), waits: false)
            slowest = max(slowest, Date().timeIntervalSince(called))
            if let texture, time > 0.3 {
                let shown = frameIndex(texture)
                seen.insert(shown)
                let wanted = Int(time * Double(Self.frameRate)) % Self.frameCount
                lags.append((wanted - shown + Self.frameCount) % Self.frameCount)
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(slowest < 0.02, "取帧最长用了 \(slowest) 秒")
        #expect(seen.count > 40, "3 秒里见到的帧：\(seen.count)")
        let sorted = lags.sorted()
        #expect(sorted[sorted.count * 95 / 100] <= 3, "落后的帧数（95%）：\(sorted[sorted.count * 95 / 100])")
    }
}
