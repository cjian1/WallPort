import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import DesktopHost

@MainActor
private final class FakeDesktop: DesktopPictureStore {
    var pictures: [CGDirectDisplayID: DesktopPicture] = [:]
    var setCount = 0

    func picture(for displayID: CGDirectDisplayID) -> DesktopPicture? { pictures[displayID] }

    func setPicture(_ picture: DesktopPicture, for displayID: CGDirectDisplayID) throws {
        pictures[displayID] = picture
        setCount += 1
    }
}

@MainActor
@Suite struct SystemWallpaperSyncTests {
    // 用不存在的显示器 ID，stableKey 会退回成 "display-<ID>"，不依赖本机硬件
    private let display = DisplaySnapshot(id: 9001, name: "测试屏", frame: CGRect(x: 0, y: 0, width: 8, height: 8), scale: 1)
    private let original = DesktopPicture(path: "/Users/me/Pictures/海.jpg", scaling: 3, allowsClipping: true)
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SystemWallpaperSyncTests-\(UUID().uuidString)", isDirectory: true)
    private let suiteName = "SystemWallpaperSyncTests-\(UUID().uuidString)"

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    private func withSync(_ body: (SystemWallpaperSync, FakeDesktop, () -> SystemWallpaperSync) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let desktop = FakeDesktop()
        desktop.pictures[display.id] = original
        let make = { SystemWallpaperSync(store: desktop, directory: directory, defaults: defaults, log: EventLog(fileURL: directory.appendingPathComponent("log.txt"))) }
        try body(make(), desktop, make)
    }

    @Test func applyReplacesPictureWithOurJPEG() throws {
        try withSync { sync, desktop, _ in
            sync.apply(makeImage(), to: display)
            let current = try #require(desktop.pictures[display.id])
            #expect(current.path.hasPrefix(directory.standardizedFileURL.path + "/"))
            #expect(current.path.hasSuffix(".jpg"))
            #expect(FileManager.default.fileExists(atPath: current.path))
        }
    }

    /// 设了锁屏壁纸时写进系统壁纸的是那张图（按屏幕尺寸缩小），读不到时退回当前画面
    @Test func lockScreenImageReplacesTheFrame() throws {
        try withSync { sync, desktop, _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 一张 64×32 的蓝图当"锁屏照片"；显示器是 8×8，写进去的应当缩到最长边 8
            let context = CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            let photo = directory.appendingPathComponent("photo.png")
            let destination = try #require(CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))

            sync.lockScreenImageURL = photo
            sync.apply(makeImage(), to: display)
            let written = try #require(desktop.pictures[display.id]).path
            let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: written) as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 8 && image.height == 4)

            sync.lockScreenImageURL = directory.appendingPathComponent("不存在.png")
            sync.apply(makeImage(), to: display)
            let fallback = try #require(desktop.pictures[display.id]).path
            let fallbackSource = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: fallback) as CFURL, nil))
            let fallbackImage = try #require(CGImageSourceCreateImageAtIndex(fallbackSource, 0, nil))
            #expect(fallbackImage.width == 8 && fallbackImage.height == 8)
        }
    }

    @Test func restoreBringsBackTheOriginalAndDeletesOurFiles() throws {
        try withSync { sync, desktop, _ in
            sync.apply(makeImage(), to: display)
            let ours = try #require(desktop.pictures[display.id]).path
            sync.restore(displays: [display])
            #expect(desktop.pictures[display.id] == original)
            #expect(!FileManager.default.fileExists(atPath: ours))
        }
    }

    @Test func repeatedApplyKeepsTheFirstOriginalAndOnlyTheLatestFile() throws {
        try withSync { sync, desktop, _ in
            sync.apply(makeImage(), to: display)
            sync.apply(makeImage(), to: display)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".jpg") }
            #expect(files.count == 1)
            sync.restore(displays: [display])
            #expect(desktop.pictures[display.id] == original)
        }
    }

    @Test func afterACrashOurOwnPictureIsNotMistakenForTheOriginal() throws {
        try withSync { first, desktop, make in
            first.apply(makeImage(), to: display)
            // 模拟崩溃后重启：新实例，系统壁纸还是我们上次设的图
            let second = make()
            second.apply(makeImage(), to: display)
            second.restore(displays: [display])
            #expect(desktop.pictures[display.id] == original)
        }
    }

    /// 截图目录挪进统一文件夹以后：系统壁纸还是旧目录里我们的截图（挪之前崩溃过），也不能当成原来的壁纸记下
    @Test func picturesInTheFormerDirectoryAreOursToo() throws {
        let former = directory.appendingPathComponent("former", isDirectory: true)
        let current = directory.appendingPathComponent("current", isDirectory: true)
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let desktop = FakeDesktop()
        desktop.pictures[display.id] = original
        let log = EventLog(fileURL: directory.appendingPathComponent("log.txt"))
        // 旧版：截图放在旧目录，然后崩溃
        SystemWallpaperSync(store: desktop, directory: former, defaults: defaults, log: log).apply(makeImage(), to: display)
        defaults.removePersistentDomain(forName: suiteName)
        // 新版：截图放在新目录；系统壁纸还是旧目录那张
        let sync = SystemWallpaperSync(
            store: desktop, directory: current, formerDirectories: [former], defaults: defaults, log: log)
        sync.apply(makeImage(), to: display)
        sync.restore(displays: [display])
        // 旧目录那张没被当成"原来的壁纸"：退出时不会把系统壁纸设回一张旧截图（旧目录删掉以后就成了坏图）
        let restored = try #require(desktop.pictures[display.id])
        #expect(!restored.path.hasPrefix(former.standardizedFileURL.path + "/"), "\(restored.path)")
    }

    @Test func reapplyOnlyTouchesDisplaysShowingSomethingElse() throws {
        try withSync { sync, desktop, _ in
            sync.apply(makeImage(), to: display)
            let ours = desktop.pictures[display.id]
            let before = desktop.setCount
            sync.reapply()
            #expect(desktop.setCount == before)

            // 切到另一个空间，那里还是原来的壁纸
            desktop.pictures[display.id] = original
            sync.reapply()
            #expect(desktop.pictures[display.id] == ours)
        }
    }

    @Test func restoreWithoutApplyChangesNothing() throws {
        try withSync { sync, desktop, _ in
            sync.restore(displays: [display])
            #expect(desktop.setCount == 0)
            #expect(desktop.pictures[display.id] == original)
        }
    }
}
