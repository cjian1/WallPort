import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 一张系统壁纸：图片路径和缩放方式
public struct DesktopPicture: Codable, Equatable, Sendable {
    public var path: String
    /// NSImageScaling 的原始值
    public var scaling: UInt?
    public var allowsClipping: Bool?

    public init(path: String, scaling: UInt? = nil, allowsClipping: Bool? = nil) {
        self.path = path
        self.scaling = scaling
        self.allowsClipping = allowsClipping
    }
}

/// 系统壁纸的读写。抽成协议是为了测试时不去动真实的桌面
@MainActor
public protocol DesktopPictureStore {
    func picture(for displayID: CGDirectDisplayID) -> DesktopPicture?
    func setPicture(_ picture: DesktopPicture, for displayID: CGDirectDisplayID) throws
}

/// 通过 NSWorkspace 读写真实的系统壁纸
@MainActor
public final class WorkspaceDesktopPictures: DesktopPictureStore {
    public init() {}

    public func picture(for displayID: CGDirectDisplayID) -> DesktopPicture? {
        guard let screen = Self.screen(displayID), let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        return DesktopPicture(
            path: url.path,
            scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
            allowsClipping: (options[.allowClipping] as? NSNumber)?.boolValue)
    }

    public func setPicture(_ picture: DesktopPicture, for displayID: CGDirectDisplayID) throws {
        guard let screen = Self.screen(displayID) else { return }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling = picture.scaling { options[.imageScaling] = NSNumber(value: scaling) }
        if let clipping = picture.allowsClipping { options[.allowClipping] = NSNumber(value: clipping) }
        try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: picture.path), for: screen, options: options)
    }

    private static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { DisplaySnapshot(screen: $0)?.id == id }
    }
}

/// 把系统壁纸换成当前动态壁纸的一帧静态画面，关闭或退出时换回原来的。
///
/// 系统会在一些时候把我们的窗口整个藏起来、露出系统壁纸：编辑桌面小组件时（实测三档窗口层级都会被藏起来）、
/// 调度中心的桌面缩略图、锁屏，以及应用退出或崩溃之后。系统壁纸换成同一画面，这些时候看到的就不是另一张图了。
///
/// 原来的系统壁纸按显示器记在 UserDefaults 里；已经是我们生成的图片时不会被当成原壁纸，
/// 所以崩溃后再启动也能恢复到真正的原壁纸。
/// 限制：系统壁纸按空间分别设置时，恢复只作用于当前空间。
@MainActor
public final class SystemWallpaperSync {
    public static var defaultDirectory: URL { AppFolder.systemWallpaper }

    /// 以前放截图的地方：原来的系统壁纸如果记成了那里的截图（崩溃过），也认得出是我们的
    public static var formerDirectories: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacWallpaper/SystemWallpaper", isDirectory: true)]
    }

    private let store: any DesktopPictureStore
    private let directory: URL
    private let formerDirectories: [URL]
    private let defaults: UserDefaults
    private let log: EventLog
    /// 每块显示器当前设上去的画面
    private var applied: [CGDirectDisplayID: DesktopPicture] = [:]
    /// 用户指定的锁屏壁纸。设了它以后，窗口被藏起来（锁屏、调度中心…）时系统壁纸换成这张固定图，
    /// 而不是当前画面；nil 表示跟随当前画面（默认）。只记路径，每次设置时按屏幕尺寸读一次，
    /// 不常驻内存（一张相机原图解码后有上百 MB）
    public var lockScreenImageURL: URL?

    private static let originalsKey = "originalDesktopPictures"

    public init(
        store: any DesktopPictureStore, directory: URL, formerDirectories: [URL] = [], defaults: UserDefaults, log: EventLog
    ) {
        self.store = store
        self.directory = directory.standardizedFileURL
        self.formerDirectories = formerDirectories.map(\.standardizedFileURL)
        self.defaults = defaults
        self.log = log
    }

    /// 把这一帧（设了锁屏壁纸时换成那张图）设为这块显示器的系统壁纸
    public func apply(_ frame: CGImage, to display: DisplaySnapshot) {
        var image = frame
        var isLockScreenPicture = false
        if let url = lockScreenImageURL {
            let longest = max(display.pixelSize.width, display.pixelSize.height)
            if let picture = Self.loadImage(url, maxPixelSize: Int(longest)) {
                image = picture
                isLockScreenPicture = true
            } else {
                log.write("锁屏壁纸：读不到 \(url.path)，这次用当前画面")
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 文件名每次都不同：系统按路径缓存壁纸，同一路径换了内容可能不会刷新
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let file = directory.appendingPathComponent("\(display.stableKey)-\(stamp).jpg")
            try Self.writeJPEG(image, to: file)
            rememberOriginal(of: display)

            let picture = DesktopPicture(
                path: file.path, scaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, allowsClipping: true)
            try store.setPicture(picture, for: display.id)
            applied[display.id] = picture
            removeFiles(of: display, except: file)
            log.write(isLockScreenPicture
                ? "系统壁纸：显示器 \(display.id) 换成锁屏壁纸" : "系统壁纸：显示器 \(display.id) 换成当前画面")
        } catch {
            log.write("系统壁纸：显示器 \(display.id) 设置失败 \(error.localizedDescription)")
        }
    }

    /// 切换空间后，新空间可能还是原来的系统壁纸，重新设一次
    public func reapply() {
        for (id, picture) in applied where store.picture(for: id)?.path != picture.path {
            do {
                try store.setPicture(picture, for: id)
                log.write("系统壁纸：显示器 \(id) 在这个空间里重新设置")
            } catch {
                log.write("系统壁纸：显示器 \(id) 重新设置失败 \(error.localizedDescription)")
            }
        }
    }

    /// 换回原来的系统壁纸，并删掉已恢复的显示器对应的图片。没连着的显示器保留记录，下次再恢复
    public func restore(displays: [DisplaySnapshot]) {
        var originals = loadOriginals()
        for display in displays {
            applied[display.id] = nil
            guard let original = originals[display.stableKey] else { continue }
            do {
                try store.setPicture(original, for: display.id)
                originals[display.stableKey] = nil
                removeFiles(of: display, except: nil)
                log.write("系统壁纸：显示器 \(display.id) 恢复为 \(original.path)")
            } catch {
                log.write("系统壁纸：显示器 \(display.id) 恢复失败 \(error.localizedDescription)")
            }
        }
        saveOriginals(originals)
    }

    // MARK: - 原壁纸记录

    private func rememberOriginal(of display: DisplaySnapshot) {
        var originals = loadOriginals()
        guard originals[display.stableKey] == nil,
              let current = store.picture(for: display.id),
              !isOurs(current.path)
        else { return }
        originals[display.stableKey] = current
        saveOriginals(originals)
        log.write("系统壁纸：记下显示器 \(display.id) 原来的壁纸 \(current.path)")
    }

    private func isOurs(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return ([directory] + formerDirectories).contains { standardized.hasPrefix($0.path + "/") }
    }

    private func loadOriginals() -> [String: DesktopPicture] {
        guard let data = defaults.data(forKey: Self.originalsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: DesktopPicture].self, from: data)) ?? [:]
    }

    private func saveOriginals(_ originals: [String: DesktopPicture]) {
        if originals.isEmpty {
            defaults.removeObject(forKey: Self.originalsKey)
        } else if let data = try? JSONEncoder().encode(originals) {
            defaults.set(data, forKey: Self.originalsKey)
        }
    }

    // MARK: - 文件

    private func removeFiles(of display: DisplaySnapshot, except keep: URL?) {
        let prefix = display.stableKey + "-"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.lastPathComponent != keep?.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 按屏幕尺寸缩小读入，顺带按 EXIF 方向转正（手机拍的照片常常是横着存的）
    static func loadImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func writeJPEG(_ image: CGImage, to file: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
