import Foundation
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 一段 8 kHz、16 位单声道的静音 WAV
private func silentWAV(seconds: Double) -> Data {
    let samples = Int(8000 * seconds)
    var data = Data()
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data += Data("RIFF".utf8); u32(UInt32(36 + samples * 2)); data += Data("WAVE".utf8)
    data += Data("fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
    data += Data("data".utf8); u32(UInt32(samples * 2))
    data += Data(repeating: 0, count: samples * 2)
    return data
}

private func sound(mode: String, startSilent: Bool = false) -> SceneSound {
    SceneSound(
        name: "测试",
        content: SceneDescription.SoundContent(
            files: ["a.wav"], playbackMode: mode, minTime: 1, maxTime: 2, startSilent: startSilent, volume: 0.5,
            volumeAnimation: nil),
        files: [("a.wav", silentWAV(seconds: 2))])
}

@MainActor
@Suite struct SceneAudioTests {
    @Test func silentUntilEnabledAndPlaying() {
        let audio = SceneAudio(sounds: [sound(mode: "loop")])
        #expect(!audio.isEmpty)
        #expect(audio.problems.isEmpty)
        audio.setPlaying(true)
        #expect(audio.audibleCount == 0)  // 默认静音
        audio.setEnabled(true)
        #expect(audio.audibleCount == 1)
        audio.setPlaying(false)  // 壁纸暂停，声音也停
        #expect(audio.audibleCount == 0)
        audio.setPlaying(true)
        #expect(audio.audibleCount == 1)
        audio.setEnabled(false)
        #expect(audio.audibleCount == 0)
        audio.stop()
    }

    @Test func randomModeCanStartSilent() {
        let audio = SceneAudio(sounds: [sound(mode: "random", startSilent: true)])
        audio.setEnabled(true)
        audio.setPlaying(true)
        #expect(audio.audibleCount == 0)
        audio.stop()
    }

    @Test func unreadableFilesAreReported() {
        let broken = SceneSound(
            name: "坏文件",
            content: SceneDescription.SoundContent(
                files: ["x.ogg"], playbackMode: "loop", minTime: 0, maxTime: 0, startSilent: false, volume: 1,
                volumeAnimation: nil),
            files: [("x.ogg", Data("不是声音".utf8))])
        let audio = SceneAudio(sounds: [broken])
        #expect(audio.isEmpty)
        #expect(audio.problems.count == 1)
    }
}
