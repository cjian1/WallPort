import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import SceneRenderer
import WallpaperFormats

/// 按 TexFile 注释里的结构拼 TEX：mipmaps 为每层的 (宽, 高, 数据)
private func makeTex(
    textureSize: SIMD2<Int>, imageSize: SIMD2<Int>, freeImage: Int32 = -1, mipmaps: [(Int, Int, Data)]
) -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    u32(0)  // RGBA8888
    u32(2)
    u32(UInt32(textureSize.x)); u32(UInt32(textureSize.y)); u32(UInt32(imageSize.x)); u32(UInt32(imageSize.y))
    u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1)
    u32(UInt32(bitPattern: freeImage))
    u32(UInt32(mipmaps.count))
    for (width, height, bytes) in mipmaps {
        u32(UInt32(width)); u32(UInt32(height))
        u32(0); u32(UInt32(bytes.count))
        u32(UInt32(bytes.count))
        data += bytes
    }
    return data
}

private func rgba(_ width: Int, _ height: Int) -> Data { Data(repeating: 200, count: width * height * 4) }

private func png(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func loader(_ files: [String: Data]) throws -> (TextureLoader, any MTLDevice) {
    var header = Data()
    func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
    u32(8)
    header += Data("PKGV0001".utf8)
    u32(files.count)
    var body = Data()
    for (name, data) in files.sorted(by: { $0.key < $1.key }) {
        u32(name.utf8.count)
        header += Data(name.utf8)
        u32(body.count)
        u32(data.count)
        body += data
    }
    let device = try #require(MTLCreateSystemDefaultDevice())
    let files = SceneFiles(package: try ScenePackage(data: header + body), assets: nil)
    return (TextureLoader(device: device, files: files), device)
}

@Suite struct TextureLoaderTests {
    /// 64×32 的纹理里放 60×30 的图像，3 层 mipmap
    private let padded = makeTex(
        textureSize: SIMD2(64, 32), imageSize: SIMD2(60, 30),
        mipmaps: [(64, 32, rgba(64, 32)), (32, 16, rgba(32, 16)), (16, 8, rgba(16, 8))])

    @Test func onlyTheNeededMipLevelsAreUploaded() throws {
        let (textures, _) = try loader(["materials/a.tex": padded])
        // 屏幕上只要 20×10：第 1 层（32×16，图像部分 30×15）够用，第 2 层（15×7.5）不够
        let small = try textures.texture(named: "a") { _ in SIMD2(20, 10) }
        #expect(small.texture.width == 32)
        #expect(small.texture.mipmapLevelCount == 2)
        #expect(!small.isFullResolution)
        // 补齐比例不因跳过几层而改变；图像尺寸仍是原图的（图层按它摆放）
        #expect(small.uvScale == SIMD2(60.0 / 64, 30.0 / 32))
        #expect(small.imageSize == SIMD2(60, 30))
    }

    @Test func largerRequestsReloadAndSmallerOnesReuse() throws {
        let (textures, _) = try loader(["materials/a.tex": padded])
        let small = try textures.texture(named: "a") { _ in SIMD2(20, 10) }
        #expect(try textures.texture(named: "a") { _ in SIMD2(10, 5) }.texture === small.texture)
        let large = try textures.texture(named: "a") { _ in SIMD2(60, 30) }
        #expect(large.texture.width == 64)
        #expect(large.isFullResolution)
        // 不带要求的调用拿到原分辨率
        #expect(try textures.texture(named: "a").texture === large.texture)
    }

    @Test func embeddedImagesAreDecodedAtTheNeededSize() throws {
        let tex = makeTex(
            textureSize: SIMD2(256, 128), imageSize: SIMD2(200, 100), freeImage: 13,
            mipmaps: [(200, 100, try png(width: 200, height: 100))])
        let (textures, _) = try loader(["materials/b.tex": tex])
        let small = try textures.texture(named: "b") { _ in SIMD2(50, 25) }
        #expect(small.texture.width == 50)
        #expect(small.texture.height == 25)
        #expect(small.uvScale == SIMD2(1, 1))
        #expect(small.imageSize == SIMD2(200, 100))
        #expect(try textures.texture(named: "b").texture.width == 200)
    }

    /// 贴图头里的尺寸、mipmap 层对不上时 Metal 会直接断言让进程退出：要先认出来，当成坏贴图报错
    @Test func brokenMipmapChainsAreErrorsNotCrashes() throws {
        let broken: [String: [(Int, Int, Data)]] = [
            "zero": [(0, 32, Data())],
            "wrongLevel": [(64, 32, rgba(64, 32)), (64, 16, rgba(64, 16))],
            "tooManyLevels": [(2, 2, rgba(2, 2)), (1, 1, rgba(1, 1)), (1, 1, rgba(1, 1))],
            "lz4Lies": [(64, 32, Data())],
        ]
        var files = broken.mapValues { makeTex(textureSize: SIMD2(64, 32), imageSize: SIMD2(64, 32), mipmaps: $0) }
        // 标成 LZ4 压缩、解压后 8192 字节，数据却是空的（以前解压时拿空数据的指针直接崩）
        var lz4 = files["lz4Lies"]!
        let flag = lz4.count - 12
        lz4.replaceSubrange(flag..<flag + 8, with: [1, 0, 0, 0, 0x00, 0x20, 0, 0])
        files["materials/lz4Lies.tex"] = lz4
        files["lz4Lies"] = nil
        let (textures, _) = try loader(Dictionary(uniqueKeysWithValues: files.map { key, value in
            (key.hasPrefix("materials/") ? key : "materials/\(key).tex", value)
        }))
        for name in broken.keys {
            #expect(throws: (any Error).self, "\(name)") { try textures.texture(named: name) }
        }
    }
}
