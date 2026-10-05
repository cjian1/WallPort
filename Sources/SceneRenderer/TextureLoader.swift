import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import WallpaperFormats

/// 上传到 GPU 的纹理，以及采样时要用的信息
struct LoadedTexture {
    let texture: any MTLTexture
    /// 图像实际尺寸（像素）
    let imageSize: SIMD2<Float>
    /// 纹理有补齐边距时，采样坐标要乘这个比例（图像尺寸 / 第一层 mipmap 尺寸）
    let uvScale: SIMD2<Float>
    /// 纹理标志第 2 位：边缘夹紧而不是平铺（按真实文件推断：全屏贴图都是 2，32×32 的平铺相位图是 0）
    let clampsUVs: Bool
    /// 纹理标志第 1 位：不做插值（推断，尚未见到实例）
    let usesNearestFiltering: Bool
    /// TEX 里的原始像素格式编号（着色器的 TEX0FORMAT 开关要用）；内嵌图片和运行时纹理按 RGBA8888 即 0
    var rawFormat: Int32 = 0
    /// 精灵图的帧信息
    var spriteSheet: TexFile.SpriteSheet? = nil
    /// 精灵图的第 2、3…张图像（帧的 imageIndex 指向它们；第 0 张就是 `texture`）。
    /// GIF 转来的动画图层帧数多时一张 4096 放不下，会接着放到下一张图像里
    var spriteImages: [any MTLTexture] = []
    /// 精灵图每张图像（含第 0 张）的原始像素尺寸：帧坐标按各自那张图像算，后面的图像常常比第一张小
    /// （Akali：第一张 4096×4096，第二张只有一排帧，是 4096×2048）
    var spriteImageSizes: [SIMD2<Float>] = []
    /// 按原分辨率加载（没有因为屏幕上用不到而跳过 mipmap 或缩小解码）
    var isFullResolution = true
    /// 贴图本身还没完全支持时的说明（例如视频纹理只显示了第一帧）
    var note: String? = nil
    /// 视频纹理：按场景时间取帧（非 nil 时绘制前要换成这一时刻的帧）
    var video: VideoTexture? = nil
}

/// 把 TEX 纹理上传到 Metal。DXT 直接作为 BC 压缩纹理上传，不在 CPU 上解码
final class TextureLoader {
    private let device: any MTLDevice
    private let files: SceneFiles
    private var cache: [String: LoadedTexture] = [:]
    /// 贴图 + 条件 → 包围盒（见 `bounds(of:test:)`）
    private var boundsCache: [BoundsKey: CachedBounds] = [:]

    /// 内嵌 JPEG/PNG 解码时的最大边长。8192×5488 的图解成 RGBA 要 180 MB，缩到这个尺寸对屏幕显示已经足够
    static let maxEmbeddedDimension = 4096

    init(device: any MTLDevice, files: SceneFiles) {
        self.device = device
        self.files = files
    }

    /// 已上传的贴图：名字 → 显存字节数（诊断用）
    var memoryUsage: [(String, Int)] {
        cache.map { ($0.key, $0.value.texture.allocatedSize + $0.value.spriteImages.map(\.allocatedSize).reduce(0, +)) }
    }

    /// 材质里写的纹理名，对应 materials/<名>.tex。
    /// - Parameter fitting: 给出图像尺寸，返回实际用到的像素尺寸（按它在屏幕上占多大算）。
    ///   给了就只加载够用的分辨率：原始格式从够大的那层 mipmap 开始上传，内嵌图片按这个尺寸解码。
    ///   同一张贴图后来要更大的尺寸时重新加载（先拿到小的那一份的图层照用它自己的）
    func texture(named name: String, fitting: ((SIMD2<Float>) -> SIMD2<Int>)? = nil) throws -> LoadedTexture {
        if let cached = cache[name], fitting == nil || covers(cached, fitting!(cached.imageSize)),
           fitting != nil || cached.isFullResolution {
            return cached
        }
        let path = "materials/\(name).tex"
        guard let data = files.data(path) else { throw FormatError("找不到纹理 \(path)") }
        let tex = try TexFile(data: data)
        var needed = fitting?(SIMD2(Float(tex.imageWidth), Float(tex.imageHeight)))
        if let fitting, let frame = tex.spriteSheet?.frames.first, tex.spriteSheet!.frames.count > 1,
           frame.width > 0, frame.height > 0 {
            // 精灵图：屏幕上显示的是一帧，按"一帧要多少像素"推回整张图集要多大（按整张算会挑到很小的一层）
            let perFrame = fitting(SIMD2(frame.width, frame.height))
            needed = SIMD2(Int(saturating: (Float(perFrame.x) * Float(tex.imageWidth) / frame.width).rounded(.up)),
                           Int(saturating: (Float(perFrame.y) * Float(tex.imageHeight) / frame.height).rounded(.up)))
        }
        let loaded = try load(tex, name: name, needed: needed)
        if let cached = cache[name], covers(cached, loadedPixels(loaded)) { return cached }
        cache[name] = loaded
        return loaded
    }

    /// 图像里 alpha 不为 0 的部分（图像的 0–1 坐标：左、上、右、下；全透明时是空的盒子）。
    /// 要把贴图读回来扫一遍，只给能限制特效范围的图层用，结果按贴图缓存；读不了时为 nil
    func contentBounds(of loaded: LoadedTexture) -> SIMD4<Float>? {
        bounds(of: loaded, test: .alpha)
    }

    /// 图像里满足条件的像素的包围盒（图像的 0–1 坐标，见 `EffectRegion.bounds`），按贴图和条件缓存
    func bounds(of loaded: LoadedTexture, test: EffectRegion.PixelTest) -> SIMD4<Float>? {
        let object = loaded.texture as AnyObject
        let key = BoundsKey(texture: ObjectIdentifier(object), test: test)
        // 贴图换成更大的一版后旧的会释放，新贴图可能落在同一个地址上：还得是同一个对象才算命中
        if let cached = boundsCache[key], cached.texture === object { return cached.bounds }
        // 贴图的 0–1 → 图像的 0–1（有补齐边距时图像只占贴图的 uvScale 那一部分）
        let scale = SIMD4(loaded.uvScale.x, loaded.uvScale.y, loaded.uvScale.x, loaded.uvScale.y)
        let bounds = EffectRegion.bounds(of: loaded.texture, test: test).map { simd_min($0 / scale, SIMD4(repeating: 1)) }
        boundsCache[key] = CachedBounds(texture: object, bounds: bounds)
        return bounds
    }

    private struct BoundsKey: Hashable {
        let texture: ObjectIdentifier
        let test: EffectRegion.PixelTest
    }

    private struct CachedBounds {
        weak var texture: AnyObject?
        let bounds: SIMD4<Float>?
    }

    /// 已加载的贴图里图像部分实际有多少像素
    private func loadedPixels(_ texture: LoadedTexture) -> SIMD2<Int> {
        SIMD2(Int(saturating: (Float(texture.texture.width) * texture.uvScale.x).rounded()),
              Int(saturating: (Float(texture.texture.height) * texture.uvScale.y).rounded()))
    }

    private func covers(_ texture: LoadedTexture, _ needed: SIMD2<Int>) -> Bool {
        let pixels = loadedPixels(texture)
        return pixels.x >= needed.x && pixels.y >= needed.y
    }

    private func load(_ tex: TexFile, name: String, needed: SIMD2<Int>?) throws -> LoadedTexture {
        guard let mipmaps = tex.images.first?.mipmaps, let first = mipmaps.first else {
            throw FormatError("纹理 \(name) 没有图像数据")
        }
        let imageSize = SIMD2(Float(tex.imageWidth), Float(tex.imageHeight))
        let storedSize = SIMD2(Float(first.width), Float(first.height))
        // 补齐比例按第一层算；跳过几层 mipmap 或缩小解码之后图像和纹理一起缩小，比例不变
        let padding = simd_min(imageSize / storedSize, SIMD2(1, 1))
        let texture: any MTLTexture
        var isFullResolution = true
        var videoNote: String?
        var video: VideoTexture?
        var spriteImages: [any MTLTexture] = []
        let extraImages = tex.spriteSheet == nil ? [] : Array(tex.images.dropFirst())
        if tex.isVideoTexture {
            // 视频纹理（`.tex` 里装的是 MP4）：WE 会逐帧播放，先解第一帧当兜底，
            // 有 VideoTexture 时每一帧都换成该时刻的帧
            let limit = needed.map { Int(max($0.x, $0.y)) } ?? Self.maxEmbeddedDimension
            texture = try uploadVideoFrame(tex, name: name, maxDimension: limit)
            if let data = tex.images.first?.mipmaps.first?.storedData {
                video = VideoTexture(data: data, device: device, maxDimension: limit)
            }
            videoNote = video == nil ? "视频纹理解码失败，按第一帧显示" : nil
        } else if tex.isEmbeddedImage {
            let longest = needed.map { max($0.x, $0.y, 1) } ?? Self.maxEmbeddedDimension
            let limit = min(Self.maxEmbeddedDimension, longest)
            isFullResolution = limit >= max(tex.imageWidth, tex.imageHeight)
            texture = try uploadEmbedded(first.decompressedData(), name: name, maxDimension: limit)
            spriteImages = try extraImages.compactMap { image in
                try image.mipmaps.first.map { try uploadEmbedded($0.decompressedData(), name: name, maxDimension: limit) }
            }
        } else {
            var level = 0
            if let needed {
                // 跳到仍然不小于需要尺寸的最小一层
                while level + 1 < mipmaps.count,
                      Float(mipmaps[level + 1].width) * padding.x >= Float(needed.x),
                      Float(mipmaps[level + 1].height) * padding.y >= Float(needed.y) {
                    level += 1
                }
            }
            isFullResolution = level == 0
            texture = try uploadRaw(tex, mipmaps: Array(mipmaps[level...]), name: name)
            // 精灵图其余的图像按同一层 mipmap 开始上传（帧坐标是按整张图的比例算的，各张要一样大）
            spriteImages = try extraImages.map { image in
                guard !image.mipmaps.isEmpty else { throw FormatError("纹理 \(name) 的精灵图有一张没有图像数据") }
                return try uploadRaw(tex, mipmaps: Array(image.mipmaps[min(level, image.mipmaps.count - 1)...]), name: name)
            }
        }
        return LoadedTexture(
            texture: texture,
            imageSize: imageSize,
            // 内嵌图片缩小解码时整张按比例缩，补齐比例同样不变
            uvScale: padding,
            clampsUVs: tex.flags & 2 != 0,
            usesNearestFiltering: tex.flags & 1 != 0,
            rawFormat: tex.isEmbeddedImage ? 0 : tex.rawFormat,
            spriteSheet: tex.spriteSheet,
            spriteImages: spriteImages,
            spriteImageSizes: tex.spriteSheet == nil ? [] : tex.images.compactMap { image in
                image.mipmaps.first.map { SIMD2(Float($0.width), Float($0.height)) }
            },
            isFullResolution: isFullResolution,
            note: videoNote,
            video: video)
    }

    /// 视频纹理：用 AVFoundation 解出第一帧（还没做逐帧播放）
    private func uploadVideoFrame(_ tex: TexFile, name: String, maxDimension: Int) throws -> any MTLTexture {
        guard let data = tex.images.first?.mipmaps.first?.storedData else {
            throw FormatError("纹理 \(name) 没有视频数据")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macwallpaper-\(abs(name.hashValue)).mp4")
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            throw FormatError("纹理 \(name) 的视频解码不出画面")
        }
        return try uploadEmbeddedImage(image, name: name, maxDimension: maxDimension)
    }

    private func uploadRaw(_ tex: TexFile, mipmaps: [TexFile.Mipmap], name: String) throws -> any MTLTexture {
        guard let format = tex.pixelFormat else { throw FormatError("纹理 \(name) 的格式 \(tex.rawFormat) 还不支持") }
        let pixelFormat: MTLPixelFormat
        switch format {
        case .rgba8888: pixelFormat = .rgba8Unorm
        case .rg88: pixelFormat = .rg8Unorm
        case .r8: pixelFormat = .r8Unorm
        case .dxt1: pixelFormat = .bc1_rgba
        case .dxt3: pixelFormat = .bc2_rgba
        case .dxt5: pixelFormat = .bc3_rgba
        }
        // 尺寸和 mipmap 链对不上时 Metal 不是返回 nil，而是断言让整个进程退出：先自己核对，坏贴图当错误报出来
        let base = SIMD2(mipmaps[0].width, mipmaps[0].height)
        guard base.x >= 1, base.y >= 1, base.x <= 16384, base.y <= 16384,
              mipmaps.count <= Int(log2(Double(max(base.x, base.y)))) + 1,
              mipmaps.enumerated().allSatisfy({ level, mipmap in
                  mipmap.width == max(1, base.x >> level) && mipmap.height == max(1, base.y >> level)
              })
        else { throw FormatError("纹理 \(name) 的尺寸或 mipmap 层不对（\(base.x)×\(base.y)，\(mipmaps.count) 层）") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: mipmaps[0].width, height: mipmaps[0].height, mipmapped: mipmaps.count > 1)
        descriptor.mipmapLevelCount = mipmaps.count
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw FormatError("无法创建纹理 \(name)（\(mipmaps[0].width)×\(mipmaps[0].height)）")
        }
        for (level, mipmap) in mipmaps.enumerated() {
            // 先核对解压后的大小，免得按文件里随便写的大小去分配内存
            let expected = format.byteCount(width: mipmap.width, height: mipmap.height)
            guard !mipmap.isLZ4Compressed || mipmap.decompressedSize == expected else {
                throw FormatError("纹理 \(name) 第 \(level) 层大小不对")
            }
            let bytes = try mipmap.decompressedData()
            guard bytes.count == format.byteCount(width: mipmap.width, height: mipmap.height) else {
                throw FormatError("纹理 \(name) 第 \(level) 层大小不对")
            }
            let bytesPerRow: Int
            switch format {
            case .dxt1: bytesPerRow = ((mipmap.width + 3) / 4) * 8
            case .dxt3, .dxt5: bytesPerRow = ((mipmap.width + 3) / 4) * 16
            case .rgba8888: bytesPerRow = mipmap.width * 4
            case .rg88: bytesPerRow = mipmap.width * 2
            case .r8: bytesPerRow = mipmap.width
            }
            bytes.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, mipmap.width, mipmap.height), mipmapLevel: level,
                    withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
            }
        }
        return texture
    }

    /// 内嵌 JPEG/PNG：系统解码成 RGBA，带透明度的还原成非预乘（WE 的纹理是非预乘的），再在 GPU 上生成 mipmap
    private func uploadEmbedded(_ data: Data, name: String, maxDimension: Int) throws -> any MTLTexture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw FormatError("纹理 \(name) 的内嵌图片无法识别")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FormatError("纹理 \(name) 的内嵌图片解码失败")
        }
        return try uploadEmbeddedImage(image, name: name, maxDimension: maxDimension)
    }

    /// 把一张已经解出来的图上传成 Metal 纹理（内嵌图片和视频第一帧走同一条路）
    private func uploadEmbeddedImage(_ image: CGImage, name: String, maxDimension: Int) throws -> any MTLTexture {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FormatError("纹理 \(name) 无法创建绘图上下文") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if hasAlpha {
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[index + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for channel in 0..<3 {
                    pixels[index + channel] = UInt8(min(255, Int(pixels[index + channel]) * 255 / alpha))
                }
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw FormatError("无法创建纹理 \(name)（\(width)×\(height)）")
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        if let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer(),
           let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return texture
    }
}
