import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import DesktopHost

/// "隐藏壁纸"要真的把桌面露出来（系统壁纸同步会把当前画面设成系统壁纸，只藏窗口的话看到的还是同一张图），
/// 以及锁屏 / 睡眠前要按"此刻"的画面重新设一次系统壁纸（睡下去以后动态壁纸就停了，
/// 而锁屏上看到的是系统壁纸）。
@MainActor
@Suite struct HideAndLockTests {
    private final class FakeDesktop: DesktopPictureStore {
        var pictures: [CGDirectDisplayID: DesktopPicture] = [:]
        func picture(for displayID: CGDirectDisplayID) -> DesktopPicture? { pictures[displayID] }
        func setPicture(_ picture: DesktopPicture, for displayID: CGDirectDisplayID) throws {
            pictures[displayID] = picture
        }
    }

    /// 能截图的假内容；`snapshotsWhileHidden` 由测试决定（场景 / 视频是 true，网页是 false）
    private final class FakeContent: DesktopContent {
        let view = NSView()
        let canSnapshotWhileHidden: Bool
        private(set) var snapshotCount = 0

        init(snapshotsWhileHidden: Bool) { canSnapshotWhileHidden = snapshotsWhileHidden }

        var snapshotsWhileHidden: Bool { canSnapshotWhileHidden }

        func snapshot() async -> CGImage? {
            snapshotCount += 1
            let context = CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            return context.makeImage()
        }

        func displayDidChange(_ display: DisplaySnapshot) {}
        func visibilityDidChange(isVisible: Bool) {}
    }

    private struct Fixture {
        let controller: WallpaperController
        let sync: SystemWallpaperSync
        let desktop: FakeDesktop
        let display: DisplaySnapshot
        let directory: URL
        let original: DesktopPicture
    }

    private func makeFixture(snapshotsWhileHidden: Bool) -> Fixture {
        let display = DisplaySnapshot(
            id: 900_002, name: "测试屏", frame: CGRect(x: -30_000, y: -30_000, width: 320, height: 200), scale: 2)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HideAndLockTests-\(UUID().uuidString)", isDirectory: true)
        let desktop = FakeDesktop()
        let original = DesktopPicture(path: "/Users/me/Pictures/猫.jpg", scaling: 3, allowsClipping: true)
        desktop.pictures[display.id] = original
        let defaults = UserDefaults(suiteName: "HideAndLockTests-\(UUID().uuidString)")!
        let log = EventLog(fileURL: directory.appendingPathComponent("log.txt"))
        let sync = SystemWallpaperSync(store: desktop, directory: directory, defaults: defaults, log: log)
        let content = FakeContent(snapshotsWhileHidden: snapshotsWhileHidden)
        let controller = WallpaperController(level: .desktop, log: log) { _ in content }
        controller.displaySource = { [display] }
        controller.systemWallpaperSync = sync
        controller.start()
        return Fixture(
            controller: controller, sync: sync, desktop: desktop, display: display, directory: directory,
            original: original)
    }

    /// 同步过一帧以后系统壁纸是我们的画面；隐藏壁纸要把它换回用户原来的那张
    @Test func hidingBringsBackTheOriginalDesktopPicture() throws {
        let fixture = makeFixture(snapshotsWhileHidden: true)
        defer {
            fixture.controller.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixture.sync.apply(try #require(frame()), to: fixture.display)
        let ours = try #require(fixture.desktop.pictures[fixture.display.id])
        #expect(ours.path.hasPrefix(fixture.directory.standardizedFileURL.path + "/"))

        fixture.controller.setShown(false)

        #expect(fixture.desktop.pictures[fixture.display.id] == fixture.original, "隐藏壁纸要把系统壁纸换回原来的")

        // 再显示出来不崩，而且状态回到"显示"
        fixture.controller.setShown(true)
        #expect(fixture.controller.isShown)
    }

    /// 隐藏期间（窗口被藏起来）不截图同步——系统壁纸已经换回原来的了
    @Test func hidingStopsSyncingWithTheOriginalRestored() throws {
        let fixture = makeFixture(snapshotsWhileHidden: true)
        defer {
            fixture.controller.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixture.sync.apply(try #require(frame()), to: fixture.display)
        fixture.controller.setShown(false)

        fixture.controller.refreshSystemWallpaper(reason: "锁屏")
        #expect(fixture.desktop.pictures[fixture.display.id] == fixture.original)
    }

    /// 锁屏 / 睡眠前：按此刻的画面重新设一次系统壁纸（窗口这时通常已经不在屏幕上了）
    @Test func lockRefreshAppliesTheCurrentFrame() async throws {
        let fixture = makeFixture(snapshotsWhileHidden: true)
        defer {
            fixture.controller.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        #expect(fixture.desktop.pictures[fixture.display.id] == fixture.original)

        fixture.controller.refreshSystemWallpaper(reason: "锁屏")
        try await Task.sleep(for: .milliseconds(300))

        let current = try #require(fixture.desktop.pictures[fixture.display.id])
        #expect(current.path.hasPrefix(fixture.directory.standardizedFileURL.path + "/"), "锁屏前应当把当前画面设成系统壁纸")
    }

    /// 网页壁纸在被藏起来的时候截不准（可能是空白），保住上一次设上去的画面
    @Test func contentThatCannotSnapshotWhileHiddenIsSkipped() async throws {
        let fixture = makeFixture(snapshotsWhileHidden: false)
        defer {
            fixture.controller.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixture.controller.refreshSystemWallpaper(reason: "锁屏")
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.desktop.pictures[fixture.display.id] == fixture.original)
    }

    private func frame() -> CGImage? {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context?.makeImage()
    }
}
