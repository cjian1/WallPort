import Foundation
import WallpaperLibrary

/// `WallpaperTool steam-assets <输出目录>`：用本机存的 Steam 会话下载 Wallpaper Engine 自带素材
/// （和 App 里"登录后自动下载"同一条路）；`steam-assets --version` 只看 Steam 上现在是哪个版本
func steamAssets(output: String?) async -> Int32 {
    setvbuf(stdout, nil, _IONBF, 0)
    guard let session = SteamCMSessionStore().load() else {
        print("✗ 本机还没有存过 Steam 会话（先在壁坞里登录一次）")
        return 1
    }
    print("用本机存的会话：账号 \(session.accountName)")
    let native = WorkshopNative()
    do {
        guard let output else {
            print("Steam 上的版本：\(try await native.engineAssetsVersion(session: session))")
            return 0
        }
        let started = Date()
        let printed = PercentPrinter()
        let version = try await native.downloadEngineAssets(
            session: session, to: URL(fileURLWithPath: output, isDirectory: true)
        ) { fraction in printed.show(fraction) }
        print("✓ 版本 \(version)，用了 \(Int(Date().timeIntervalSince(started))) 秒，装在 \(output)")
        return 0
    } catch {
        print("✗ \(error.localizedDescription)")
        return 1
    }
}

/// 每过 10% 打一行
private final class PercentPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func show(_ fraction: Double) {
        let step = Int(fraction * 10)
        lock.withLock {
            guard step > last else { return }
            last = step
            print("  \(step * 10)%")
        }
    }
}
