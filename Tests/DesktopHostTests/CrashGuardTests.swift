import Foundation
import Testing
@testable import DesktopHost

@Suite struct CrashGuardTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-guard-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("loading.json")
    }

    @Test func scenesStillLoadingWhenTheAppDiedAreSuspectsNextTime() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = CrashGuard(file: file)
        #expect(first.suspects.isEmpty)
        let a = first.begin("/a")
        first.begin("/b")
        first.end(a)
        // 这里"崩了"：没有 clear
        let second = CrashGuard(file: file)
        #expect(second.suspects == ["/b"])
        // 只拦一次：再下一次启动不再拦
        #expect(CrashGuard(file: file).suspects.isEmpty)
    }

    /// 同一张壁纸载入两次（重建、两块屏幕）：先载入的那次到时擦掉，后载入的那次照样记着
    @Test func overlappingLoadsOfTheSameSceneAreTrackedSeparately() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let guardian = CrashGuard(file: file)
        let first = guardian.begin("/a")
        let rebuild = guardian.begin("/a")
        guardian.end(first)
        // 失败回调和定时器都会擦同一笔：重复调用没关系
        guardian.end(first)
        #expect(FileManager.default.fileExists(atPath: file.path))
        guardian.end(rebuild)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cleanExitLeavesNothing() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let guardian = CrashGuard(file: file)
        guardian.begin("/a")
        guardian.clear()
        #expect(CrashGuard(file: file).suspects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
