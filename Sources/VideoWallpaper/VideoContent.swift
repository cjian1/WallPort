import AppKit
import AVFoundation
import DesktopHost

/// 视频壁纸：硬件解码、无缝循环，默认静音（菜单里打开"播放壁纸声音"才出声）。什么时候暂停由 PlaybackGate 决定。
@MainActor
public final class VideoContent: DesktopContent, UserPausable, AudioPlaying {
    public let view: NSView
    public let url: URL
    public var isPausedByUser: Bool { gate.isPausedByUser }

    private let playerView: PlayerView
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var observations: [NSKeyValueObservation] = []
    /// 第一帧解码出来之前，控制器靠它把旧画面留在屏幕上
    private var readyHandler: (@MainActor () -> Void)?
    private let label: String
    private let log: EventLog
    private let onFailure: @MainActor (String) -> Void
    private var hasFailed = false

    private lazy var gate = PlaybackGate { [weak self] playing, reason in
        self?.playbackDidChange(playing, reason: reason)
    }

    /// - Parameters:
    ///   - label: 写日志用的前缀，例如"显示器 1"
    ///   - onFailure: 文件读不了或解码失败时调用，参数是原因。调用方通常会换成别的内容
    public init(url: URL, label: String, log: EventLog, onFailure: @escaping @MainActor (String) -> Void) {
        VideoDecoders.registerSystemDecoders()
        self.url = url
        self.label = label
        self.log = log
        self.onFailure = onFailure

        player.isMuted = true
        // 壁纸不能阻止显示器按时休眠
        player.preventsDisplaySleepDuringVideoPlayback = false
        let playerView = PlayerView(player: player)
        self.playerView = playerView
        view = playerView

        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        self.looper = looper
        observations = [
            looper.observe(\.status) { [weak self] _, _ in
                Task { @MainActor in self?.looperStatusDidChange() }
            },
            looper.observe(\.loopCount) { [weak self] _, _ in
                Task { @MainActor in self?.loopCountDidChange() }
            },
        ]
        log.write("\(label) 视频：载入 \(url.path)")
        gate.start(reason: "载入")
        // 铺满时按"画面位置"挪、完整显示时留黑边，都要先知道画面的宽高
        Task { [weak playerView] in
            let size = await Self.displaySize(of: url)
            playerView?.videoSize = size
        }
    }

    /// 壁纸设置里的显示方式：完整显示（两边留黑）或铺满（`position` 是被裁方向上看哪一部分，0 最左 / 最上）
    public func setDisplay(fitsWhole: Bool, position: Float) {
        playerView.fitsWhole = fitsWhole
        playerView.position = CGFloat(min(max(position, 0), 1))
    }

    /// 视频画面在屏幕上的宽高（带上旋转）；读不出来时为 nil，按默认的铺满放
    private nonisolated static func displaySize(of url: URL) async -> CGSize? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let size = natural.applying(transform)
        return size.width != 0 && size.height != 0 ? CGSize(width: abs(size.width), height: abs(size.height)) : nil
    }

    /// 第一帧解码出来（`AVPlayerLayer` 会自己说）时回调；视频坏掉一直解不出来时由控制器的超时兜底
    public func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if playerView.isReadyForDisplay { handler(); return }
        readyHandler = handler
        observations.append(playerView.playerLayer.observe(\.isReadyForDisplay) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in
                self?.readyHandler?()
                self?.readyHandler = nil
            }
        })
    }

    public func setAudioEnabled(_ enabled: Bool) {
        player.isMuted = !enabled
    }

    public func setVolume(_ volume: Float) {
        player.volume = min(max(volume, 0), 1)
    }

    /// 选文件时先检查一遍，免得把 WebM 这类 AVFoundation 解不了的文件设成壁纸。返回 nil 表示可以播放
    public nonisolated static func unplayableReason(for url: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return String(localized: "文件不存在") }
        // MP4 里装 VP9 的视频要先登记系统自带的解码器，否则会被当成"无法播放"
        VideoDecoders.registerSystemDecoders()
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else {
                return String(localized: "系统无法播放这个文件，可能是 WebM 等 AVFoundation 不支持的格式")
            }
            if try await asset.loadTracks(withMediaType: .video).isEmpty {
                return String(localized: "文件里没有视频轨道")
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func setPausedByUser(_ paused: Bool) {
        gate.setPausedByUser(paused)
    }

    // MARK: - DesktopContent

    /// 画面那一层在视图的 layout 里按新尺寸重新摆
    public func displayDidChange(_ display: DisplaySnapshot) {}

    public func visibilityDidChange(isVisible: Bool) {
        gate.setVisible(isVisible)
    }

    /// 当前播放位置的一帧。默认的铺满居中交给系统壁纸的"填充"方式（和播放时的裁切一致），按视频原尺寸给；
    /// 改过显示方式（完整显示、换了画面位置）时按屏幕上实际的样子拼一张
    public func snapshot() async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let frame: CGImage
        do {
            frame = try await generator.image(at: player.currentTime()).image
        } catch {
            log.write("\(label) 视频：截取当前画面失败 \(error.localizedDescription)")
            return nil
        }
        guard playerView.fitsWhole || playerView.position != 0.5 else { return frame }
        let scale = playerView.window?.backingScaleFactor ?? 2
        let bounds = playerView.bounds
        let place = playerView.playerLayer.frame
        guard bounds.width > 0, bounds.height > 0,
              let context = CGContext(
                data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return frame }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(
            x: place.minX * scale, y: place.minY * scale, width: place.width * scale, height: place.height * scale))
        return context.makeImage() ?? frame
    }

    public func tearDown() {
        gate.invalidate()
        observations.forEach { $0.invalidate() }
        observations = []
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
    }

    // MARK: - 播放状态

    private func playbackDidChange(_ playing: Bool, reason: String) {
        if playing { player.play() } else { player.pause() }
        log.write("\(label) 视频：\(playing ? "播放" : "暂停")（\(reason)）")
    }

    private func looperStatusDidChange() {
        guard let looper else { return }
        switch looper.status {
        case .ready:
            log.write("\(label) 视频：就绪")
        case .failed:
            fail(looper.error?.localizedDescription ?? String(localized: "未知错误"))
        default:
            break
        }
    }

    private func loopCountDidChange() {
        guard let count = looper?.loopCount, count == 1 || count % 500 == 0 else { return }
        log.write("\(label) 视频：已循环 \(count) 次")
    }

    private func fail(_ reason: String) {
        guard !hasFailed else { return }
        hasFailed = true
        gate.invalidate()
        player.pause()
        log.write("\(label) 视频：无法播放 \(url.lastPathComponent)：\(reason)")
        onFailure(reason)
    }
}

/// 视频画面那一层放在黑底上：铺满时按比例放大、按"画面位置"挪（多出来的被裁掉），
/// 完整显示时整张放进来、两边留黑。还不知道画面宽高时按 AVPlayerLayer 自己的铺满居中
final class PlayerView: NSView {
    /// 换壁纸时要立刻能查"解码出第一帧了吗"，所以直接暴露出来
    let playerLayer: AVPlayerLayer
    var videoSize: CGSize? {
        didSet { if videoSize != oldValue { needsLayout = true } }
    }
    var fitsWhole = false {
        didSet { if fitsWhole != oldValue { needsLayout = true } }
    }
    var position: CGFloat = 0.5 {
        didSet { if position != oldValue { needsLayout = true } }
    }

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    /// 已经解码出可以显示的第一帧
    var isReadyForDisplay: Bool { playerLayer.isReadyForDisplay }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = Self.videoFrame(in: bounds, video: videoSize, fitsWhole: fitsWhole, position: position)
        CATransaction.commit()
    }

    /// 画面那一层的位置（视图坐标，左下原点）。铺满：按大的那个比例放大，被裁的方向上 position 0 露出最左 / 最上；
    /// 完整显示：按小的那个比例缩、居中
    static func videoFrame(in bounds: CGRect, video: CGSize?, fitsWhole: Bool, position: CGFloat) -> CGRect {
        guard let video, video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let ratio = (bounds.width / video.width, bounds.height / video.height)
        let scale = fitsWhole ? min(ratio.0, ratio.1) : max(ratio.0, ratio.1)
        let size = CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
        let spare = CGSize(width: bounds.width - size.width, height: bounds.height - size.height)
        let along = fitsWhole ? 0.5 : min(max(position, 0), 1)
        return CGRect(
            x: (spare.width * along).rounded(), y: (spare.height * (1 - along)).rounded(),
            width: size.width, height: size.height)
    }
}
