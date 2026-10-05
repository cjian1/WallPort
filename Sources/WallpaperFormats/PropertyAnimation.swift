import Foundation

/// 属性上的关键帧动画：`{"animation": {"c0": [关键帧…], "c1": …, "options": {…}}, "value": 静态值}`。
///
/// 结构（2026-09-28 用 ~/wp 里仅有的 3 处核对：Lucy 场景摄像机的 origin / zoom、声音的 volume）：
/// - `options`：fps（帧率）、length（时间轴总帧数）、mode（single 播一遍停在最后、loop 循环、mirror 来回）；
/// - `c0`…`c3`：每个分量一条曲线；关键帧有 frame、value，以及贝塞尔手柄 front（出）/ back（入）的 x、y。
///
/// 手柄的单位 WE 没有公开。两处数据里 front.x 分别是 0.8333（段长 36 帧）和 0.7895（段长 38 帧），
/// 按"x = 1 对应段长的 1/3"（贝塞尔动画曲线的常见约定）换算，手柄都正好约 10 帧，这里按这个理解；
/// y 按同样的比例乘以两端值之差的 1/3。真实数据里 y 都是 0，也就是两端平缓的 S 形。
/// 静态 value 是编辑器里当前显示的值，和关键帧不一定一致，有动画时以关键帧为准。
public struct PropertyAnimation: Sendable, Equatable {
    public struct Keyframe: Sendable, Equatable {
        public let frame: Float
        public let value: Float
        /// 出手柄（指向下一帧）、入手柄（指向上一帧），单位见类型说明
        public let front: SIMD2<Float>
        public let back: SIMD2<Float>

        public init(frame: Float, value: Float, front: SIMD2<Float> = SIMD2(1, 0), back: SIMD2<Float> = SIMD2(-1, 0)) {
            self.frame = frame
            self.value = value
            self.front = front
            self.back = back
        }
    }

    public enum Mode: String, Sendable {
        case single, loop, mirror
    }

    public let fps: Float
    /// 时间轴总帧数
    public let length: Float
    public let mode: Mode
    /// 每个分量一条曲线，关键帧按帧号排好
    public let channels: [[Keyframe]]

    public init(fps: Float, length: Float, mode: Mode, channels: [[Keyframe]]) {
        self.fps = max(fps, 0.001)
        self.length = length
        self.mode = mode
        self.channels = channels.map { $0.sorted { $0.frame < $1.frame } }
    }

    /// 从 `{"animation": …}` 读出动画；不是动画或一条关键帧都没有时返回 nil
    public init?(_ raw: Any?) {
        guard let animation = (raw as? [String: Any])?["animation"] as? [String: Any] else { return nil }
        let options = animation["options"] as? [String: Any] ?? [:]
        var channels: [[Keyframe]] = []
        for index in 0..<4 {
            guard let list = animation["c\(index)"] as? [[String: Any]] else { break }
            channels.append(list.compactMap { key in
                guard let frame = SceneValue.float(key["frame"]), let value = SceneValue.float(key["value"]) else { return nil }
                func handle(_ name: String, _ fallback: SIMD2<Float>) -> SIMD2<Float> {
                    guard let raw = key[name] as? [String: Any] else { return fallback }
                    return SIMD2(SceneValue.float(raw["x"]) ?? fallback.x, SceneValue.float(raw["y"]) ?? fallback.y)
                }
                return Keyframe(frame: frame, value: value, front: handle("front", SIMD2(1, 0)), back: handle("back", SIMD2(-1, 0)))
            })
        }
        guard channels.contains(where: { !$0.isEmpty }) else { return nil }
        let frames = channels.flatMap { $0.map(\.frame) }
        self.init(
            fps: SceneValue.float(options["fps"]) ?? 30,
            length: SceneValue.float(options["length"]) ?? (frames.max() ?? 0),
            mode: Mode(rawValue: SceneValue.string(options["mode"]) ?? "") ?? .loop,
            channels: channels)
    }

    /// 动画开始后 seconds 秒时各分量的值
    public func value(at seconds: Float) -> [Float] {
        let frame = timelineFrame(max(0, seconds) * fps)
        return channels.map { Self.evaluate($0, at: frame) }
    }

    /// 按播放方式把"已经过了多少帧"换算成时间轴上的帧号
    func timelineFrame(_ elapsed: Float) -> Float {
        let end = max(length, channels.flatMap { $0.map(\.frame) }.max() ?? 0)
        guard end > 0 else { return 0 }
        switch mode {
        case .single:
            return min(elapsed, end)
        case .loop:
            return elapsed.truncatingRemainder(dividingBy: end)
        case .mirror:
            let phase = elapsed.truncatingRemainder(dividingBy: 2 * end)
            return phase <= end ? phase : 2 * end - phase
        }
    }

    static func evaluate(_ keys: [Keyframe], at frame: Float) -> Float {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        let index = keys.lastIndex { $0.frame <= frame } ?? 0
        let a = keys[index]
        let b = keys[min(index + 1, keys.count - 1)]
        let span = b.frame - a.frame
        guard span > 0 else { return b.value }
        // 贝塞尔的四个控制点（帧, 值），手柄按"x = 1 对应段长的 1/3"换算
        let third = SIMD2(span / 3, (b.value - a.value) / 3)
        let p0 = SIMD2(a.frame, a.value)
        let p1 = p0 + SIMD2(max(a.front.x, 0), a.front.y) * third
        let p3 = SIMD2(b.frame, b.value)
        let p2 = p3 + SIMD2(min(b.back.x, 0), b.back.y) * third
        // 按帧号解出曲线参数 t（x 方向单调），再取值
        var t = (frame - a.frame) / span
        for _ in 0..<8 {
            let x = bezier(p0.x, p1.x, p2.x, p3.x, t) - frame
            let slope = bezierSlope(p0.x, p1.x, p2.x, p3.x, t)
            guard abs(x) > 1e-4, abs(slope) > 1e-6 else { break }
            t = min(max(t - x / slope, 0), 1)
        }
        return bezier(p0.y, p1.y, p2.y, p3.y, t)
    }

    private static func bezier(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        let u = 1 - t
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
    }

    private static func bezierSlope(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        let u = 1 - t
        return 3 * u * u * (b - a) + 6 * u * t * (c - b) + 3 * t * t * (d - c)
    }
}
