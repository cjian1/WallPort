import Foundation
import Testing
@testable import WallpaperFormats

/// 手写的关键帧动画，结构照 WE 场景文件：c0 一条曲线，两端手柄的 y 为 0（两端平缓）
private func animation(mode: String, from: Float = 0.5, to: Float = 0.8, frames: Int = 38) -> Any {
    let json = """
    {"animation": {"c0": [
        {"frame": 0, "value": \(from), "front": {"x": 0.8, "y": 0}, "back": {"x": -1, "y": 0}},
        {"frame": \(frames), "value": \(to), "front": {"x": 1, "y": 0}, "back": {"x": -0.8, "y": 0}}],
      "options": {"fps": 12, "length": 60, "mode": "\(mode)"}}, "value": 1.0}
    """
    return try! JSONSerialization.jsonObject(with: Data(json.utf8))
}

@Suite struct PropertyAnimationTests {
    @Test func readsOptionsAndKeyframes() throws {
        let parsed = try #require(PropertyAnimation(animation(mode: "single")))
        #expect(parsed.fps == 12)
        #expect(parsed.length == 60)
        #expect(parsed.mode == .single)
        #expect(parsed.channels.count == 1)
        #expect(parsed.channels[0].map(\.frame) == [0, 38])
        #expect(parsed.channels[0][0].front == SIMD2(0.8, 0))
        #expect(PropertyAnimation(1.0) == nil)
        #expect(PropertyAnimation(["value": 1.0]) == nil)
    }

    @Test func singleModeEasesAndThenHolds() throws {
        let parsed = try #require(PropertyAnimation(animation(mode: "single")))
        #expect(abs(parsed.value(at: 0)[0] - 0.5) < 1e-4)
        // 两端手柄对称、平缓：正中间就是平均值，前段慢后段也慢
        #expect(abs(parsed.value(at: 19.0 / 12)[0] - 0.65) < 1e-3)
        let early = parsed.value(at: 4.0 / 12)[0] - 0.5
        #expect(early > 0 && early < 0.3 * 4 / 38)
        // 38 帧之后停在最后的值，时间轴走完也不回头
        #expect(abs(parsed.value(at: 38.0 / 12)[0] - 0.8) < 1e-4)
        #expect(abs(parsed.value(at: 100)[0] - 0.8) < 1e-4)
    }

    @Test func valuesIncreaseMonotonically() throws {
        let parsed = try #require(PropertyAnimation(animation(mode: "single")))
        var previous: Float = -1
        for frame in 0...38 {
            let value = parsed.value(at: Float(frame) / 12)[0]
            #expect(value >= previous - 1e-5)
            previous = value
        }
    }

    @Test func loopAndMirrorWrapAroundTheTimeline() throws {
        // 时间轴 60 帧，关键帧在 0 和 60
        let loop = try #require(PropertyAnimation(animation(mode: "loop", from: 0, to: 1, frames: 60)))
        #expect(abs(loop.value(at: 70.0 / 12)[0] - loop.value(at: 10.0 / 12)[0]) < 1e-4)
        let mirror = try #require(PropertyAnimation(animation(mode: "mirror", from: 0, to: 1, frames: 60)))
        #expect(abs(mirror.value(at: 70.0 / 12)[0] - mirror.value(at: 50.0 / 12)[0]) < 1e-4)
    }

    @Test func soundObjectsCarryTheirSettings() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 5, "name": "音乐", "sound": ["sounds/a.mp3", "sounds/b.mp3"], "playbackmode": "random",
                      "mintime": 1, "maxtime": 5, "startsilent": true, "volume": 0.4},
                     {"id": 6, "sound": ["sounds/c.mp3"], "volume": \(String(decoding: try JSONSerialization.data(withJSONObject: animation(mode: "single")), as: UTF8.self))}]}
        """
        let description = try SceneDescription(json: Data(scene.utf8))
        let first = try #require(description.objects[0].sound)
        #expect(first.files == ["sounds/a.mp3", "sounds/b.mp3"])
        #expect(first.playbackMode == "random")
        #expect(first.minTime == 1 && first.maxTime == 5)
        #expect(first.startSilent)
        #expect(first.volume(at: 10) == 0.4)
        let second = try #require(description.objects[1].sound)
        #expect(second.playbackMode == "loop")
        #expect(abs(second.volume(at: 0) - 0.5) < 1e-4)
        #expect(abs(second.volume(at: 10) - 0.8) < 1e-4)
    }
}
