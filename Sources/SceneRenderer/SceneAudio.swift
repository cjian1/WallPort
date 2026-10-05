import AVFoundation
import DesktopHost
import Foundation
import WallpaperFormats

/// 场景里的一个声音对象：设置和它的声音文件（已经从场景包或自带素材里读出来）
public struct SceneSound: Sendable {
    public let name: String
    public let content: SceneDescription.SoundContent
    /// 和 content.files 一一对应；读不到的文件不在这里
    public let files: [(path: String, data: Data)]
}

/// 播放场景里的声音对象。和视频、网页一样默认不出声，打开"播放壁纸声音"才播；
/// 壁纸暂停（被遮住或用户暂停）时声音也暂停，恢复时从停下的地方接着放。
///
/// 播放方式：loop 循环（多个文件按顺序轮流）；random 放完一段随机等 minTime…maxTime 秒再随机放一段，
/// startSilent 时开场先等；single 按顺序放一遍。音量有关键帧动画时按"已经播放的秒数"取值。
@MainActor
final class SceneAudio: NSObject, AVAudioPlayerDelegate {
    private final class Track {
        let sound: SceneSound
        let players: [AVAudioPlayer]
        var current: Int?
        /// random 模式：下一段在 elapsed 到这个值时开始
        var nextStart: Double?
        var isFinished = false

        init(sound: SceneSound, players: [AVAudioPlayer]) {
            self.sound = sound
            self.players = players
        }
    }

    private var tracks: [Track] = []
    private var isEnabled = false
    private var isPlaying = false
    /// 壁纸设置里的音量，乘在每个声音对象自己的音量上
    private var masterVolume: Float = 1
    /// 声音实际在放的累计秒数（暂停和静音时不走），音量动画和随机间隔都按它算
    private(set) var elapsed: Double = 0
    private var timer: Timer?
    private var lastTick: Date?
    private var random = SystemRandomNumberGenerator()
    /// 文件读不了（格式不支持等）的原因
    private(set) var problems: [String] = []

    /// 正在出声的音轨数（测试和诊断用）
    var audibleCount: Int { tracks.filter { track in track.current.map { track.players[$0].isPlaying } ?? false }.count }

    init(sounds: [SceneSound]) {
        super.init()
        for sound in sounds {
            var players: [AVAudioPlayer] = []
            for file in sound.files {
                do {
                    let player = try AVAudioPlayer(data: file.data)
                    player.delegate = self
                    player.prepareToPlay()
                    players.append(player)
                } catch {
                    problems.append("\(sound.name) 的 \(file.path) 放不了：\(error.localizedDescription)")
                }
            }
            guard !players.isEmpty else { continue }
            let track = Track(sound: sound, players: players)
            if sound.content.playbackMode == "loop", players.count == 1 { players[0].numberOfLoops = -1 }
            if sound.content.playbackMode == "random", sound.content.startSilent { track.nextStart = randomGap(sound) }
            tracks.append(track)
        }
    }

    var isEmpty: Bool { tracks.isEmpty }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        refresh()
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        refresh()
    }

    func setMasterVolume(_ volume: Float) {
        masterVolume = min(max(volume, 0), 1)
        updateVolumes()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for track in tracks { track.players.forEach { $0.stop() } }
    }

    private var isActive: Bool { isEnabled && isPlaying && !tracks.isEmpty }

    private func refresh() {
        if isActive {
            lastTick = Date()
            for track in tracks {
                if let current = track.current {
                    track.players[current].play()
                } else if !track.isFinished, track.nextStart == nil {
                    start(track, index: firstIndex(track))
                }
            }
            updateVolumes()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
            advanceClock()
            for track in tracks { track.current.map { track.players[$0].pause() } }
        }
    }

    private func advanceClock() {
        if let lastTick { elapsed += Date().timeIntervalSince(lastTick) }
        lastTick = isActive ? Date() : nil
    }

    private func tick() {
        advanceClock()
        for track in tracks where track.current == nil && !track.isFinished {
            if let nextStart = track.nextStart, elapsed >= nextStart {
                track.nextStart = nil
                start(track, index: Int.random(in: 0..<track.players.count, using: &random))
            }
        }
        updateVolumes()
    }

    private func updateVolumes() {
        for track in tracks {
            let volume = track.sound.content.volume(at: Float(elapsed)) * masterVolume
            track.players.forEach { $0.volume = volume }
        }
    }

    private func firstIndex(_ track: Track) -> Int {
        track.sound.content.playbackMode == "random" ? Int.random(in: 0..<track.players.count, using: &random) : 0
    }

    private func start(_ track: Track, index: Int) {
        track.current = index
        let player = track.players[index]
        player.currentTime = 0
        player.volume = track.sound.content.volume(at: Float(elapsed)) * masterVolume
        if isActive { player.play() }
    }

    private func randomGap(_ sound: SceneSound) -> Double {
        let low = Double(min(sound.content.minTime, sound.content.maxTime))
        let high = Double(max(sound.content.minTime, sound.content.maxTime))
        return elapsed + (high > low ? Double.random(in: low...high, using: &random) : low)
    }

    /// 一段放完：loop 接下一段（单个文件时 AVAudioPlayer 自己循环，不会走到这里），random 等一会儿，single 放下一段或结束
    private func finished(_ player: AVAudioPlayer) {
        guard let track = tracks.first(where: { $0.players.contains { $0 === player } }) else { return }
        let next = (track.current ?? 0) + 1
        track.current = nil
        switch track.sound.content.playbackMode {
        case "random":
            track.nextStart = randomGap(track.sound)
        case "single":
            if next < track.players.count { start(track, index: next) } else { track.isFinished = true }
        default:
            start(track, index: next % track.players.count)
        }
    }

    /// 回调不保证在主线程，转回主线程处理
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        nonisolated(unsafe) let player = player
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(player) } }
    }
}
