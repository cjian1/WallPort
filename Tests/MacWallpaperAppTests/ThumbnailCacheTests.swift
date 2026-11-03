import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacWallpaperApp
import WallpaperLibrary

/// 磁盘上的缩略图：以前总取第一帧存下的全黑图要重做，看得见的接着用（不用重新下载）
@Suite struct ThumbnailCacheTests {
    private let url = URL(string: "https://images.example.invalid/ugc/1/ABCDEF/")!

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeJPEG(_ r: UInt8, _ g: UInt8, _ b: UInt8, to file: URL) throws {
        let side = 64
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let destination = try #require(CGImageDestinationCreateWithURL(
            file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func legacyBlackThumbnailIsDroppedSoItGetsRedone() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent(ThumbnailCache.legacyDiskName(url))
        try writeJPEG(0, 0, 0, to: legacy)

        #expect(ThumbnailCache.savedThumbnail(for: url, in: directory) == nil)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func legacyVisibleThumbnailIsKeptUnderTheNewName() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent(ThumbnailCache.legacyDiskName(url))
        try writeJPEG(200, 120, 40, to: legacy)

        let image = try #require(ThumbnailCache.savedThumbnail(for: url, in: directory))
        #expect(!WorkshopPreview.isBlank(image))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(ThumbnailCache.diskName(url)).path))
    }

    @Test func newThumbnailIsUsedEvenWhenTheWholePreviewIsBlank() throws {
        // 新取法存下的就是找过以后的结果（整张预览都是空帧时才会是黑的）：照用，不再一遍遍重新下载
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeJPEG(0, 0, 0, to: directory.appendingPathComponent(ThumbnailCache.diskName(url)))

        #expect(ThumbnailCache.savedThumbnail(for: url, in: directory) != nil)
        #expect(ThumbnailCache.diskName(url) != ThumbnailCache.legacyDiskName(url))
    }
}
