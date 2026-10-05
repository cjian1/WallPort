import Compression
import Foundation

/// Wallpaper Engine 的 .tex 纹理文件。
///
/// 结构（2026-09-28 用 ~/wp 里的真实纹理逐字节核对，见 REFERENCES.md）。整数都是小端 int32，
/// 版本字符串以 NUL 结尾：
///
///     "TEXV0005"  "TEXI0001"
///     [格式][标志][纹理宽][纹理高][图像宽][图像高][未知 4 字节]
///     "TEXB000n"  [图像数]  （0003 起加 [FreeImage 格式]，0004 再加 [是否 MP4]）
///     图像 × 图像数：[mipmap 数]
///         mipmap × mipmap 数：[宽][高]（0002 起加 [是否 LZ4 压缩][解压后大小]）[数据大小][数据]
///     其后可能还有精灵图的帧信息（TEXS 段，见 `SpriteSheet`）
///
/// 纹理宽高是分配的尺寸，图像宽高是实际画面的尺寸，两者可能不同。
/// FreeImage 格式不是 -1 时，数据是一个完整的图片文件（JPEG、PNG 等），而不是原始像素。
public struct TexFile: Sendable {
    /// 原始像素格式。编号的含义由真实文件验证：原始数据的字节数必须和按格式算出的一致
    public enum PixelFormat: Int32, Sendable {
        case rgba8888 = 0
        case dxt5 = 4
        case dxt3 = 6
        case dxt1 = 7
        case rg88 = 8
        case r8 = 9

        /// 一层 mipmap 原始数据应有的字节数
        public func byteCount(width: Int, height: Int) -> Int {
            let blocks = ((width + 3) / 4) * ((height + 3) / 4)
            switch self {
            case .rgba8888: return width * height * 4
            case .rg88: return width * height * 2
            case .r8: return width * height
            case .dxt1: return blocks * 8
            case .dxt3, .dxt5: return blocks * 16
            }
        }
    }

    public struct Mipmap: Sendable {
        public let width: Int
        public let height: Int
        public let isLZ4Compressed: Bool
        public let decompressedSize: Int
        /// 文件里存的原样数据；LZ4 压缩时需要先调用 decompressedData()
        public let storedData: Data

        public func decompressedData() throws -> Data {
            guard isLZ4Compressed else { return storedData }
            return try LZ4.decompressRaw(storedData, decompressedSize: decompressedSize)
        }
    }

    public struct Image: Sendable {
        public let mipmaps: [Mipmap]
    }

    public let fileVersion: String
    public let headerVersion: String
    public let containerVersion: String
    public let rawFormat: Int32
    public let flags: Int32
    public let textureWidth: Int
    public let textureHeight: Int
    public let imageWidth: Int
    public let imageHeight: Int
    /// TEXB0003 起才有；-1 表示原始像素
    public let freeImageFormat: Int32?
    /// TEXB0004 起才有
    public let isVideo: Bool?
    public let images: [Image]
    /// 精灵图（粒子的逐帧动画）的帧信息；普通纹理为 nil
    public let spriteSheet: SpriteSheet?
    /// 图像数据之后剩下的字节数（动图帧信息等）
    public let trailingByteCount: Int

    public var pixelFormat: PixelFormat? { PixelFormat(rawValue: rawFormat) }
    /// 数据是完整的图片文件（JPEG、PNG……），不是原始像素
    public var isEmbeddedImage: Bool { (freeImageFormat ?? -1) != -1 }
    /// 数据是一段视频（MP4 / ISO-BMFF）。
    ///
    /// TEXB0004 有专门的 `isVideo` 字段；TEXB0003 没有，WE 把"标志"的第 5 位当视频标记
    /// （`~/wp` 里 12 张这样的纹理：标志 34 = 2 | 32，载荷以 `ftyp` 盒开头）。两种都认，
    /// 另外再按载荷开头兜一次底：`00 00 00 xx 66 74 79 70` 就是 ISO-BMFF。
    public var isVideoTexture: Bool {
        if isVideo == true { return true }
        guard freeImageFormat ?? -1 == -1, flags & 32 != 0 else { return false }
        guard let data = images.first?.mipmaps.first?.storedData, data.count > 12 else { return false }
        return Array(data[4..<8]) == Array("ftyp".utf8)
    }

    private static let maxDimension = 16384
    private static let maxCount = 4096

    public init(data: Data) throws {
        var reader = ByteReader(data)
        fileVersion = try reader.cString(limit: 16)
        guard fileVersion.hasPrefix("TEXV") else { throw FormatError("不是 TEX 纹理：开头是 \(fileVersion)") }
        headerVersion = try reader.cString(limit: 16)
        guard headerVersion.hasPrefix("TEXI") else { throw FormatError("TEX 头部版本不认识：\(headerVersion)") }

        rawFormat = try reader.int32()
        flags = try reader.int32()
        textureWidth = try reader.count(limit: Self.maxDimension, what: "纹理宽度")
        textureHeight = try reader.count(limit: Self.maxDimension, what: "纹理高度")
        imageWidth = try reader.count(limit: Self.maxDimension, what: "图像宽度")
        imageHeight = try reader.count(limit: Self.maxDimension, what: "图像高度")
        _ = try reader.uint32()

        containerVersion = try reader.cString(limit: 16)
        guard let containerNumber = Int(containerVersion.dropFirst(4)), containerVersion.hasPrefix("TEXB"),
              (1...4).contains(containerNumber)
        else { throw FormatError("TEX 图像容器版本不认识：\(containerVersion)") }

        let imageCount = try reader.count(limit: Self.maxCount, what: "图像数")
        freeImageFormat = containerNumber >= 3 ? try reader.int32() : nil
        isVideo = containerNumber >= 4 ? try reader.int32() != 0 : nil

        var images: [Image] = []
        for _ in 0..<imageCount {
            let mipmapCount = try reader.count(limit: 32, what: "mipmap 数")
            var mipmaps: [Mipmap] = []
            for _ in 0..<mipmapCount {
                let width = try reader.count(limit: Self.maxDimension, what: "mipmap 宽度")
                let height = try reader.count(limit: Self.maxDimension, what: "mipmap 高度")
                var isLZ4 = false
                var decompressedSize = 0
                if containerNumber >= 2 {
                    isLZ4 = try reader.int32() != 0
                    decompressedSize = try reader.count(limit: 1 << 30, what: "解压后大小")
                }
                let size = try reader.count(limit: reader.remaining, what: "mipmap 数据大小")
                let stored = try reader.bytes(size)
                mipmaps.append(Mipmap(
                    width: width, height: height, isLZ4Compressed: isLZ4,
                    decompressedSize: isLZ4 ? decompressedSize : size, storedData: stored))
            }
            images.append(Image(mipmaps: mipmaps))
        }
        self.images = images
        spriteSheet = try SpriteSheet.read(&reader)
        trailingByteCount = reader.remaining
    }
}

extension TexFile {
    /// 精灵图的帧信息，紧跟在图像数据之后。结构（2026-09-28 用 WE 自带的 50 多张粒子精灵图核对，
    /// 每张的字节数都和下面的结构精确吻合）：
    ///
    ///     "TEXS0002" NUL  [帧数]                    帧 × 帧数
    ///     "TEXS0003" NUL  [帧数][帧宽][帧高]（整数像素） 帧 × 帧数
    ///     帧（32 字节）：[图像编号 u32][帧时长 f32][x][y][宽][宽的 y 分量][高的 x 分量][高]（像素，f32）
    ///
    /// 帧按行排在一张图上，例如 512×128 的花瓣图是一行 5 帧、每帧 102.5×128；
    /// 帧时长是 1 / 帧数（整段动画按 1 秒计）。
    public struct SpriteSheet: Sendable, Equatable {
        public struct Frame: Sendable, Equatable {
            public let imageIndex: Int
            public let duration: Float
            public let x: Float
            public let y: Float
            public let width: Float
            public let height: Float
        }

        public let frames: [Frame]

        static func read(_ reader: inout ByteReader) throws -> SpriteSheet? {
            guard reader.remaining >= 9, let version = try? reader.peekString(8), version.hasPrefix("TEXS") else { return nil }
            let tag = try reader.cString(limit: 16)
            guard let number = Int(tag.dropFirst(4)), (2...3).contains(number) else {
                throw FormatError("精灵图段版本不认识：\(tag)")
            }
            let count = try reader.count(limit: 4096, what: "精灵图帧数")
            if number >= 3 {
                _ = try reader.uint32()  // 帧宽、帧高（整数像素），和帧里的浮点尺寸重复
                _ = try reader.uint32()
            }
            var frames: [Frame] = []
            for _ in 0..<count {
                let imageIndex = Int(try reader.uint32())
                let duration = try reader.float32()
                let x = try reader.float32()
                let y = try reader.float32()
                let width = try reader.float32()
                _ = try reader.float32()
                _ = try reader.float32()
                let height = try reader.float32()
                frames.append(Frame(imageIndex: imageIndex, duration: duration, x: x, y: y, width: width, height: height))
            }
            return SpriteSheet(frames: frames)
        }
    }
}

enum LZ4 {
    /// 解开不带帧头的 LZ4 块数据
    static func decompressRaw(_ data: Data, decompressedSize: Int) throws -> Data {
        guard decompressedSize > 0 else { return Data() }
        guard !data.isEmpty else { throw FormatError("LZ4 数据是空的") }
        var output = Data(count: decompressedSize)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, decompressedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written == decompressedSize else {
            throw FormatError("LZ4 解压得到 \(written) 字节，应为 \(decompressedSize) 字节")
        }
        return output
    }
}
