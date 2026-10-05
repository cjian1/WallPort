import Foundation

/// 决定内容此刻该播放还是暂停，视频和网页壁纸共用。
///
/// - 用户手动暂停立即生效；
/// - 被完全遮挡要持续一段时间才暂停：M0 的日志显示，切换空间的动画里遮挡状态会在几毫秒内来回跳，
///   直接跟着暂停和恢复会让画面卡顿；
/// - 重新露出立即恢复。
@MainActor
public final class PlaybackGate {
    public private(set) var isPlaying = false
    public private(set) var isPausedByUser = false

    private var isVisible = true
    private var isInvalidated = false
    private var pendingPause: Task<Void, Never>?
    private let grace: Duration
    private let onChange: @MainActor (_ isPlaying: Bool, _ reason: String) -> Void

    public init(
        grace: Duration = .seconds(1),
        onChange: @escaping @MainActor (_ isPlaying: Bool, _ reason: String) -> Void
    ) {
        self.grace = grace
        self.onChange = onChange
    }

    /// 按当前状态做第一次决定
    public func start(reason: String) {
        update(reason: reason)
    }

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        update(reason: visible ? "重新露出" : "被完全遮挡")
    }

    public func setPausedByUser(_ paused: Bool) {
        guard paused != isPausedByUser else { return }
        isPausedByUser = paused
        update(reason: paused ? "手动暂停" : "手动继续")
    }

    /// 内容被拆掉时调用，之后不再回调
    public func invalidate() {
        isInvalidated = true
        pendingPause?.cancel()
        pendingPause = nil
    }

    private func update(reason: String) {
        pendingPause?.cancel()
        pendingPause = nil
        guard !isInvalidated else { return }

        if isPausedByUser {
            set(false, reason: reason)
        } else if isVisible {
            set(true, reason: reason)
        } else if isPlaying {
            let grace = grace
            pendingPause = Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                self?.set(false, reason: "\(reason)超过 \(Self.describe(grace))")
            }
        }
    }

    private func set(_ playing: Bool, reason: String) {
        guard !isInvalidated, playing != isPlaying else { return }
        isPlaying = playing
        onChange(playing, reason)
    }

    private static func describe(_ duration: Duration) -> String {
        let milliseconds = Int(duration / .milliseconds(1))
        return milliseconds % 1000 == 0 ? "\(milliseconds / 1000) 秒" : "\(milliseconds) 毫秒"
    }
}

/// 可以被用户手动暂停的内容（视频、网页）
@MainActor
public protocol UserPausable: DesktopContent {
    var isPausedByUser: Bool { get }
    func setPausedByUser(_ paused: Bool)
}

/// 可以调帧率上限的内容（场景、网页）。0 表示不限制，跟着显示器刷新率
@MainActor
public protocol FrameRateAdjustable: DesktopContent {
    func setMaximumFrameRate(_ fps: Int)
    /// 按画面变得多快在上限之下自动降帧（只有场景支持）
    func setAdaptiveFrameRate(_ enabled: Bool)
}

public extension FrameRateAdjustable {
    func setAdaptiveFrameRate(_ enabled: Bool) {}
}
