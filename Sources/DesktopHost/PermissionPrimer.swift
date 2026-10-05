import Foundation
import Security

/// 进软件时就把要用到的系统授权问完，别等到用户挑壁纸的时候才一个个弹出来：
///
/// - **文件访问**：壁纸文件夹、WE 自带素材目录、各屏正在用的壁纸、锁屏图片放在「文稿」「下载」「桌面」、
///   iCloud 云盘或外置盘里时，第一次读取会弹系统的访问授权（每类位置问一次，之后系统记住）。
///   启动时在后台把它们逐个读一下，弹窗就出现在启动的时候；读取会一直等到用户回应，所以不能放在主线程。
///   每次启动都读：已经答过的不会再弹，新加的位置（例如上次运行时才换的壁纸）也能提前问到。
/// - **系统音频录制**：音乐可视化壁纸要读系统正在播放的声音频谱。没有公开接口能单独申请这个授权，
///   只有真的开始采集时系统才弹，所以第一次启动时开一下采集，之后不再重复（按 App 的代码签名身份记：
///   临时签名每次构建都会变，系统也会把授权忘掉，这时要重新问）。实测开始采集的调用会
///   **一直等到用户点了允许或拒绝**才返回（原来在主线程上调，弹窗期间整个 App 卡住），所以放到后台线程。
///
/// 两类按顺序来：文件的问完再问音频，免得弹窗叠在一起。调用方等 `prime` 返回再把壁纸放上桌面，
/// 但 `prime` **只等文件访问**：壁纸要读文件，没授权就读不出来；系统音频只有音乐可视化壁纸用得到，
/// 在后台接着问、不挡着壁纸（原来也等它，开发时每次重新签名都要重新问，壁纸晚出来 1.5～74 秒）。
@MainActor
public final class PermissionPrimer {
    public static let audioRequestedKey = "didRequestSystemAudioCapture"

    private let defaults: UserDefaults
    private let log: EventLog
    private let acquireAudio: @Sendable () -> Bool
    private let releaseAudio: () -> Void
    private let audioHold: Duration
    private let audioAvailable: Bool
    /// 问过授权时记下的 App 身份；和现在的不一样就再问一次
    private let codeIdentity: String

    /// 开始采集的调用等了这么久才返回，就当它是在等用户回应弹窗：用户已经答过了，采集可以马上停
    static let answeredThreshold: Duration = .milliseconds(500)
    /// 后台进行中的系统音频授权请求（`prime` 不等它；测试用它等结果）
    public private(set) var audioRequest: Task<Void, Never>?

    /// - Parameters:
    ///   - audioHold: 开始采集的调用很快就返回时（授权早就决定了，或者系统没有等用户回应），
    ///     为了弹授权临时开着的采集保持多久再停——弹窗还没答就停掉的话，弹窗可能跟着消失
    public init(
        defaults: UserDefaults = AppFolder.settings, log: EventLog,
        acquireAudio: @escaping @Sendable () -> Bool = { SystemAudioSpectrum.shared.acquire() },
        releaseAudio: @escaping () -> Void = { SystemAudioSpectrum.shared.release() },
        audioHold: Duration = .seconds(15), audioAvailable: Bool? = nil,
        codeIdentity: String? = PermissionPrimer.currentCodeIdentity()
    ) {
        self.defaults = defaults
        self.log = log
        self.codeIdentity = codeIdentity ?? "unsigned"
        self.acquireAudio = acquireAudio
        self.releaseAudio = releaseAudio
        self.audioHold = audioHold
        if let audioAvailable {
            self.audioAvailable = audioAvailable
        } else if #available(macOS 14.2, *) {
            self.audioAvailable = true
        } else {
            self.audioAvailable = false
        }
    }

    /// 先问文件访问，答完（或者等满 `timeout`）就返回；系统音频在文件问完之后在后台接着问（见 `audioRequest`）。
    /// `timeout` 是兜底：网络盘卡住之类的情况不能让壁纸一直出不来。
    /// 返回 false 表示等超时了（后台的读取照样继续，读完再问音频）
    @discardableResult
    public func prime(locations: [URL], timeout: Duration = .seconds(60)) async -> Bool {
        let files = Task { await self.touchFiles(Self.unique(locations)) }
        audioRequest = Task {
            await files.value
            await self.requestSystemAudio()
        }
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            Task { await files.value; once.resume(true) }
            Task { try? await Task.sleep(for: timeout); once.resume(false) }
        }
        if !finished {
            log.write("启动：等文件访问授权超过 \(timeout)，先把壁纸放上桌面")
        }
        return finished
    }

    private func touchFiles(_ locations: [URL]) async {
        let slow = await Task.detached(priority: .userInitiated) { Self.touch(locations) }.value
        for (path, seconds) in slow {
            log.write("启动：读取 \(path) 用了 \(String(format: "%.1f", seconds)) 秒（多半在等用户回应访问授权）")
        }
    }

    /// 当前 App 的代码签名身份（cdhash）。系统的隐私授权认的就是签名：临时签名每次构建都不一样
    public nonisolated static func currentCodeIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// 去掉重复（同一个路径写法不同）的位置，保持原来的顺序
    nonisolated static func unique(_ locations: [URL]) -> [URL] {
        var seen: Set<String> = []
        return locations.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// 把每个位置读一下：文件夹列一下目录，文件打开再关上。受保护的位置在这里弹授权，并一直等到用户回应。
    /// 不先判断存不存在：没授权时连"存不存在"都可能查不到，那样就永远弹不出来了。返回等得久的位置
    nonisolated static func touch(_ locations: [URL]) -> [(path: String, seconds: Double)] {
        var slow: [(path: String, seconds: Double)] = []
        for url in locations {
            let started = Date()
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) == nil {
                try? FileHandle(forReadingFrom: url).close()
            }
            let seconds = Date().timeIntervalSince(started)
            if seconds > 1 { slow.append((url.path, seconds)) }
        }
        return slow
    }

    /// 第一次启动时开一下系统音频采集，让系统弹出"系统音频录制"的授权；之后的启动不再开。
    /// App 的签名身份变了（开发时的临时签名每次构建都变）系统会忘掉授权，这时再问一次
    func requestSystemAudio() async {
        guard audioAvailable, defaults.string(forKey: Self.audioRequestedKey) != codeIdentity else { return }
        defaults.set(codeIdentity, forKey: Self.audioRequestedKey)
        let acquire = acquireAudio
        let clock = ContinuousClock()
        let started = clock.now
        let running = await Task.detached(priority: .userInitiated) { acquire() }.value
        let waited = clock.now - started
        if running {
            let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
            log.write("启动：请求系统音频录制授权（开始采集的调用等了 \(String(format: "%.1f", seconds)) 秒）")
        } else {
            log.write("启动：系统音频采集不可用——\(SystemAudioSpectrum.shared.problem ?? "未知原因")")
        }
        // 等了很久才返回说明是在等用户回应，已经答完了，马上停；很快就返回的话弹窗可能还在，多开一会儿。
        // acquire 失败也登记过使用者，照样要还
        let hold = waited >= Self.answeredThreshold ? Duration.zero : audioHold
        let release = releaseAudio
        Task {
            if hold > .zero { try? await Task.sleep(for: hold) }
            release()
        }
    }
}

/// 两个任务谁先完成就用谁的结果，另一个再 resume 时忽略
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
