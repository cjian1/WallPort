import Foundation
import Metal
import ShaderCompiler
import ShaderTranslation
import simd
import WallpaperFormats

/// 翻译并编译好的一个 WE 着色器程序
struct CompiledProgram {
    let pipeline: any MTLRenderPipelineState
    let vertexLayout: UniformBlockLayout
    let fragmentLayout: UniformBlockLayout
    let interface: ShaderInterface
    /// 实际使用的开关取值
    let defines: [String: Int]
    /// 顶点着色器用 g_ModelViewProjectionMatrix 算位置（不是直接把 a_Position 当裁剪坐标）
    var readsModelViewProjection = true
}

/// 按"着色器 + 开关 + 有贴图的槽"缓存翻译结果。翻译一次要几十毫秒，同一场景里常有重复
final class ProgramCache {
    private let device: any MTLDevice
    private let files: SceneFiles
    private let diskCache: URL?
    private var programs: [String: Result<CompiledProgram, any Error>] = [:]

    /// 特效通道画四边形用的顶点缓冲编号，避开 uniform 块用的 0
    static let vertexBufferIndex = 30

    init(device: any MTLDevice, files: SceneFiles, diskCache: URL?) {
        self.device = device
        self.files = files
        self.diskCache = diskCache
    }

    /// 顶点数据的排列
    enum VertexFormat: String {
        /// 特效通道的四边形：位置 3f、纹理坐标 2f
        case effectQuad
        /// 粒子的四个角（见 `ParticleLayer`）：a_Position 3f、a_TexCoordVec4 4f、a_Color 4f、
        /// a_TexCoordC2 2f、a_TexCoordVec4C1 4f
        case particle
    }

    /// 固定功能的混合方式（WE 材质的 blending）
    enum Blending: String {
        case none, translucent, additive
    }

    func program(
        shader: String, combos: [String: Int], providedTextures: Set<Int>, vertexFormat: VertexFormat = .effectQuad,
        blending: Blending = .none
    ) throws -> CompiledProgram {
        let key = shader + "|" + combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            + "|" + providedTextures.sorted().map(String.init).joined(separator: ",")
            + "|" + vertexFormat.rawValue + "|" + blending.rawValue
        if let cached = programs[key] { return try cached.get() }
        let result = Result {
            try compile(
                shader: shader, combos: combos, providedTextures: providedTextures, vertexFormat: vertexFormat,
                blending: blending)
        }
        programs[key] = result
        return try result.get()
    }

    private func compile(
        shader: String, combos: [String: Int], providedTextures: Set<Int>, vertexFormat: VertexFormat, blending: Blending
    ) throws -> CompiledProgram {
        guard let vertex = files.text("shaders/\(shader).vert"), let fragment = files.text("shaders/\(shader).frag") else {
            throw FormatError("找不到着色器 \(shader)")
        }
        let translated = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: combos, providedTextures: providedTextures, include: files.text,
            cacheDirectory: diskCache)
        let vertexFunction = try device.makeLibrary(source: translated.vertexMetal, options: nil).makeFunction(name: "main0")
        let fragmentFunction = try device.makeLibrary(source: translated.fragmentMetal, options: nil).makeFunction(name: "main0")
        guard let vertexFunction, let fragmentFunction else { throw FormatError("\(shader) 翻译后找不到入口函数") }

        // 按名字对上着色器里的顶点输入
        let attributes: [String: (MTLVertexFormat, Int)]
        let stride: Int
        switch vertexFormat {
        case .effectQuad:
            attributes = ["a_Position": (.float3, 0), "a_TexCoord": (.float2, 12)]
            stride = 20
        case .particle:
            attributes = [
                "a_Position": (.float3, 0), "a_TexCoordVec4": (.float4, 12), "a_Color": (.float4, 28),
                "a_TexCoordC2": (.float2, 44), "a_TexCoordVec4C1": (.float4, 52),
            ]
            stride = ParticleLayer.floatsPerVertex * 4
        }
        let layout = MTLVertexDescriptor()
        for attribute in vertexFunction.vertexAttributes ?? [] where attribute.isActive {
            guard let (format, offset) = attributes[attribute.name] else {
                throw FormatError("\(shader) 用到了还不支持的顶点输入 \(attribute.name)")
            }
            let slot = layout.attributes[attribute.attributeIndex]!
            slot.bufferIndex = Self.vertexBufferIndex
            slot.format = format
            slot.offset = offset
        }
        layout.layouts[Self.vertexBufferIndex].stride = stride

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = layout
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = SceneRenderer.pixelFormat
        if blending != .none {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = blending == .additive ? .one : .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return CompiledProgram(
            pipeline: try device.makeRenderPipelineState(descriptor: descriptor),
            vertexLayout: translated.vertexUniforms, fragmentLayout: translated.fragmentUniforms,
            interface: translated.interface, defines: translated.defines,
            // 翻译出的 Metal 源码里，用到的 uniform 以成员访问（`.名字`）出现；只声明没用的只出现在结构体定义里。
            // 按整个名字认：只读 g_ModelViewProjectionMatrixInverse 的不算
            readsModelViewProjection: translated.vertexMetal.range(
                of: #"\.g_ModelViewProjectionMatrix\b"#, options: .regularExpression) != nil)
    }
}

/// 运行时才确定的纹理：这个特效的输入，或者它自己的某个中间缓冲
enum EffectTexture: Equatable {
    /// 上一个特效的结果（第一个特效时是图层本身）
    case previous
    /// 本特效 fbos 里的第几个缓冲
    case buffer(Int)
}

/// 特效里的一个通道：着色器、贴图、材质参数，以及读哪些纹理、画到哪里
struct EffectStep {
    let name: String
    /// nil 表示这一"通道"不是材质而是命令（目前只有 `{"command": "copy"}`：把源缓冲整块拷到目标）
    let program: CompiledProgram?
    /// 槽位 → 素材里的贴图（遮罩、噪声图等）
    let textures: [Int: LoadedTexture]
    /// 槽位 → 运行时纹理。单通道特效就是 [0: .previous]
    let bindings: [Int: EffectTexture]
    /// 需要"到这里为止的画面"（`_rt_FullFrameBuffer`）的贴图槽
    let frameBufferSlots: Set<Int>
    /// 通道的输出里已经含背景（WE 的 "Copy background"）：链的结果要当成不透明的整块来画
    let includesBackground: Bool
    /// 画到本特效的第几个中间缓冲；nil 表示画到特效的输出
    let target: Int?
    /// 不随时间变化的 uniform 都预先写好，每帧只改时间
    let vertexUniforms: UniformBuffer
    let fragmentUniforms: UniformBuffer
    /// 铺满缓冲的四边形（每个顶点：位置 xyz + 纹理坐标 uv）。画到特效输出的通道用图层像素坐标
    /// （见 `EffectChain.pixelQuad`），画到中间缓冲的用裁剪坐标
    var quad: [Float] = EffectChain.clipQuad

    /// 着色器读音频频谱（`g_AudioSpectrum16Left` 这类 uniform）
    var readsAudio: Bool {
        EffectChain.audioUniforms.contains { vertexUniforms.has($0) || fragmentUniforms.has($0) }
    }

    /// 着色器读鼠标位置
    var readsPointer: Bool {
        ["g_PointerPosition", "g_PointerPositionLast"].contains { vertexUniforms.has($0) || fragmentUniforms.has($0) }
    }
}

/// 一个特效实例：若干通道，以及 effect.json 里 fbos 声明的中间缓冲
struct ChainEffect {
    let name: String
    let steps: [EffectStep]
    let buffers: [any MTLTexture]
}

/// 一个图层的特效链：先把图层贴图拷进离屏纹理（去掉补齐边距；尺寸不超过图层在屏幕上实际占的像素），
/// 再依次经过每个特效。特效之间用两张主缓冲轮流交接：特效读 previous（当前那张），最后一个通道写另一张；
/// 多通道特效的中间结果写在它自己的缓冲里。最后的结果当作图层的贴图画到屏幕上。
final class EffectChain {
    let effects: [ChainEffect]
    /// 输入纹理。合成层每帧换成"到这里为止的画面"的拷贝
    var source: LoadedTexture
    /// 把输入画进缓冲时用的投影。特效都在图层自己的空间里算，通常是单位矩阵（输入铺满缓冲）；
    /// 文字图层用它把文字放在缓冲中间、四周留出 padding
    let inputProjection: simd_float4x4
    /// 输入四个角（左下、右下、左上、右上）在输入纹理上的采样坐标；nil 表示整张图像（按补齐比例）。
    /// 合成层用它从整帧画面里取出自己矩形覆盖的那一块
    var sourceCorners: [SIMD2<Float>]?
    /// 拷贝输入时乘上的颜色。文字、纯色图层把图层的颜色和透明度放在这里（特效之前，见 Draw.colorIntoChain）。
    /// 颜色变了（脚本改了透明度、颜色）时，只算一次的静态链也要重算一遍
    var inputColor = SIMD4<Float>(1, 1, 1, 1) {
        didSet { if inputColor != oldValue { hasEncodedStatic = false } }
    }
    /// 这一帧"到这里为止的画面"（上下翻转，和 WE 的 `_rt_FullFrameBuffer` 约定一致）。
    /// 有通道的贴图槽默认值是 `_rt_FullFrameBuffer` 时（"复制背景"的辉光/光线类特效）必须给，
    /// 否则那一槽没绑定，采样出来是黑的——图层上会糊出一块黑斑
    var screenCopy: (any MTLTexture)?

    /// 这条链要看画面（必须在轮到这一层绘制时才算，不能提前到屏幕这一遍之前）
    var needsScreenCopy: Bool {
        effects.contains { $0.steps.contains { !$0.frameBufferSlots.isEmpty } }
    }

    /// 最后一步把背景混进了结果（"复制背景"）：画这一层时要按不透明处理，否则背景会被叠两次
    var outputIncludesBackground: Bool {
        effects.last?.steps.last?.includesBackground ?? false
    }
    /// 两张主缓冲（或没有特效时的一张）。延后到绘制时才算的链子会从池子里借、用完还回去
    private var targets: [any MTLTexture]
    /// 主缓冲的尺寸（借还之后 `targets` 可能指向别的纹理，这里单独记着给诊断用）
    private let mainBufferSize: SIMD2<Int>
    /// 当前的主缓冲是不是从池子里借的
    private var borrowedFromPool = false
    /// 这条链的主缓冲交给池子管（构建完就放掉，绘制时再借）
    private(set) var isPooled = false
    private let device: any MTLDevice

    /// 特效链自己分配的缓冲占的显存（两张主缓冲 + 各特效的中间缓冲）
    var allocatedSize: Int {
        // 交给池子的链不占自己的主缓冲（那部分显存记在池子的账上）
        let main = isPooled ? 0 : targets.map(\.allocatedSize).reduce(0, +)
        return main + effects.flatMap(\.buffers).map(\.allocatedSize).reduce(0, +)
    }

    /// 静态链算完以后，另一张主缓冲（中间结果）就用不上了：换成 1×1 的占位，省一整张屏幕大小的纹理。
    /// 要重算时（颜色、透明度变了）先 `restoreSpareBuffer` 建回来
    func releaseSpareBuffer() {
        guard !isPooled, !effects.isEmpty, !spareReleased,
              let placeholder = try? Self.makeBuffer(device: device, size: SIMD2(1, 1))
        else { return }
        targets[(effects.count + 1) % 2] = placeholder
        spareReleased = true
    }

    func restoreSpareBuffer() throws {
        guard spareReleased else { return }
        targets[(effects.count + 1) % 2] = try Self.makeBuffer(device: device, size: mainBufferSize)
        spareReleased = false
    }

    private var spareReleased = false

    /// 两张主缓冲的尺寸
    var bufferSize: SIMD2<Int> { mainBufferSize }

    /// 只在这块里算（主缓冲的像素坐标）：图层内容加上特效最多挪开的距离，外面保持透明（见 `EffectRegion`）。
    /// nil 表示整块缓冲都算
    var activeRegion: MTLScissorRect?
    /// 各特效（按下标）真正会改动的范围（主缓冲像素）：外面照抄输入，里面才跑特效（见 `EffectRegion.changedRegion`）；
    /// nil 表示整块都跑特效
    var effectRegions: [MTLScissorRect?] = []
    /// 第 0 步只需要拷的范围：第一个特效只在它会改动的范围加上偏移上限里读输入；nil 表示整块都拷
    var copyRegion: MTLScissorRect?
    /// 有 `activeRegion` 时，范围外要补多宽一圈透明（像素）：下一遍在范围里取样最远取到这么远（各特效最大偏移 + 2）
    var regionGuard = 0

    /// 结果不随时间和鼠标变化、输入也是固定贴图时为 true：算一次就够，不用每帧重算。
    /// 构建时由引用了别的图层结果的地方置为 false
    var isStatic: Bool
    /// 静态链是否已经算过
    var hasEncodedStatic = false

    private static let dynamicUniforms = [
        "g_Time", "g_PointerPosition", "g_PointerPositionLast", "g_Daytime",
    ] + audioUniforms
    /// 音频律动的 uniform（WE 的 AUDIOPROCESSING 通道读它们）
    static let audioUniforms = [
        "g_AudioSpectrum16Left", "g_AudioSpectrum16Right",
        "g_AudioSpectrum32Left", "g_AudioSpectrum32Right",
        "g_AudioSpectrum64Left", "g_AudioSpectrum64Right",
    ]

    /// 链里有特效读音频频谱
    var readsAudio: Bool { effects.contains { $0.steps.contains(where: \.readsAudio) } }
    var readsPointer: Bool { effects.contains { $0.steps.contains(where: \.readsPointer) } }
    private let copyPipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private let fallback: any MTLTexture

    /// 最后一个特效画进哪张主缓冲
    var output: LoadedTexture {
        let texture = targets[effects.count % 2]
        return LoadedTexture(
            texture: texture, imageSize: SIMD2(Float(texture.width), Float(texture.height)),
            uvScale: SIMD2(1, 1), clampsUVs: true, usesNearestFiltering: false)
    }

    init(
        effects: [ChainEffect], source: LoadedTexture, size: SIMD2<Int>, device: any MTLDevice,
        copyPipeline: any MTLRenderPipelineState, fallback: any MTLTexture,
        inputProjection: simd_float4x4 = matrix_identity_float4x4
    ) throws {
        self.effects = effects
        self.source = source
        self.inputProjection = inputProjection
        isStatic = !effects.flatMap(\.steps).contains { step in
            Self.dynamicUniforms.contains { step.vertexUniforms.has($0) || step.fragmentUniforms.has($0) }
        }
        // 读画面的链每帧都要重算（画面底下几层随时在变）
        if isStatic, effects.contains(where: { $0.steps.contains { !$0.frameBufferSlots.isEmpty } }) {
            isStatic = false
        }
        self.copyPipeline = copyPipeline
        self.fallback = fallback
        self.device = device
        // 没有特效时只需要拷贝那一张
        // Metal 的纹理每边最多 16384，超了不是返回 nil 而是直接断言让进程退出（坏场景里尺寸可能是任何数）
        let size = size.clamped(lowerBound: SIMD2(1, 1), upperBound: SIMD2(16384, 16384))
        mainBufferSize = size
        targets = try (0..<(effects.isEmpty ? 1 : 2)).map { _ in try Self.makeBuffer(device: device, size: size) }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { throw FormatError("无法创建采样器") }
        self.sampler = sampler
    }

    /// 主缓冲的数量：没有特效时一张（拷贝用），有特效时两张轮流交接
    private var targetCount: Int { effects.isEmpty ? 1 : 2 }

    /// 改成由池子管主缓冲：把自己占着的放掉（换成 1×1 的占位），绘制前再借。
    /// 只给"延后到绘制时才算、而且不被别的特效引用、也不是静态"的链用
    func prepareForPooling() {
        guard !isPooled else { return }
        isPooled = true
        targets = (0..<targetCount).compactMap { _ in try? Self.makeBuffer(device: device, size: SIMD2(1, 1)) }
    }

    /// 从池子里借主缓冲（尺寸和自己的一样）。
    /// - Returns: 能不能用：自己的缓冲随时能用；交给池子的链要借够才算数（借不到时返回 false，
    ///   调用方这一帧别画这层，免得拿 1×1 占位缓冲画出花屏）
    @discardableResult
    func borrowBuffers(from pool: EffectBufferPool) -> Bool {
        guard isPooled else { return true }
        guard !borrowedFromPool else { return true }
        let textures = pool.borrow(count: targetCount, size: mainBufferSize)
        guard textures.count == targetCount else {
            pool.give(textures)
            return false
        }
        targets = textures
        borrowedFromPool = true
        return true
    }

    /// 用完把主缓冲还回池子。只有"延后到绘制时才算、而且不被别的特效引用"的链会走这条路
    func releaseBuffers(to pool: EffectBufferPool) {
        guard borrowedFromPool else { return }
        pool.give(targets)
        borrowedFromPool = false
    }

    static func bufferDescriptor(size: SIMD2<Int>) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: SceneRenderer.pixelFormat, width: max(1, size.x), height: max(1, size.y), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return descriptor
    }

    static func makeBuffer(device: any MTLDevice, size: SIMD2<Int>) throws -> any MTLTexture {
        guard let texture = device.makeTexture(descriptor: bufferDescriptor(size: size)) else {
            throw FormatError("无法创建 \(size.x)×\(size.y) 的特效缓冲")
        }
        return texture
    }

    /// 裁剪空间的整张四边形；左上角 (-1, 1) 对应纹理坐标 (0, 0)
    static let clipQuad: [Float] = [
        -1, -1, 0, 0, 1,
        1, -1, 0, 1, 1,
        -1, 1, 0, 0, 0,
        1, 1, 0, 1, 0,
    ]

    /// 以图层像素为单位的整张四边形：中心是原点、y 朝上，左上角 (−宽/2, 高/2) 对应纹理坐标 (0, 0)。
    /// WE 画到特效输出的通道就是这样的四边形，再乘 g_ModelViewProjectionMatrix 变成裁剪坐标；
    /// 顶点模式的特效（植物摇摆、倾斜、透视的 Vertex 模式）按像素挪顶点
    static func pixelQuad(size: SIMD2<Float>) -> [Float] {
        let half = size / 2
        return [
            -half.x, -half.y, 0, 0, 1,
            half.x, -half.y, 0, 1, 1,
            -half.x, half.y, 0, 0, 0,
            half.x, half.y, 0, 1, 0,
        ]
    }

    /// - Parameters:
    ///   - pointer: 鼠标在屏幕上的位置，0–1，原点在左上角（WE 的着色器自己再翻转 y）
    ///   - audio: 系统音频的 16/32/64 段频谱；跟着音乐律动的通道（WE 的 AUDIOPROCESSING）读它
    func encode(
        into commandBuffer: any MTLCommandBuffer, time: Float, pointer: SIMD2<Float>,
        audio: (left: [Float], right: [Float])? = nil
    ) {
        let whole = MTLScissorRect(x: 0, y: 0, width: mainBufferSize.x, height: mainBufferSize.y)
        let outer = activeRegion ?? whole
        // 只写一部分的遍不整块清空（见 `encodePass`）：只在范围里算的链，除了最后一遍（屏幕上要读它的结果）；
        // 第 0 步只拷第一个特效要读的那一块时也一样（外面在第一个特效之后才会被整块重写）
        let lastIndex = effects.count - 1
        let limitsStores = activeRegion != nil
        // 第 0 步：拷贝图层贴图，按补齐比例只取有效部分（合成层按给定的四个角取）。
        // 第一个特效只在它的遮罩范围里读输入时，只拷那一块
        let copiesAll = effects.isEmpty || (copyRegion == nil && !limitsStores)
        encodePass(commandBuffer, target: targets[0], clearsWhole: copiesAll) { encoder in
            if let region = copyRegion {
                guard let inside = Self.intersection(region, outer) else { return }
                encoder.setScissorRect(inside)
            }
            drawSource(encoder)
        }

        for (index, effect) in effects.enumerated() {
            let previous = targets[index % 2]
            let output = targets[(index + 1) % 2]
            for (stepIndex, step) in effect.steps.enumerated() {
                let target = step.target.map { effect.buffers[$0] } ?? output
                let isLast = index == lastIndex && stepIndex == effect.steps.count - 1
                encodePass(commandBuffer, target: target, clearsWhole: isLast || !limitsStores) { encoder in
                    guard let program = step.program else {
                        // 命令通道：把绑定的源缓冲整块拷到 target
                        let source: any MTLTexture
                        switch step.bindings[0] {
                        case .previous: source = previous
                        case .buffer(let buffer): source = effect.buffers[buffer]
                        case nil: source = fallback
                        }
                        drawCopy(encoder, from: source)
                        return
                    }
                    // 这个特效只在遮罩范围里改东西：外面照抄输入（第一个特效直接从图层贴图拷，和第 0 步画法一样），
                    // 里面才跑特效的着色器
                    if index < effectRegions.count, let region = effectRegions[index], effect.steps.count == 1,
                       step.target == nil {
                        for strip in Self.strips(around: region, within: outer) {
                            encoder.setScissorRect(strip)
                            if index == 0 { drawSource(encoder) } else { drawCopy(encoder, from: previous) }
                        }
                        guard let inside = Self.intersection(region, outer) else { return }
                        encoder.setScissorRect(inside)
                    }
                    drawStep(
                        step, program: program, effect: effect, previous: previous, encoder: encoder, time: time,
                        pointer: pointer, audio: audio)
                }
            }
        }
    }

    /// 第 0 步的画法：图层贴图按补齐比例（或给定的四个角）画满缓冲
    private func drawSource(_ encoder: any MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(copyPipeline)
        let uv = source.uvScale
        let corners = sourceCorners ?? [SIMD2(0, uv.y), SIMD2(uv.x, uv.y), SIMD2(0, 0), SIMD2(uv.x, 0)]
        let vertices: [SIMD4<Float>] = [
            SIMD4(-1, -1, corners[0].x, corners[0].y), SIMD4(1, -1, corners[1].x, corners[1].y),
            SIMD4(-1, 1, corners[2].x, corners[2].y), SIMD4(1, 1, corners[3].x, corners[3].y),
        ]
        var uniforms = LayerUniformValues(projection: inputProjection, color: inputColor, mode: .zero)
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniformValues>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniformValues>.stride, index: 1)
        encoder.setFragmentTexture(source.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 把一张缓冲原样画满目标（命令通道的"拷贝"，也是遮罩外"照抄输入"的画法）；颜色乘 0 时画成透明黑
    private func drawCopy(
        _ encoder: any MTLRenderCommandEncoder, from source: any MTLTexture, color: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    ) {
        encoder.setRenderPipelineState(copyPipeline)
        let vertices: [SIMD4<Float>] = [
            SIMD4(-1, -1, 0, 1), SIMD4(1, -1, 1, 1), SIMD4(-1, 1, 0, 0), SIMD4(1, 1, 1, 0),
        ]
        var uniforms = LayerUniformValues(projection: matrix_identity_float4x4, color: color, mode: .zero)
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniformValues>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniformValues>.stride, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 跑一个特效通道的着色器
    private func drawStep(
        _ step: EffectStep, program: CompiledProgram, effect: ChainEffect, previous: any MTLTexture,
        encoder: any MTLRenderCommandEncoder, time: Float, pointer: SIMD2<Float>,
        audio: (left: [Float], right: [Float])?
    ) {
        encoder.setRenderPipelineState(program.pipeline)
        var vertexUniforms = step.vertexUniforms
        var fragmentUniforms = step.fragmentUniforms
        vertexUniforms.set("g_Time", [time])
        fragmentUniforms.set("g_Time", [time])
        vertexUniforms.set("g_PointerPosition", [pointer.x, pointer.y])
        fragmentUniforms.set("g_PointerPosition", [pointer.x, pointer.y])
        if let audio {
            for size in [16, 32, 64] {
                let bands = Self.bandCount(audio, size)
                vertexUniforms.set("g_AudioSpectrum\(size)Left", bands.left)
                vertexUniforms.set("g_AudioSpectrum\(size)Right", bands.right)
                fragmentUniforms.set("g_AudioSpectrum\(size)Left", bands.left)
                fragmentUniforms.set("g_AudioSpectrum\(size)Right", bands.right)
            }
        }
        step.quad.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: ProgramCache.vertexBufferIndex)
        }
        encoder.setVertexBytes(vertexUniforms.bytes, length: vertexUniforms.bytes.count, index: 0)
        encoder.setFragmentBytes(fragmentUniforms.bytes, length: fragmentUniforms.bytes.count, index: 0)
        // g_TextureN 绑定在 N + 1；运行时纹理优先，其次素材贴图，都没有就绑一张 1×1 的黑色纹理
        var slots = Set(program.interface.textures.map(\.index))
        slots.formUnion(step.bindings.keys)
        for slot in slots {
            let texture: any MTLTexture
            if step.bindings[slot] == nil, step.frameBufferSlots.contains(slot), let screenCopy {
                texture = screenCopy
            } else {
                switch step.bindings[slot] {
                case .previous: texture = previous
                case .buffer(let buffer): texture = effect.buffers[buffer]
                case nil: texture = step.textures[slot]?.texture ?? fallback
                }
            }
            encoder.setFragmentTexture(texture, index: slot + 1)
            encoder.setFragmentSamplerState(sampler, index: slot + 1)
            encoder.setVertexTexture(texture, index: slot + 1)
            encoder.setVertexSamplerState(sampler, index: slot + 1)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 两个矩形的交集；不相交时为 nil
    static func intersection(_ a: MTLScissorRect, _ b: MTLScissorRect) -> MTLScissorRect? {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `outer` 里去掉 `inner` 剩下的部分，拆成最多 4 个矩形（上、下两条整宽，中间左、右两块）
    static func strips(around inner: MTLScissorRect, within outer: MTLScissorRect) -> [MTLScissorRect] {
        guard let middle = intersection(inner, outer) else { return [outer] }
        var result: [MTLScissorRect] = []
        if middle.y > outer.y {
            result.append(MTLScissorRect(x: outer.x, y: outer.y, width: outer.width, height: middle.y - outer.y))
        }
        let outerBottom = outer.y + outer.height, middleBottom = middle.y + middle.height
        if outerBottom > middleBottom {
            result.append(MTLScissorRect(x: outer.x, y: middleBottom, width: outer.width, height: outerBottom - middleBottom))
        }
        if middle.x > outer.x {
            result.append(MTLScissorRect(x: outer.x, y: middle.y, width: middle.x - outer.x, height: middle.height))
        }
        let outerRight = outer.x + outer.width, middleRight = middle.x + middle.width
        if outerRight > middleRight {
            result.append(MTLScissorRect(x: middleRight, y: middle.y, width: outerRight - middleRight, height: middle.height))
        }
        return result
    }

    /// 音频频谱降/升采样到 WE 的 16 / 32 / 64 段（`g_AudioSpectrum16Left[16]` 这类 uniform）
    private static func bandCount(
        _ audio: (left: [Float], right: [Float]), _ count: Int
    ) -> (left: [Float], right: [Float]) {
        func resample(_ values: [Float]) -> [Float] {
            guard values.count != count, !values.isEmpty else { return values }
            return (0..<count).map { index in
                let start = index * values.count / count
                let end = max(start + 1, (index + 1) * values.count / count)
                return values[start..<min(end, values.count)].reduce(0, +) / Float(max(1, end - start))
            }
        }
        return (resample(audio.left), resample(audio.right))
    }

    /// 一遍渲染。`clearsWhole` 为 false 时不整块清空：Apple GPU 上"清空"会把每一块（tile）都写回显存，
    /// 哪怕裁剪矩形只画了一小块；不清空时没画到的块直接跳过，但里面留着以前的内容（缓冲是池子里轮着用的），
    /// 所以只能用在"没画到的地方不会被读到"的遍上。只在范围里算的链（`activeRegion`）另外在范围外补一圈透明
    /// （`regionGuard`）：下一遍在范围里取样最远取到这一圈，读到的和整块清空时一样是透明黑
    private func encodePass(
        _ commandBuffer: any MTLCommandBuffer, target: any MTLTexture, clearsWhole: Bool = true,
        body: (any MTLRenderCommandEncoder) -> Void
    ) {
        let partial = !clearsWhole && target.width == mainBufferSize.x && target.height == mainBufferSize.y
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = partial ? .dontCare : .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let region = activeRegion {
            let scaled = Self.scaled(region, from: mainBufferSize, to: target)
            if partial {
                let guardBand = MTLScissorRect(
                    x: max(0, scaled.x - regionGuard), y: max(0, scaled.y - regionGuard),
                    width: min(target.width, scaled.x + scaled.width + regionGuard) - max(0, scaled.x - regionGuard),
                    height: min(target.height, scaled.y + scaled.height + regionGuard) - max(0, scaled.y - regionGuard))
                for strip in Self.strips(around: scaled, within: guardBand) {
                    encoder.setScissorRect(strip)
                    drawCopy(encoder, from: fallback, color: .zero)
                }
            }
            encoder.setScissorRect(scaled)
        }
        body(encoder)
        encoder.endEncoding()
    }
}

extension EffectChain {
    /// 主缓冲上的裁剪矩形换算到另一张缓冲（特效自己的中间缓冲按比例缩小过）上，并夹在它的范围里
    static func scaled(_ region: MTLScissorRect, from size: SIMD2<Int>, to target: any MTLTexture) -> MTLScissorRect {
        guard target.width != size.x || target.height != size.y else { return region }
        let sx = Double(target.width) / Double(max(size.x, 1)), sy = Double(target.height) / Double(max(size.y, 1))
        let x0 = max(0, min(target.width - 1, Int((Double(region.x) * sx).rounded(.down))))
        let y0 = max(0, min(target.height - 1, Int((Double(region.y) * sy).rounded(.down))))
        let x1 = max(x0 + 1, min(target.width, Int((Double(region.x + region.width) * sx).rounded(.up))))
        let y1 = max(y0 + 1, min(target.height, Int((Double(region.y + region.height) * sy).rounded(.up))))
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// 和 LayerShaders 里 LayerUniforms 对应的内存布局
struct LayerUniformValues {
    var projection: simd_float4x4
    var color: SIMD4<Float>
    var mode: SIMD4<Int32>
}

/// 特效链主缓冲的池子：借的时候从一块 Metal 堆（heap）里切，还的时候标成可别名（`makeAliasable`），
/// 后面借的缓冲就能落在同一块显存上——**不管尺寸是否一样**。
///
/// 以前按尺寸分桶复用整张纹理：视差场景里每个图层的缩放差一点，缓冲就差几十像素（3527×2015、3562×2035……），
/// 谁也借不了谁的，池子等于没用（1732032524 在 4K 屏上闲着 6 种尺寸 × 2 张 = 360 MB）。现在堆只需要
/// "一帧里同时借出去最多的那几张"那么大。
///
/// 安全靠堆的依赖跟踪（`hazardTrackingMode = .tracked`）：Metal 把整个堆当成一个资源跟踪读写，后一条链写进
/// 别名的显存之前，会等前面画这一块的读（同一帧里前一条链画到屏幕上、或者上一帧还在 GPU 上跑的）做完。
/// 借还的顺序也要对：链画到屏幕上之后才还（见 SceneRenderer 里 `releaseBuffers` 的位置）。
final class EffectBufferPool: @unchecked Sendable {
    private let device: any MTLDevice
    private var heap: (any MTLHeap)?
    /// 同时借出去的缓冲最多占多大的堆（按 `heapTextureSizeAndAlign` 算，含对齐）
    private var neededHeapSize = 0
    private var borrowedBytes = 0
    private var borrowed = 0
    private(set) var peakBorrowed = 0
    private let lock = NSLock()

    init(device: any MTLDevice) {
        self.device = device
    }

    func borrow(count: Int, size: SIMD2<Int>) -> [any MTLTexture] {
        lock.lock()
        defer { lock.unlock() }
        // 堆不够大时，趁手上一张都没借出去的时候换一块够大的（旧的等用它的纹理都释放了自己会释放）
        if borrowed == 0, neededHeapSize > (heap?.size ?? 0) { heap = makeHeap(size: neededHeapSize) }
        let descriptor = EffectChain.bufferDescriptor(size: size)
        let needed = device.heapTextureSizeAndAlign(descriptor: descriptor)
        let stride = (needed.size + needed.align - 1) / needed.align * needed.align
        var result: [any MTLTexture] = []
        for _ in 0..<count {
            // 堆里放不下（第一帧还不知道要多大，或者碎了）就单独建一张，下次换堆时按需要的大小来
            guard let texture = heap?.makeTexture(descriptor: descriptor) ?? device.makeTexture(descriptor: descriptor)
            else { break }
            result.append(texture)
        }
        borrowed += result.count
        borrowedBytes += result.count * stride
        peakBorrowed = max(peakBorrowed, borrowed)
        neededHeapSize = max(neededHeapSize, borrowedBytes)
        return result
    }

    /// 还回去（也用于借的时候只拿到一部分、用不上的情况）。还回来的纹理不能再用
    func give(_ textures: [any MTLTexture]) {
        guard !textures.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for texture in textures {
            if texture.heap != nil { texture.makeAliasable() }
            let needed = device.heapTextureSizeAndAlign(descriptor: EffectChain.bufferDescriptor(
                size: SIMD2(texture.width, texture.height)))
            borrowed -= 1
            borrowedBytes -= (needed.size + needed.align - 1) / needed.align * needed.align
        }
    }

    private func makeHeap(size: Int) -> (any MTLHeap)? {
        let descriptor = MTLHeapDescriptor()
        descriptor.size = size
        descriptor.storageMode = .private
        descriptor.type = .automatic
        descriptor.hazardTrackingMode = .tracked
        return device.makeHeap(descriptor: descriptor)
    }

    /// 堆占的显存（诊断用）
    var heapBytes: Int {
        lock.withLock { heap?.size ?? 0 }
    }
}
