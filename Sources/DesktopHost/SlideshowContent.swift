import AppKit
import ImageIO

/// 图片幻灯片：按顺序或随机轮流显示一组图片，淡入淡出切换；显示方式（铺满 / 完整显示、画面位置、等比缩放）
/// 和图片壁纸一样。依赖型网页预设（例如"完美壁纸"的幻灯片预设）由壁坞直接放它打包的图片文件夹：
/// 切换间隔可以按秒设，图片按屏幕尺寸解码（原图常有几千万像素），下一张提前在后台解好。
/// 桌面被挡住、用户暂停时不换（省电），露出来时已经过了点就马上换
@MainActor
public final class SlideshowContent: DesktopContent, FramingAdjustable, UserPausable {
    public let view: NSView
    /// 离开屏幕也能给出当前这张，锁屏 / 屏保同步用
    public var snapshotsWhileHidden: Bool { true }
    public var isPausedByUser: Bool { pausedByUser }

    /// 两张之间淡入淡出的时间
    nonisolated static let fadeDuration: TimeInterval = 1
    /// 切换间隔最短几秒：比淡入淡出短就看不清了
    public nonisolated static let minimumInterval: TimeInterval = 2
    /// 连着解不出这么多张就当整组都坏了
    nonisolated static let maxDecodeAttempts = 8

    private let files: [URL]
    private let label: String
    private let log: EventLog
    private let onFailure: @MainActor (String) -> Void
    private let slideView = SlideshowView()
    private var targetPixelSize: CGSize
    private var interval: TimeInterval
    private var shuffles: Bool
    /// 正在显示的那张（下标、解好的图）
    private var current: (index: Int, image: CGImage)?
    /// 下一张：显示完一张就开始在后台解
    private var upcoming: Task<(index: Int, image: CGImage)?, Never>?
    private var timer: Timer?
    /// 下一次该换的时间。到点时被挡住或暂停就先不换，露出来或继续时再换
    private var nextChange: Date?
    private var isVisible = true
    private var pausedByUser = false
    private var readyHandler: (@MainActor () -> Void)?
    private var hasFailed = false
    private var isTornDown = false

    public init(
        files: [URL], interval: TimeInterval, shuffles: Bool, label: String, log: EventLog,
        targetPixelSize: CGSize = .zero, onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.files = files
        self.interval = max(Self.minimumInterval, interval)
        self.shuffles = shuffles
        self.label = label
        self.log = log
        self.targetPixelSize = targetPixelSize
        self.onFailure = onFailure
        view = slideView
        log.write("\(label) 幻灯片：\(files.count) 张，每 \(Self.describe(self.interval))换一张\(shuffles ? "，随机顺序" : "")")
        guard !files.isEmpty else {
            fail(String(localized: "没有可以显示的图片"))
            return
        }
        advance(animated: false)
    }

    // MARK: - 设置

    public func setDisplay(fitsWhole: Bool, position: Float, scale: Float) {
        slideView.fitsWhole = fitsWhole
        slideView.position = CGFloat(min(max(position, 0), 1))
        slideView.scale = CGFloat(scale)
    }

    /// 改了切换间隔：从这一张出现时算起按新的间隔换（已经超过就马上换）
    public func setInterval(_ seconds: TimeInterval) {
        let seconds = max(Self.minimumInterval, seconds)
        guard seconds != interval else { return }
        let shownAt = nextChange.map { $0.addingTimeInterval(-interval) } ?? Date()
        interval = seconds
        log.write("\(label) 幻灯片：改成每 \(Self.describe(seconds))换一张")
        guard current != nil, files.count > 1 else { return }
        timer?.invalidate()
        timer = nil
        nextChange = shownAt.addingTimeInterval(seconds)
        resumeIfDue()
    }

    /// 改了顺序 / 随机：已经提前解好的下一张作废，按新的方式重新挑
    public func setShuffles(_ shuffles: Bool) {
        guard shuffles != self.shuffles else { return }
        self.shuffles = shuffles
        guard let current else { return }
        upcoming?.cancel()
        upcoming = prepare(after: current.index)
    }

    // MARK: - DesktopContent

    public func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if current != nil { handler() } else { readyHandler = handler }
    }

    public func displayDidChange(_ display: DisplaySnapshot) {
        targetPixelSize = display.pixelSize
    }

    public func visibilityDidChange(isVisible: Bool) {
        self.isVisible = isVisible
        resumeIfDue()
    }

    public func setPausedByUser(_ paused: Bool) {
        pausedByUser = paused
        resumeIfDue()
    }

    public func snapshot() async -> CGImage? {
        guard let image = current?.image else { return nil }
        return ImageContent.render(
            image, size: targetPixelSize, fitsWhole: slideView.fitsWhole, position: slideView.position,
            scale: slideView.scale)
    }

    public func tearDown() {
        isTornDown = true
        timer?.invalidate()
        timer = nil
        upcoming?.cancel()
        upcoming = nil
        readyHandler = nil
        current = nil
        slideView.clear()
    }

    #if DEBUG
    /// 测试用：不等间隔，直接换下一张；正在显示第几张
    func advanceForTesting() { advance(animated: false) }
    var currentIndexForTesting: Int? { current?.index }
    #endif

    // MARK: - 换图

    /// 换下一张：用提前解好的，没有就现解
    private func advance(animated: Bool) {
        timer?.invalidate()
        timer = nil
        nextChange = nil
        let task = upcoming ?? prepare(after: current?.index)
        upcoming = nil
        Task { [weak self] in
            let next = await task.value
            guard let self, !self.isTornDown else { return }
            guard let next else {
                self.fail(String(localized: "图片都解不出来"))
                return
            }
            self.show(next, animated: animated)
        }
    }

    private func show(_ next: (index: Int, image: CGImage), animated: Bool) {
        current = next
        slideView.show(next.image, animated: animated)
        if let handler = readyHandler {
            readyHandler = nil
            handler()
        }
        guard files.count > 1 else { return }
        upcoming = prepare(after: next.index)
        schedule(after: interval)
    }

    /// 在后台解 `index` 之后该放的那张；解不出来的跳过，往后再试几张
    private func prepare(after index: Int?) -> Task<(index: Int, image: CGImage)?, Never> {
        let files = files
        let size = targetPixelSize
        let start = Self.nextIndex(after: index, count: files.count, shuffles: shuffles)
        return Task.detached(priority: .utility) {
            var candidate = start
            for _ in 0..<min(files.count, Self.maxDecodeAttempts) {
                if Task.isCancelled { return nil }
                if let image = ImageContent.decode(files[candidate], targetPixelSize: size) { return (candidate, image) }
                candidate = (candidate + 1) % files.count
            }
            return nil
        }
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        nextChange = Date().addingTimeInterval(delay)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        timer.tolerance = min(1, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        timer = nil
        guard isVisible, !pausedByUser else { return }
        advance(animated: true)
    }

    /// 露出来或继续了：已经过了该换的时间就马上换，没到就接着等剩下的
    private func resumeIfDue() {
        guard isVisible, !pausedByUser, timer == nil, current != nil, let nextChange else { return }
        let remaining = nextChange.timeIntervalSinceNow
        if remaining <= 0 { advance(animated: true) } else { schedule(after: remaining) }
    }

    private func fail(_ reason: String) {
        guard !hasFailed else { return }
        hasFailed = true
        log.write("\(label) 幻灯片：放不了（\(reason)）")
        onFailure(reason)
    }

    /// 下一张的下标：按顺序循环；随机时每次重新挑，但不连着放同一张
    nonisolated static func nextIndex(
        after current: Int?, count: Int, shuffles: Bool, random: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Int {
        guard count > 1 else { return 0 }
        guard shuffles else { return current.map { ($0 + 1) % count } ?? 0 }
        guard let current else { return random(count) }
        let pick = random(count - 1)
        return pick >= current ? pick + 1 : pick
    }

    /// 日志里的间隔："30 秒"、"5 分钟"
    nonisolated static func describe(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole >= 60 && whole % 60 == 0 ? "\(whole / 60) 分钟" : "\(whole) 秒"
    }
}

/// 两层图片：新的一张在上面一层淡入、旧的同时淡出，然后两层交换角色
@MainActor
private final class SlideshowView: NSView {
    private var front = CALayer()
    private var back = CALayer()
    private var frontImage: CGImage?
    private var backImage: CGImage?
    var fitsWhole = false {
        didSet { if fitsWhole != oldValue { needsLayout = true } }
    }
    var position: CGFloat = 0.5 {
        didSet { if position != oldValue { needsLayout = true } }
    }
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        for slide in [back, front] {
            slide.masksToBounds = true
            layer?.addSublayer(slide)
        }
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    func show(_ image: CGImage, animated: Bool) {
        // 新图放进下面那层，摆好位置（不要动画）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        back.contents = image
        back.frame = frame(for: image)
        back.contentsScale = window?.backingScaleFactor ?? 2
        back.opacity = 0
        back.zPosition = 1
        front.zPosition = 0
        CATransaction.commit()
        backImage = image
        // 再一起淡入淡出：完整显示时两张大小不同，旧的不淡出会从新图边上露出来
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(SlideshowContent.fadeDuration)
        } else {
            CATransaction.setDisableActions(true)
        }
        back.opacity = 1
        front.opacity = 0
        CATransaction.commit()
        swap(&front, &back)
        swap(&frontImage, &backImage)
    }

    func clear() {
        for slide in [front, back] { slide.contents = nil }
        frontImage = nil
        backImage = nil
    }

    private func frame(for image: CGImage) -> CGRect {
        Framing.frame(
            in: bounds, content: CGSize(width: image.width, height: image.height),
            fitsWhole: fitsWhole, position: position, scale: scale)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let contentsScale = window?.backingScaleFactor ?? 2
        for (slide, image) in [(front, frontImage), (back, backImage)] {
            if let image { slide.frame = frame(for: image) }
            slide.contentsScale = contentsScale
        }
        CATransaction.commit()
    }
}
