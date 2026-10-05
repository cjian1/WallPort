import Foundation
import Testing
@testable import DesktopHost

/// 启动时提前申请授权：文件位置逐个读一下，系统音频只在第一次启动时开一下采集。
/// App 等 `prime` 返回才把壁纸放上桌面：它只等文件访问，系统音频在后台接着问（`audioRequest`），不挡壁纸
@MainActor
@Suite struct PermissionPrimerTests {
    /// 后台线程里调的 acquire 用它计数
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "PermissionPrimerTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private var log: EventLog {
        EventLog(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("primer-test.log"))
    }

    /// 同一个位置换种写法（多一个结尾斜杠、带 `.`）只读一次，顺序不变
    @Test func locationsAreDeduplicatedInOrder() {
        let unique = PermissionPrimer.unique([
            URL(fileURLWithPath: "/tmp/b"), URL(fileURLWithPath: "/tmp/a/"),
            URL(fileURLWithPath: "/tmp/./b"), URL(fileURLWithPath: "/tmp/a"),
        ])
        #expect(unique.map(\.path) == ["/tmp/b", "/tmp/a"])
    }

    /// 文件夹、文件、不存在的路径都能读（不存在的直接跳过，不会卡住）
    @Test func touchingReadsFoldersAndFilesAndSkipsMissingOnes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionPrimerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("lock.png")
        try Data([1, 2, 3]).write(to: file)
        let slow = PermissionPrimer.touch([folder, file, folder.appendingPathComponent("没有这个")])
        #expect(slow.isEmpty)
    }

    /// 开始采集的调用会等到用户点了允许才返回：`prime` 不等它（壁纸马上放上桌面），
    /// 答完马上停采集（用户已经答过了）；同一个 App 身份只问一次，身份变了再问
    @Test func primeDoesNotWaitForTheAudioAnswerAndOnlyAsksOnce() async throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let acquired = Counter()
        var released = 0
        func primer(_ identity: String = "build-1") -> PermissionPrimer {
            PermissionPrimer(
                defaults: defaults, log: log,
                acquireAudio: { acquired.increment(); Thread.sleep(forTimeInterval: 0.6); return true },
                releaseAudio: { released += 1 }, audioHold: .seconds(30), audioAvailable: true, codeIdentity: identity)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let first = primer()
        let finished = await first.prime(locations: [])
        #expect(finished)
        #expect(clock.now - started < .milliseconds(400), "壁纸不等系统音频的弹窗")
        await first.audioRequest?.value
        #expect(acquired.count == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(released == 1, "用户已经答过了，不用再开 30 秒")

        let second = primer()
        await second.prime(locations: [])
        await second.audioRequest?.value
        #expect(acquired.count == 1, "问过一次就不再开采集")

        // 重新构建（临时签名变了），系统会忘掉授权：启动时要再问
        let rebuilt = primer("build-2")
        await rebuilt.prime(locations: [])
        await rebuilt.audioRequest?.value
        #expect(acquired.count == 2)
    }

    /// 开始采集的调用很快就返回（授权早就决定了，或者系统没等用户回应）：多开一会儿再停，免得弹窗跟着消失
    @Test func quickAcquireIsHeldBeforeRelease() async throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var released = 0
        let primer = PermissionPrimer(
            defaults: defaults, log: log, acquireAudio: { true }, releaseAudio: { released += 1 },
            audioHold: .milliseconds(300), audioAvailable: true)
        await primer.prime(locations: [])
        await primer.audioRequest?.value
        #expect(released == 0)
        try await Task.sleep(for: .milliseconds(600))
        #expect(released == 1)
    }

    /// 用户一直不答系统音频的弹窗：壁纸照样马上出来；答完之后采集照样会停
    @Test func slowAudioAnswerDoesNotHoldTheWallpaper() async throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var released = 0
        let primer = PermissionPrimer(
            defaults: defaults, log: log,
            acquireAudio: { Thread.sleep(forTimeInterval: 0.8); return true },
            releaseAudio: { released += 1 }, audioAvailable: true)
        let clock = ContinuousClock()
        let started = clock.now
        let finished = await primer.prime(locations: [], timeout: .milliseconds(100))
        #expect(finished, "文件都读完了，没有超时")
        #expect(clock.now - started < .milliseconds(600))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(released == 1)
    }

    /// 开采集失败（例如没有输出设备）也登记过使用者，照样要还
    @Test func failedAudioRequestStillReleases() async throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var released = 0
        let primer = PermissionPrimer(
            defaults: defaults, log: log, acquireAudio: { false }, releaseAudio: { released += 1 },
            audioHold: .milliseconds(10), audioAvailable: true)
        await primer.prime(locations: [])
        await primer.audioRequest?.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(released == 1)
    }

    /// 系统太旧（进程 tap 要 macOS 14.2）时不开采集，也不记成"问过了"
    @Test func unavailableAudioIsNotRequested() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let acquired = Counter()
        let primer = PermissionPrimer(
            defaults: defaults, log: log, acquireAudio: { acquired.increment(); return true }, releaseAudio: {},
            audioAvailable: false)
        await primer.prime(locations: [])
        await primer.audioRequest?.value
        #expect(acquired.count == 0)
        #expect(defaults.string(forKey: PermissionPrimer.audioRequestedKey) == nil)
    }
}
