import Foundation
import Metal
import Testing
@testable import SceneRenderer

@Suite struct MotionProbeTests {
    /// 有纹理的亮度图：几个不同频率的正弦叠起来（块匹配要能认出位置），整体挪开 (dx, dy)
    private func pattern(width: Int = 200, height: Int = 120, dx: Double = 0, dy: Double = 0, brightness: Double = 0)
        -> LumaFrame
    {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) - dx, v = Double(y) - dy
                let value = 128 + 50 * sin(u * 0.37) * cos(v * 0.29) + 30 * sin((u + 2 * v) * 0.11) + brightness
                pixels[y * width + x] = UInt8(max(0, min(255, value)))
            }
        }
        return LumaFrame(width: width, height: height, pixels: pixels)
    }

    @Test func stillFrameHasNoMotion() throws {
        let frame = pattern()
        let result = try #require(MotionEstimator.measure(from: frame, to: frame, interval: 0.1))
        #expect(result.speed == 0)
        #expect(result.fadeRate == 0)
        #expect(result.movingBlocks == 0 && result.warpingBlocks == 0 && result.fadingBlocks == 0)
    }

    /// 整体挪 2.5 格（亮度图的格，原画面 10 像素），0.1 秒：约 100 像素 / 秒
    @Test func shiftedFrameMovesAtTheRightSpeed() throws {
        let result = try #require(MotionEstimator.measure(
            from: pattern(), to: pattern(dx: 2.5, dy: 0), interval: 0.1))
        #expect(result.movingBlocks > result.warpingBlocks)
        #expect(abs(result.speed - 100) < 15, "速度 \(result.speed)")
        let diagonal = try #require(MotionEstimator.measure(
            from: pattern(), to: pattern(dx: -1, dy: 1), interval: 0.1))
        #expect(abs(diagonal.speed - 2.squareRoot() * 40) < 10, "速度 \(diagonal.speed)")
    }

    /// 没有纹理、整块变亮：只是明暗在变，按亮度级 / 秒算
    @Test func flatBrighteningIsAFade() throws {
        let dark = LumaFrame(width: 100, height: 60, pixels: [UInt8](repeating: 80, count: 6000))
        let light = LumaFrame(width: 100, height: 60, pixels: [UInt8](repeating: 90, count: 6000))
        let result = try #require(MotionEstimator.measure(from: dark, to: light, interval: 0.1))
        #expect(result.fadingBlocks > 0 && result.movingBlocks == 0)
        #expect(abs(result.fadeRate - 100) < 1)
        #expect(result.speed == 0)
    }

    /// 形状在变（前后两帧是不相干的纹理）：块匹配找不到位移，按"亮度变化 ÷ 梯度"估，至少要比没动快
    @Test func unrelatedTextureIsWarping() throws {
        let other = LumaFrame(
            width: 200, height: 120, pixels: pattern().pixels.enumerated().map { UInt8(truncatingIfNeeded: $0.element &+ UInt8($0.offset % 97)) })
        let result = try #require(MotionEstimator.measure(from: pattern(), to: other, interval: 0.1))
        #expect(result.warpingBlocks > 0)
        #expect(result.speed > 0)
    }

    @Test func frameRateFollowsTheSpeed() {
        func result(speed: Double, fade: Double = 0) -> MotionEstimator.Result {
            .init(speed: speed, fadeRate: fade, movingBlocks: 1, warpingBlocks: 0, fadingBlocks: 0, totalBlocks: 10)
        }
        // Retina：每帧 2 个点 = 4 个像素
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 0), backingScale: 2, cap: 30) == 20)
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 80), backingScale: 2, cap: 30) == 20)
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 90), backingScale: 2, cap: 30) == 24)
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 100), backingScale: 2, cap: 30) == 30)
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 1000), backingScale: 2, cap: 30) == 30)
        // 普通屏每个点 1 个像素：同样的像素速度要更高的帧率
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 80), backingScale: 1, cap: 30) == 30)
        // 明暗变得快也要高帧率（每帧不超过 8 级）
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 0, fade: 200), backingScale: 2, cap: 30) == 30)
        // 上限更低（用电池降到 15 帧）时不超过上限；不限制时可以更高，比最高一档还快就不限
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 0), backingScale: 2, cap: 15) == 15)
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 150), backingScale: 2, cap: 0) == 40)
        #expect(AdaptiveFrameRate.frameRate(for: result(speed: 1000), backingScale: 2, cap: 0) == 0)
    }

    /// 量满 3 次之前按上限；变快马上升，变慢要 3 次都慢才降
    @Test func governorRaisesAtOnceAndLowersSlowly() {
        var governor = FrameRateGovernor(startingAt: 100)
        #expect(!governor.isDue(at: 101) && governor.isDue(at: 102))
        #expect(governor.rate(cap: 30) == 30)
        governor.record(20, at: 102)
        governor.record(20, at: 104)
        #expect(governor.rate(cap: 30) == 30, "还没量满 3 次")
        #expect(governor.isDue(at: 106) && !governor.isDue(at: 105.9))
        governor.record(20, at: 106)
        #expect(governor.rate(cap: 30) == 20)
        #expect(!governor.isDue(at: 115) && governor.isDue(at: 116), "量满之后每 10 秒量一次")
        governor.record(30, at: 116)
        #expect(governor.rate(cap: 30) == 30, "变快了马上升")
        governor.record(20, at: 126)
        governor.record(20, at: 136)
        #expect(governor.rate(cap: 30) == 30, "30 还在最近 3 次里")
        governor.record(20, at: 146)
        #expect(governor.rate(cap: 30) == 20)
        #expect(governor.rate(cap: 15) == 15, "上限更低时按上限")
        governor.record(0, at: 156)
        #expect(governor.rate(cap: 30) == 30, "比最高一档还快：按上限")
        #expect(governor.rate(cap: 0) == 0)
    }

    /// GPU 缩图：每个输出像素是原画面 4×4 的平均亮度
    @Test func captureAveragesFourByFourBlocks() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let probe = try MotionProbe(device: device)
        let width = 16, height = 8
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        // 左半边白、右半边黑；第 1 行的第 4–7 列（第二个 4×4 块里）一半白一半黑
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where x >= 8 || (y < 4 && x >= 6) {
                pixels.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 3, with: [0, 0, 0])
            }
        }
        source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var frame: LumaFrame? }
        let box = Box()
        probe.capture(source, into: commands) { frame in
            box.frame = frame
            done.signal()
        }
        commands.commit()
        #expect(done.wait(timeout: .now() + 5) == .success)
        let frame = try #require(box.frame)
        #expect(frame.width == 4 && frame.height == 2)
        #expect(frame.pixels[0] == 255 && frame.pixels[4] == 255, "左边整块白")
        #expect(abs(Int(frame.pixels[1]) - 128) <= 1, "一半白一半黑：\(frame.pixels[1])")
        #expect(frame.pixels[5] == 255, "下面那一块全白")
        #expect(frame.pixels[2] == 0 && frame.pixels[3] == 0 && frame.pixels[7] == 0)
    }
}
