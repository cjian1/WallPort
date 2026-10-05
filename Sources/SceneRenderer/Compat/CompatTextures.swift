import Foundation
import simd

/// 程序生成的贴图（TEX 格式）。和 WE 素材里同名贴图一样的只有**接口**：尺寸（粒子按贴图高宽比拉伸）、
/// 像素格式（R8 / RG88 在着色器里按灰度 + 透明度解释）、平铺还是钳制、精灵图的帧布局；
/// 内容是自己画的：用途一样，样子不同。噪声类按统计特性生成（`WallpaperTool tex-stats` 量均值、方差、平滑程度）
enum CompatTextures {
    static let generators: [String: @Sendable () -> Data] = utility.merging(particles) { first, _ in first }

    // MARK: - 工具贴图和渐变

    static let utility: [String: @Sendable () -> Data] = [
        "materials/util/white.tex": { solid(SIMD4(1, 1, 1, 1)) },
        "materials/util/black.tex": { solid(SIMD4(0, 0, 0, 1)) },
        // 流向图的"不流动"：两个分量都是中间值
        "materials/util/noflow.tex": { solid(SIMD4(127.0 / 255, 127.0 / 255, 0, 1)) },
        // 四个通道各自独立的均匀白噪声（均值 0.5、标准差 1/√12），天然可以平铺
        "materials/util/noise.tex": {
            var random = CompatRandom(seed: 0x6E6F_6973)
            let pixels = (0..<256 * 256).map { _ in
                SIMD4<Float>(random.unit(), random.unit(), random.unit(), random.unit())
            }
            return CompatTexWriter(width: 256, height: 256, format: .rgba).write(pixels)
        },
        // 灰度分形噪声，可以无缝平铺；均值约 0.5、标准差约 0.2
        "materials/util/clouds_256.tex": {
            let shaped = noiseImage(seed: 0x636C_6F75, period: 4, octaves: 6, mean: 0.5, deviation: 0.2)
            return CompatTexWriter(width: 256, height: 256, format: .rgba).write(shaped.map { SIMD4($0, $0, $0, 1) })
        },
        // 四个独立的平滑噪声通道（Perlin 式），均值 0.4–0.55、标准差约 0.1
        "materials/util/perlin_256.tex": {
            let means: [Float] = [0.38, 0.43, 0.56, 0.44]
            var channels: [[Float]] = []
            for channel in 0..<4 {
                channels.append(noiseImage(
                    seed: 0x7065_7200 &+ UInt64(channel), period: 8, octaves: 4, mean: means[channel], deviation: 0.1))
            }
            var pixels: [SIMD4<Float>] = []
            pixels.reserveCapacity(256 * 256)
            for index in 0..<256 * 256 {
                pixels.append(SIMD4(channels[0][index], channels[1][index], channels[2][index], channels[3][index]))
            }
            return CompatTexWriter(width: 256, height: 256, format: .rgba).write(pixels)
        },
        // 64×2 的色带（钳制），着色器按横坐标取色
        "materials/gradient/gradient_iridescent.tex": {
            gradient { t in
                // 柔和的彩虹，整体偏蓝：色相转一圈，饱和度低
                let hue = t * 0.85 + 0.45
                let rgb = CompatColor.hsv(hue, 0.35, 1)
                return SIMD4(rgb, 1)
            }
        },
        "materials/gradient/gradient_ice.tex": {
            gradient { t in SIMD4(simd_mix(SIMD3<Float>(0.42, 0.74, 1), SIMD3<Float>(0.82, 0.92, 1), SIMD3(repeating: t)), 1) }
        },
        "materials/gradient/gradient_ferro_fluid.tex": {
            // 几乎全黑，靠近一端有一道金属高光
            gradient { t in
                let highlight = exp(-pow((t - 0.9) / 0.06, 2))
                return SIMD4(SIMD3(0.02, 0.02, 0.03) + SIMD3(0.95, 0.93, 1) * highlight, 1)
            }
        },
    ]

    /// 256×256 的可平铺分形噪声，调成给定的均值和标准差
    static func noiseImage(seed: UInt64, period: Int, octaves: Int, mean: Float, deviation: Float) -> [Float] {
        let noise = CompatNoise(seed: seed)
        var raw: [Float] = []
        raw.reserveCapacity(256 * 256)
        for y in 0..<256 {
            for x in 0..<256 {
                raw.append(noise.fbm(x: Float(x) / 256, y: Float(y) / 256, period: period, octaves: octaves))
            }
        }
        return CompatNoise.normalize(raw, mean: mean, deviation: deviation)
    }

    static func solid(_ color: SIMD4<Float>) -> Data {
        CompatTexWriter(width: 32, height: 32, format: .rgba).write(Array(repeating: color, count: 32 * 32))
    }

    static func gradient(_ color: (Float) -> SIMD4<Float>) -> Data {
        let row = (0..<64).map { color(Float($0) / 63) }
        return CompatTexWriter(width: 64, height: 2, format: .rgba, clamps: true).write(row + row)
    }

    /// 粒子贴图在 CompatParticleTextures.swift
    static var particles: [String: @Sendable () -> Data] { CompatParticleTextures.generators }
}

// MARK: - 写 TEX

/// 按 TEX 的结构（TexFile 的注释）写出不压缩的原始像素，带完整的 mipmap 链和可选的精灵图帧信息
struct CompatTexWriter {
    enum Format: Int32 {
        /// 4 通道
        case rgba = 0
        /// 2 通道：着色器里当成（灰度、透明度）
        case rg88 = 8
        /// 1 通道：着色器里当成透明度（颜色是白的）
        case r8 = 9

        var channels: Int {
            switch self {
            case .rgba: 4
            case .rg88: 2
            case .r8: 1
            }
        }
    }

    struct Frame {
        let x: Float, y: Float, width: Float, height: Float
    }

    let width: Int
    let height: Int
    let format: Format
    /// TEX 标志第 1 位：钳制纹理坐标（粒子、渐变）；不设时平铺（噪声）
    var clamps = false
    var frames: [Frame] = []

    /// 像素按行从上到下；rgba 用四个分量，rg88 用 (x = 灰度, w = 透明度)，r8 用 w（透明度）
    func write(_ pixels: [SIMD4<Float>]) -> Data {
        var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
        func i32(_ value: Int32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func f32(_ value: Float) { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        i32(format.rawValue)
        i32((clamps ? 2 : 0) | (frames.isEmpty ? 0 : 4))
        i32(Int32(width)); i32(Int32(height)); i32(Int32(width)); i32(Int32(height)); i32(0)
        data += Data("TEXB0003".utf8) + Data([0])
        i32(1)
        i32(-1)
        let levels = mipmaps(pixels)
        i32(Int32(levels.count))
        for level in levels {
            let bytes = encode(level.pixels)
            i32(Int32(level.width)); i32(Int32(level.height))
            i32(0); i32(Int32(bytes.count))
            i32(Int32(bytes.count))
            data += bytes
        }
        if !frames.isEmpty {
            data += Data("TEXS0003".utf8) + Data([0])
            i32(Int32(frames.count)); i32(Int32(frames[0].width.rounded(.down))); i32(Int32(frames[0].height.rounded(.down)))
            for frame in frames {
                i32(0); f32(1 / Float(frames.count))
                f32(frame.x); f32(frame.y); f32(frame.width); f32(0); f32(0); f32(frame.height)
            }
        }
        return data
    }

    private func encode(_ pixels: [SIMD4<Float>]) -> Data {
        func byte(_ value: Float) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(pixels.count * format.channels)
        for pixel in pixels {
            switch format {
            case .rgba: bytes += [byte(pixel.x), byte(pixel.y), byte(pixel.z), byte(pixel.w)]
            case .rg88: bytes += [byte(pixel.x), byte(pixel.w)]
            case .r8: bytes.append(byte(pixel.w))
            }
        }
        return Data(bytes)
    }

    /// 2×2 平均逐层缩小到 1×1
    private func mipmaps(_ pixels: [SIMD4<Float>]) -> [(width: Int, height: Int, pixels: [SIMD4<Float>])] {
        var levels = [(width, height, pixels)]
        while let (w, h, current) = levels.last, w > 1 || h > 1 {
            let (nw, nh) = (max(1, w / 2), max(1, h / 2))
            var next = [SIMD4<Float>](repeating: .zero, count: nw * nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    let (x0, y0) = (min(x * 2, w - 1), min(y * 2, h - 1))
                    let (x1, y1) = (min(x * 2 + 1, w - 1), min(y * 2 + 1, h - 1))
                    next[y * nw + x] = (current[y0 * w + x0] + current[y0 * w + x1] + current[y1 * w + x0] + current[y1 * w + x1]) * 0.25
                }
            }
            levels.append((nw, nh, next))
        }
        return levels.map { (width: $0.0, height: $0.1, pixels: $0.2) }
    }
}

// MARK: - 随机数、噪声、颜色

/// 可重复的伪随机数（同一个种子每次生成一样的贴图）
struct CompatRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0–1
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }

    mutating func range(_ low: Float, _ high: Float) -> Float { low + (high - low) * unit() }
}

/// 可平铺的梯度噪声（Perlin 式）和它的分形叠加
struct CompatNoise {
    let seed: UInt64

    private func hash(_ x: Int, _ y: Int) -> UInt64 {
        var h = seed &+ UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h = (h ^ (h >> 31)) &* 0xBF58_476D_1CE4_E5B9
        return h ^ (h >> 29)
    }

    private func gradient(_ x: Int, _ y: Int) -> SIMD2<Float> {
        let angle = Float(hash(x, y) >> 40) / Float(1 << 24) * 2 * .pi
        return SIMD2(cos(angle), sin(angle))
    }

    /// 单层梯度噪声，约 −0.7…0.7；坐标按 period 取模，整数周期上可以无缝平铺
    func perlin(x: Float, y: Float, period: Int) -> Float {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        let fx = x - Float(xi), fy = y - Float(yi)
        func wrap(_ v: Int) -> Int { ((v % period) + period) % period }
        func corner(_ dx: Int, _ dy: Int) -> Float {
            simd_dot(gradient(wrap(xi + dx), wrap(yi + dy)), SIMD2(fx - Float(dx), fy - Float(dy)))
        }
        let u = fx * fx * fx * (fx * (fx * 6 - 15) + 10), v = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
        return simd_mix(simd_mix(corner(0, 0), corner(1, 0), u), simd_mix(corner(0, 1), corner(1, 1), u), v)
    }

    /// 分形叠加：x、y 是 0–1 的贴图坐标，period 是最低一层每个方向的格数
    func fbm(x: Float, y: Float, period: Int, octaves: Int, persistence: Float = 0.5) -> Float {
        var total: Float = 0, amplitude: Float = 1, cells = period
        for _ in 0..<octaves {
            total += perlin(x: x * Float(cells), y: y * Float(cells), period: cells) * amplitude
            amplitude *= persistence
            cells *= 2
        }
        return total
    }

    /// 线性变换到给定的均值和标准差（再截到 0–1）
    static func normalize(_ values: [Float], mean: Float, deviation: Float) -> [Float] {
        let count = Float(values.count)
        let average = values.reduce(0, +) / count
        let spread = max((values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / count).squareRoot(), 1e-6)
        return values.map { min(max(($0 - average) / spread * deviation + mean, 0), 1) }
    }
}

enum CompatColor {
    /// 色相按圈数（0–1 一圈）
    static func hsv(_ hue: Float, _ saturation: Float, _ value: Float) -> SIMD3<Float> {
        let h = (hue - hue.rounded(.down)) * 6
        let k = SIMD3<Float>(5, 3, 1).map { n -> Float in
            let t = (n + h).truncatingRemainder(dividingBy: 6)
            return value - value * saturation * max(0, min(min(t, 4 - t), 1))
        }
        return k
    }
}

private extension SIMD3 where Scalar == Float {
    func map(_ transform: (Float) -> Float) -> SIMD3<Float> { SIMD3(transform(x), transform(y), transform(z)) }
}
