import Metal
import WallpaperFormats
import simd

/// 缩小后的亮度图（每个像素是原画面 `MotionProbe.downscale` × `downscale` 的平均亮度，0–255）
public struct LumaFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// 量画面动得多快，给自动帧率用（见 `AdaptiveFrameRate`、`SceneContent`）。
///
/// 隔 0.1 秒左右取两帧屏幕画面，在 GPU 上缩到 1/4 并转成亮度，读回来在 CPU 上分块找位移（`MotionEstimator`）。
/// 一次只多一遍很小的缩图和两次几百 KB 的读回，隔几秒才量一次
public final class MotionProbe: @unchecked Sendable {
    public static let downscale = 4
    private let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState

    public init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "luma_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "luma_fragment")
        descriptor.colorAttachments[0].pixelFormat = .r8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw FormatError("无法创建采样器")
        }
        self.sampler = sampler
    }

    /// 在命令缓冲里把 `source`（要能被着色器读）缩成亮度图；命令缓冲执行完后在 Metal 的回调线程上交出结果
    public func capture(
        _ source: any MTLTexture, into commandBuffer: any MTLCommandBuffer,
        completion: @escaping @Sendable (LumaFrame) -> Void
    ) {
        let width = max(1, source.width / Self.downscale), height = max(1, source.height / Self.downscale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // 执行完之后只有这里还读它，没有别人在写
        nonisolated(unsafe) let readback = target
        commandBuffer.addCompletedHandler { _ in
            var pixels = [UInt8](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes {
                readback.getBytes(
                    $0.baseAddress!, bytesPerRow: width, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            completion(LumaFrame(width: width, height: height, pixels: pixels))
        }
    }

    /// 每个输出像素取原图 4×4 的平均：4 次线性插值取样，各落在一个 2×2 的正中（四个像素的公共角上）
    private static let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct LumaVertex { float4 position [[position]]; float2 uv; };
        vertex LumaVertex luma_vertex(uint index [[vertex_id]]) {
            float2 corner = float2(index & 1, index >> 1);
            LumaVertex out;
            out.position = float4(corner.x * 2 - 1, 1 - corner.y * 2, 0, 1);
            out.uv = corner;
            return out;
        }
        fragment float luma_fragment(
            LumaVertex in [[stage_in]], texture2d<float> image [[texture(0)]], sampler imageSampler [[sampler(0)]]) {
            float2 texel = 1.0 / float2(image.get_width(), image.get_height());
            float3 sum = 0;
            for (int y = -1; y <= 1; y += 2) {
                for (int x = -1; x <= 1; x += 2) {
                    sum += image.sample(imageSampler, in.uv + float2(x, y) * texel).rgb;
                }
            }
            return dot(sum * 0.25, float3(0.299, 0.587, 0.114));
        }
        """
}

/// 两帧亮度图之间，画面里变得最快的那部分有多快。
///
/// 分块（8×8，相当于原画面 32×32），变化很小的块不管，变了的块分三种：
/// - 整块挪动：在 ±6 格里找最像的位置（绝对差之和最小，抛物线插值到小数格），挪过去以后差别剩不到一半；
/// - 形状在变（光影、噪声、粒子）：找不到这样的位移，按"亮度变化 ÷ 亮度梯度"估等效速度（光流的法向分量）；
/// - 没有纹理、只有明暗在变（淡入淡出、闪烁）：只算每个像素变了几级。
/// 各取靠前的值：去掉最快的 3%，免得个别错配把帧率抬上去
public enum MotionEstimator {
    public struct Result: Equatable, Sendable {
        /// 挪动、变形得快的那部分的速度（原画面像素 / 秒）
        public var speed: Double
        /// 明暗变得快的那部分（亮度级 / 秒，满 255）
        public var fadeRate: Double
        public var movingBlocks: Int
        public var warpingBlocks: Int
        public var fadingBlocks: Int
        public var totalBlocks: Int
    }

    /// 一个块的判断（也给诊断图用）
    public struct Block: Sendable {
        public enum Kind: Sendable { case still, moving, warping, fading }
        /// 块在亮度图里的左上角
        public var x: Int
        public var y: Int
        public var kind: Kind
        /// 挪动 / 等效的速度（亮度图的格，两帧之间）
        public var shift: Double
        /// 平均每个像素变了几级（两帧之间）
        public var change: Double
        /// 位移顶到了搜索范围（实际更快）
        public var atEdge: Bool
    }

    public static let block = 8
    static let searchRadius = 6

    public static func measure(from earlier: LumaFrame, to later: LumaFrame, interval: Double) -> Result? {
        guard interval > 0, let blocks = blocks(from: earlier, to: later) else { return nil }
        var speeds: [Double] = [], fades: [Double] = []
        var moving = 0, warping = 0
        for block in blocks {
            switch block.kind {
            case .still: continue
            case .moving: moving += 1
            case .warping: warping += 1
            case .fading:
                fades.append(block.change / interval)
                continue
            }
            speeds.append(block.shift * Double(MotionProbe.downscale) / interval)
        }
        /// 从大到小去掉最快的 3% 之后的最大值
        func top(_ values: [Double]) -> Double {
            let sorted = values.sorted(by: >)
            return sorted.isEmpty ? 0 : sorted[min(sorted.count * 3 / 100, sorted.count - 1)]
        }
        return Result(
            speed: top(speeds), fadeRate: top(fades), movingBlocks: moving, warpingBlocks: warping,
            fadingBlocks: fades.count, totalBlocks: blocks.count)
    }

    /// 逐块判断
    public static func blocks(from earlier: LumaFrame, to later: LumaFrame) -> [Block]? {
        guard earlier.width == later.width, earlier.height == later.height else { return nil }
        let width = later.width, height = later.height
        let radius = searchRadius, size = block
        let columns = (width - 2 * radius) / size, rows = (height - 2 * radius) / size
        guard columns > 0, rows > 0 else { return nil }
        var result: [Block] = []
        result.reserveCapacity(columns * rows)
        earlier.pixels.withUnsafeBufferPointer { a in
            later.pixels.withUnsafeBufferPointer { b in
                /// 后一帧 (x0, y0) 起的块和前一帧挪开 (dx, dy) 的块的绝对差之和
                func difference(_ x0: Int, _ y0: Int, _ dx: Int, _ dy: Int) -> Int {
                    var sum = 0
                    for y in 0..<size {
                        let rowB = (y0 + y) * width + x0, rowA = (y0 + y - dy) * width + x0 - dx
                        for x in 0..<size { sum += abs(Int(b[rowB + x]) - Int(a[rowA + x])) }
                    }
                    return sum
                }
                /// 两帧平均的亮度梯度大小（中心差分），块内求和
                func gradient(_ x0: Int, _ y0: Int) -> Double {
                    var sum = 0.0
                    for y in y0..<(y0 + size) {
                        for x in x0..<(x0 + size) {
                            let i = y * width + x
                            let gx = Double(Int(a[i + 1]) - Int(a[i - 1]) + Int(b[i + 1]) - Int(b[i - 1])) / 4
                            let gy = Double(Int(a[i + width]) - Int(a[i - width]) + Int(b[i + width]) - Int(b[i - width])) / 4
                            sum += (gx * gx + gy * gy).squareRoot()
                        }
                    }
                    return sum
                }
                let pixels = Double(size * size)
                var scores = [Int](repeating: 0, count: (2 * radius + 1) * (2 * radius + 1))
                for row in 0..<rows {
                    for column in 0..<columns {
                        let x0 = radius + column * size, y0 = radius + row * size
                        var block = Block(x: x0, y: y0, kind: .still, shift: 0, change: 0, atEdge: false)
                        defer { result.append(block) }
                        let still = difference(x0, y0, 0, 0)
                        block.change = Double(still) / pixels
                        // 平均每个像素差不到 3 级：没怎么变
                        guard still > 3 * size * size else { continue }
                        var best = still, bestX = 0, bestY = 0
                        for dy in -radius...radius {
                            for dx in -radius...radius {
                                let score = dx == 0 && dy == 0 ? still : difference(x0, y0, dx, dy)
                                scores[(dy + radius) * (2 * radius + 1) + dx + radius] = score
                                if score < best { best = score; bestX = dx; bestY = dy }
                            }
                        }
                        if Double(best) < 0.5 * Double(still) {
                            block.kind = .moving
                            block.atEdge = abs(bestX) == radius || abs(bestY) == radius
                            func score(_ dx: Int, _ dy: Int) -> Double {
                                Double(scores[(dy + radius) * (2 * radius + 1) + dx + radius])
                            }
                            /// 抛物线插值：最小值两边的分数不一样时，真正的最小值偏向小的那边
                            func refine(_ minus: Double, _ center: Double, _ plus: Double) -> Double {
                                let curvature = minus - 2 * center + plus
                                return curvature > 0 ? max(-0.5, min(0.5, 0.5 * (minus - plus) / curvature)) : 0
                            }
                            var shiftX = Double(bestX), shiftY = Double(bestY)
                            if abs(bestX) < radius { shiftX += refine(score(bestX - 1, bestY), Double(best), score(bestX + 1, bestY)) }
                            if abs(bestY) < radius { shiftY += refine(score(bestX, bestY - 1), Double(best), score(bestX, bestY + 1)) }
                            block.shift = (shiftX * shiftX + shiftY * shiftY).squareRoot()
                            continue
                        }
                        // 找不到整块的位移：有纹理就按"亮度变化 ÷ 梯度"估等效速度，没纹理就只是明暗在变
                        let slope = gradient(x0, y0)
                        if slope / pixels < 3 {
                            block.kind = .fading
                        } else {
                            block.kind = .warping
                            block.shift = min(Double(still) / slope, Double(radius) * 2.squareRoot())
                        }
                    }
                }
            }
        }
        return result
    }
}

/// 按画面变得多快定帧率：每帧挪动不超过 `jumpPoints` 个点、明暗每帧变不超过 `fadeStep` 级就看不出卡，
/// 选够用的最低一档（不超过上限）
public enum AdaptiveFrameRate {
    /// 候选帧率
    static let ladder = [20, 24, 30, 40, 60]
    /// 每帧允许挪动多少（点；Retina 屏上是 4 个像素）
    static let jumpPoints = 2.0
    /// 每帧允许明暗变几级（满 255）
    static let fadeStep = 8.0

    /// - Parameters:
    ///   - cap: 帧率上限（0 表示不限制）
    ///   - backingScale: 屏幕每个点几个像素
    public static func frameRate(for result: MotionEstimator.Result, backingScale: Double, cap: Int) -> Int {
        let needed = max(result.speed / (jumpPoints * max(backingScale, 1)), result.fadeRate / fadeStep)
        guard let rate = ladder.first(where: { Double($0) >= needed }) else { return cap }
        return cap == 0 ? rate : min(rate, cap)
    }
}

/// 自动帧率的节奏和防抖：开始播放后第 2、4、6 秒各量一次，之后每 10 秒量一次；帧率按最近 3 次里要求最高的定——
/// 量到变快了马上升上去，变慢了要连着 3 次都慢才降。量满 3 次之前按上限
struct FrameRateGovernor {
    static let firstProbe = 2.0
    static let earlyInterval = 2.0
    static let interval = 10.0
    static let window = 3

    /// 最近几次量出来要的帧率（0 表示比候选的最高一档还快）
    private(set) var history: [Int] = []
    /// 下一次该量的时间（场景时间，秒）
    private(set) var nextProbe: Double

    init(startingAt time: Double) {
        nextProbe = time + Self.firstProbe
    }

    func isDue(at time: Double) -> Bool { time >= nextProbe }

    /// 这次没量成（中途暂停了之类）：过一会儿再量
    mutating func postpone(from time: Double) {
        nextProbe = time + Self.earlyInterval
    }

    mutating func record(_ needed: Int, at time: Double) {
        history.append(needed)
        if history.count > Self.window { history.removeFirst() }
        nextProbe = time + (history.count < Self.window ? Self.earlyInterval : Self.interval)
    }

    /// 在上限 `cap`（0 表示不限制）之下现在该用的帧率
    func rate(cap: Int) -> Int {
        guard history.count >= Self.window else { return cap }
        let needed = history.contains(0) ? 0 : history.max()!
        if needed == 0 { return cap }
        return cap == 0 ? needed : min(needed, cap)
    }
}
