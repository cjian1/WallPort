import CoreGraphics
import DesktopHost
import Foundation
import Metal
import ShaderCompiler
import simd
import WallpaperFormats

/// 把一个场景画到 Metal 纹理上。M4 支持：图片图层、纯色层、分组的父子变换、可见性、透明度、颜色、
/// 材质的透明/叠加混合、29 种图层混合模式（colorBlendMode）、正交画布按"铺满裁切"适配目标尺寸。
///
/// 木偶变形图层按模型网格绘制，骨骼动画在 CPU 上蒙皮（见 `PuppetAnimator`）。
/// 粒子系统在 CPU 上模拟，用 WE 自己的 genericparticle 着色器绘制（见 `ParticleLayer`）。
/// 暂不支持的内容（文字、合成层、脚本等）不会静默丢掉，
/// 都记在 `unsupported` 里，渲染时按能做到的最接近方式处理或跳过。
///
/// 构建（读文件、解码和上传纹理）比较慢，可以在后台线程做；构建完成后状态不再改变，可以交给主线程渲染。
public final class SceneRenderer: @unchecked Sendable {
    /// 一次鼠标事件：位置 0–1、原点在左上角。点击类是"按下后很快抬起"合成出来的
    public struct PointerEvent: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case down
            case up
            case dragged
            case click
        }

        public let kind: Kind
        public let position: SIMD2<Float>

        public init(kind: Kind, position: SIMD2<Float>) {
            self.kind = kind
            self.position = position
        }
    }

    public let canvasSize: SIMD2<Float>
    /// 取景位置（壁纸设置里的"画面位置"）：画布被裁掉的方向上 0 是最左 / 最上、1 是最右 / 最下，见 `framing`
    public let focus: SIMD2<Float>
    public let clearColor: SIMD3<Float>
    /// 画布中心（画布坐标，左下原点）。固定正交场景是画布正中；`.auto` 场景是内容包围盒的中心
    private let canvasCenter: SIMD2<Float>
    /// 固定正交场景里真正有内容的框（见 `fillBox(canvas:content:)`）；内容盖满画布、或者只占一小块时为 nil
    public let fillBox: (min: SIMD2<Float>, max: SIMD2<Float>)?
    /// 投影方式（正交 / 透视），见 `SceneDescription.Projection`
    private let projectionKind: SceneDescription.Projection
    /// 透视场景的顶层相机；正交场景忽略
    private let sceneCamera: SceneDescription.ViewCamera?
    private let fov: Float
    private let nearz: Float
    private let farz: Float
    /// 画出来的图层数
    public let drawnLayerCount: Int
    /// 只在图层内容附近算的特效链有几条（见 `EffectRegion`）
    public let regionLimitedChains: Int
    /// 只在遮罩范围里跑的特效有几个（见 `EffectRegion.changedRegion`）
    public let maskLimitedEffects: Int
    /// 实际渲染的特效数
    public let renderedEffectCount: Int
    /// 每个特效通道的诊断信息：着色器、开关、贴图、材质参数
    public let effectSummaries: [String]
    /// 有特效或粒子时画面随时间变化，需要持续渲染
    public var needsAnimation: Bool {
        // 延后到绘制时才算的链子不在 `chains` 里，但同样会让画面随时间变化
        !chains.isEmpty || draws.contains { $0.chain != nil } || !particleLayers.isEmpty
            || hasPuppetAnimation || hasDynamicText || hasScriptedAnimation
            || camera != nil || hasMaterialAnimation || draws.contains { $0.sprite != nil }
    }
    /// 有材质着色器用了 g_Time（旗帜的飘动就是这样）：画面随时间变，要持续渲染
    private let hasMaterialAnimation: Bool
    private let hasPuppetAnimation: Bool
    /// 有带脚本的文字（时钟）时为 true：文字会随时间变
    private let hasDynamicText: Bool
    /// 有每帧重算的属性脚本（浮动、悬浮缩放…）时为 true
    private let hasScriptedAnimation: Bool
    /// 有脚本注册了鼠标事件（悬停、点击、拖动）：只有这种场景才需要开全局鼠标监听
    public let needsPointerEvents: Bool
    /// 有特效读音频频谱、或脚本注册了 AudioBuffers：只有这种场景才需要采集系统音频
    public let usesAudio: Bool
    /// 画面跟着鼠标动（特效或材质读鼠标位置、粒子跟着鼠标、脚本处理鼠标事件）：鼠标一动就要按上限的帧率画
    public let followsPointer: Bool
    /// 2D 摄像机有动画（Lucy 的开场）
    private let camera: SceneDescription.Camera?
    /// 粒子系统的个数（含子系统）
    public let particleSystemCount: Int
    /// 当前活着的粒子数
    public var liveParticleCount: Int { particleLayers.map(\.particleCount).reduce(0, +) }
    /// 暂不支持的内容 → 出现次数
    public let unsupported: [String: Int]
    /// 显存去向（诊断用）：每行"类别 名字 尺寸 字节数"，按字节数从大到小
    public let memorySummary: [(String, Int)]
    /// 开发工具用：每从 WE 自带素材目录读到一个文件就回调一次（相对素材目录的路径）。App 里不设
    public static var assetReadObserver: ((String) -> Void)? {
        get { SceneFiles.assetReadObserver }
        set { SceneFiles.assetReadObserver = newValue }
    }
    /// 开发工具用：兼容素材怎么用（App 里不改，永远是 `.fallback`）
    public static var compatAssetMode: CompatAssetMode {
        get { SceneFiles.compatMode }
        set { SceneFiles.compatMode = newValue }
    }
    /// 开发工具用：每用到一个兼容素材回调一次（相对素材目录的路径）
    public static var compatReadObserver: ((String) -> Void)? {
        get { SceneFiles.compatReadObserver }
        set { SceneFiles.compatReadObserver = newValue }
    }
    /// 特效缓冲池的统计（诊断用）：同时最多借出去几张、池子的堆占多少字节
    public var bufferPoolStats: (peakBorrowed: Int, heapBytes: Int) {
        (bufferPool.peakBorrowed, bufferPool.heapBytes)
    }
    /// 场景里的声音对象（由 SceneContent 播放）
    public let sounds: [SceneSound]
    /// 读取失败的文件等
    public let problems: [String]

    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private var draws: [Draw]
    /// 挂在木偶骨骼上的图层（见 `AttachmentLink`）
    private var attachmentLinks: [AttachmentLink] = []
    /// 屏幕这一遍之前要算好的特效链（含只被别的特效引用的隐藏图层），按依赖顺序
    private let chains: [EffectChain]
    private let particleLayers: [ParticleLayer]
    private let frameCopy = FrameCopy()
    /// 场景泛光（general.bloom）：整帧画完后做；nil 表示没开或建不起来
    private let bloom: SceneBloom?
    /// 按下后捕获的图层：拖动时鼠标可能跑到图层外面，事件仍然送给它
    private var pointerCapture: ScriptedLayer?
    /// 运行时的图层状态：脚本（含场景对象接口）改的就是它
    private let state: SceneState
    /// 挂在没有绘制的图层上的脚本（幻灯片控制器那类），每帧要先跑
    private let controllerScripts: [ScriptedLayer]
    /// 场景对象编号 → 绘制列表下标（脚本改了绘制顺序时按它重排）
    private var drawIndexByObject: [Int: Int]
    /// 上一次绘制的时间，用来算 engine.frametime
    private var lastEncodeTime: Float?
    /// 系统音频频谱（跟着音乐律动的特效和脚本用它）；nil 表示没有音频来源
    public var audioSpectrum: SystemAudioSpectrum?
    /// 视频贴图要不要等这一刻的帧解出来。离线出图要准确的那一帧（默认）；桌面上设成 false：
    /// 只用后台已经解好的帧，渲染（主线程）从不等解码器（见 `VideoTexture`）
    public var waitsForVideoFrames = true
    /// 运行时建图层（`thisScene.createLayer`）要用的东西
    private let runtimeFiles: SceneFiles
    private let runtimeTextures: TextureLoader
    private let pipelines: [PipelineKey: any MTLRenderPipelineState]
    private let samplers: [SamplerKey: any MTLSamplerState]
    /// 贴图槽没给贴图时绑的 1×1 黑色纹理
    private let fallbackTexture: any MTLTexture
    /// 延后到绘制时才算的那些特效链借还主缓冲用的池子
    private let bufferPool: EffectBufferPool

    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private enum Blend: Hashable, CaseIterable {
        case translucent, additive, opaque
        /// 图层混合模式：着色器读出帧缓冲里已有的颜色自己算，不用固定混合单元
        case programmable
    }

    private struct PipelineKey: Hashable {
        let blend: Blend
        let textured: Bool
    }

    private struct SamplerKey: Hashable {
        let clamp: Bool
        let nearest: Bool
    }

    /// 挂在父木偶挂点上的图层：挂点在父模型坐标里 = 骨骼当前世界变换 × 挂点偏移
    struct AttachmentLink {
        let child: Int
        let parent: Int
        let bone: Int
        let offset: simd_float4x4
    }

    private struct Draw {
        let vertices: [SIMD4<Float>]  // xy：画布坐标，zw：纹理坐标
        let color: SIMD4<Float>
        let pipeline: PipelineKey
        let texture: LoadedTexture?
        let blendMode: Int32
        /// 带特效的图层：画的是特效链最后的结果，而不是原始贴图
        var chain: EffectChain? = nil
        /// 特效链只算了图层内容附近那一块时（见 `EffectRegion`）：那一块在画布上的四个角。画结果时照样画整个
        /// 四边形（逐像素和原来一样），只是用屏幕上的裁剪矩形跳过这块以外的像素；nil 时不裁
        var regionCorners: [SIMD4<Float>]? = nil
        /// 木偶网格：顶点（画布坐标 + 纹理坐标）和三角形索引放在 GPU 缓冲里，不用 vertices
        var mesh: MeshBuffers? = nil
        /// 粒子对象：自己设置管线和缓冲，上面的字段都不用
        var particles: ParticleLayer? = nil
        /// 文字图层：贴图由它按需重画（时钟的文字每秒都会变）
        var text: TextLayer? = nil
        /// 用了 WE 材质自带着色器（非 genericimage）的图层：用那个着色器画四边形，而不是固定的图层管线
        var material: MaterialDraw? = nil
        /// 合成层 / 全屏后处理层：四个角（左下、右下、左上、右上）的画布坐标。画到它时先拷一份
        /// 到这里为止的画面，从中取出这四个角围成的区域作为特效链的输入
        var composeCorners: [SIMD2<Float>]? = nil
        /// 由脚本驱动的字段（origin / scale / alpha / color / visible）
        var scripted: ScriptedLayer? = nil
        /// 精灵图动画（GIF 转来的动画图层）：每帧换成当前那一格
        var sprite: SpriteAnimation? = nil
        /// 这个绘制属于哪个场景对象（脚本按编号找图层、改属性）
        var objectID: Int = 0
        /// 颜色和透明度在特效链的**输入端**作用（文字图层、纯色图层）：绘制时不再乘一遍，
        /// 每帧把 state.color(objectID) 刷进链的输入
        var colorIntoChain = false
    }

    /// 一个用材质着色器绘制的图层：编译好的程序、各槽位的贴图、预先写好的 uniform
    private struct MaterialDraw {
        let program: CompiledProgram
        let textures: [Int: LoadedTexture]
        var vertexUniforms: UniformBuffer
        var fragmentUniforms: UniformBuffer
    }

    private struct MeshBuffers {
        let vertices: any MTLBuffer
        let indices: any MTLBuffer
        let indexCount: Int
        /// 有骨骼动画时每帧重新蒙皮，顶点缓冲由它提供
        var animator: PuppetAnimator? = nil
    }

    private struct Uniforms {
        var projection: simd_float4x4
        var color: SIMD4<Float>
        /// x 为图层混合模式编号，其余补齐
        var mode: SIMD4<Int32>
    }

    /// - Parameters:
    ///   - targetSize: 要显示到的屏幕像素尺寸。给了就按图层在屏幕上实际占的像素限制特效缓冲，
    ///     只缩小不放大；不给（离屏工具）就用图像的原尺寸
    ///   - shaderCache: 着色器翻译结果的磁盘缓存目录；nil 时每次都重新翻译
    ///   - hiddenElements: 用户在设置里关掉的粒子、文字、特效（见 `SceneElements`）
    ///   - limitsEffectsToContent: 图层特效只在图层内容附近算（见 `EffectRegion`）。关掉只用于对比；
    ///     开发工具里设环境变量 `NO_EFFECT_REGION=1` 也能关
    public init(
        device: any MTLDevice, package: ScenePackage, assets: URL?, targetSize: SIMD2<Float>? = nil,
        shaderCache: URL? = nil, userProperties: Data? = nil, hiddenElements: Set<String> = [],
        focus: SIMD2<Float> = SIMD2(0.5, 0.5),
        limitsEffectsToContent: Bool = ProcessInfo.processInfo.environment["NO_EFFECT_REGION"] == nil
    ) throws {
        self.focus = simd_clamp(focus, .zero, SIMD2(1, 1))
        let focus = self.focus
        guard let sceneData = package.contents(of: "scene.json") else { throw FormatError("包里没有 scene.json") }
        let scene = try SceneDescription(json: sceneData, userProperties: userProperties, hiddenElements: hiddenElements)
        guard let queue = device.makeCommandQueue() else { throw FormatError("无法创建 Metal 命令队列") }
        self.device = device
        self.queue = queue
        // 画布：写了宽高就用它；`auto` / 透视场景按内容包围盒（拿不到内容尺寸时退回屏幕尺寸）
        let canvas: SIMD2<Float>
        let center: SIMD2<Float>
        let fill: (min: SIMD2<Float>, max: SIMD2<Float>)?
        switch scene.projection {
        case .fixed(let size):
            canvas = size
            center = size / 2
            // 作者把画布留得比内容大时，取景按屏幕比例避开空边（见 `framing`）
            fill = Self.fillBox(canvas: size, content: scene.contentExtent)
        case .auto, .perspective:
            canvas = scene.contentExtent?.size ?? targetSize ?? SIMD2(1920, 1080)
            center = scene.contentExtent?.center ?? canvas / 2
            fill = nil
        }
        canvasSize = canvas
        canvasCenter = center
        fillBox = fill
        projectionKind = scene.projection
        sceneCamera = scene.viewCamera
        fov = scene.fov
        nearz = scene.nearz
        farz = scene.farz
        clearColor = scene.clearEnabled ? scene.clearColor : .zero

        let library = try device.makeLibrary(source: LayerShaders.source, options: nil)
        var pipelines: [PipelineKey: any MTLRenderPipelineState] = [:]
        for blend in Blend.allCases {
            for textured in [true, false] {
                let key = PipelineKey(blend: blend, textured: textured)
                pipelines[key] = try Self.makePipeline(device: device, library: library, key: key)
            }
        }
        self.pipelines = pipelines

        var samplers: [SamplerKey: any MTLSamplerState] = [:]
        for clamp in [true, false] {
            for nearest in [true, false] {
                let descriptor = MTLSamplerDescriptor()
                descriptor.minFilter = nearest ? .nearest : .linear
                descriptor.magFilter = nearest ? .nearest : .linear
                descriptor.mipFilter = .linear
                descriptor.sAddressMode = clamp ? .clampToEdge : .repeat
                descriptor.tAddressMode = clamp ? .clampToEdge : .repeat
                samplers[SamplerKey(clamp: clamp, nearest: nearest)] = device.makeSamplerState(descriptor: descriptor)
            }
        }
        self.samplers = samplers

        let files = SceneFiles(package: package, assets: assets)
        let state = SceneState(scene: scene)
        let fallbackTexture = try Self.makeFallbackTexture(device: device)
        self.fallbackTexture = fallbackTexture
        bufferPool = EffectBufferPool(device: device)
        let context = EffectContext(
            device: device, programs: ProgramCache(device: device, files: files, diskCache: shaderCache),
            copyPipeline: pipelines[PipelineKey(blend: .opaque, textured: true)]!,
            fallback: fallbackTexture,
            transparent: try Self.makeFallbackTexture(device: device, pixel: [0, 0, 0, 0]),
            white: try Self.makeFallbackTexture(device: device, pixel: [255, 255, 255, 255]))
        let textureLoader = TextureLoader(device: device, files: files)
        var builder = DrawListBuilder(
            scene: scene, files: files, textures: textureLoader, context: context,
            screenScale: targetSize.map {
                Self.framing(canvas: canvas, center: center, fill: fill, target: $0, focus: focus).scale
            },
            screenProjection: targetSize.map {
                Self.projection(
                    kind: scene.projection, canvas: canvas, center: center, fill: fill,
                    camera: scene.viewCamera, fov: scene.fov, near: scene.nearz, far: scene.farz, target: $0,
                    focus: focus)
            },
            visibleCanvasRegion: targetSize.map { target in
                guard fill != nil else {
                    return Self.visibleRegion(canvas: scene.canvasSize ?? SIMD2(1920, 1080), target: target, focus: focus)
                }
                return Self.visibleRegion(canvas: canvas, center: center, fill: fill, target: target, focus: focus)
            },
            userProperties: userProperties, state: state)
        builder.limitsEffectsToContent = limitsEffectsToContent
        let result = builder.build()
        regionLimitedChains = builder.regionLimitedChains.count
        maskLimitedEffects = builder.maskLimitedEffects.count
        runtimeFiles = files
        runtimeTextures = textureLoader
        draws = result.draws
        chains = result.chains
        attachmentLinks = builder.attachmentLinks
        particleLayers = result.draws.compactMap(\.particles)
        hasPuppetAnimation = result.draws.contains { $0.mesh?.animator != nil }
        hasMaterialAnimation = result.draws.contains { draw in
            guard let material = draw.material else { return false }
            return material.vertexUniforms.has("g_Time") || material.fragmentUniforms.has("g_Time")
        }
        hasDynamicText = result.draws.contains { $0.text?.isDynamic == true }
        // 控制器脚本（幻灯片）也要每帧跑
        controllerScripts = builder.scriptedLayers.filter { layer in
            !result.draws.contains { $0.scripted === layer }
        }
        hasScriptedAnimation = result.draws.contains { $0.scripted?.isDynamic == true }
            || controllerScripts.contains { $0.isDynamic }
        needsPointerEvents = result.draws.contains { $0.scripted?.handlesPointer == true }
        usesAudio = (result.chains + result.draws.compactMap(\.chain)).contains(where: \.readsAudio)
            || (result.draws.compactMap(\.scripted) + controllerScripts).contains(where: \.usesAudio)
        followsPointer = needsPointerEvents
            || (result.chains + result.draws.compactMap(\.chain)).contains(where: \.readsPointer)
            || result.draws.contains { draw in
                guard let material = draw.material else { return false }
                return material.vertexUniforms.has("g_PointerPosition") || material.fragmentUniforms.has("g_PointerPosition")
            }
            || result.draws.contains { $0.particles?.followsPointer == true }
        camera = scene.objects.compactMap(\.camera).first { $0.isAnimated }
        var indexByObject: [Int: Int] = [:]
        for (position, draw) in result.draws.enumerated() where indexByObject[draw.objectID] == nil {
            indexByObject[draw.objectID] = position
        }
        drawIndexByObject = indexByObject
        self.state = state
        if ProcessInfo.processInfo.environment["SHOW_STATS"] != nil {
            let staticPrefix = draws.prefix { draw in
                draw.chain == nil && draw.particles == nil && draw.mesh?.animator == nil
                    && draw.text?.isDynamic != true && draw.scripted == nil && draw.composeCorners == nil
            }.count
            print("  图层 \(draws.count) 个，最前面的静态图层 \(staticPrefix) 个")
            var steps = 0
            var freezeable = 0
            for chain in result.chains {
                let all = chain.effects.flatMap(\.steps)
                steps += all.count
                let dynamic = ["g_Time", "g_PointerPosition", "g_PointerPositionLast", "g_Daytime"]
                freezeable += all.prefix { step in
                    !dynamic.contains { step.vertexUniforms.has($0) || step.fragmentUniforms.has($0) }
                }.count
            }
            print("  特效通道 \(steps) 个，其中开头可以冻结的 \(freezeable) 个")
            let limited = builder.regionLimitedChains
            if !limited.isEmpty {
                let average = limited.reduce(0, +) / Double(limited.count) * 100
                print("  只在内容附近算的特效链 \(limited.count) 条，平均只算整块缓冲的 \(Int(average.rounded()))%")
            }
            let masked = builder.maskLimitedEffects
            if !masked.isEmpty {
                let average = masked.reduce(0, +) / Double(masked.count) * 100
                print("  只在遮罩范围里跑的特效 \(masked.count) 个，平均只跑整块缓冲的 \(Int(average.rounded()))%")
            }
            for (reason, count) in builder.regionSkipReasons.sorted(by: { $0.value > $1.value }) {
                print("  没限制的特效链：\(reason) \(count) 条")
            }
        }
        particleSystemCount = result.particleSystems
        sounds = builder.sounds
        drawnLayerCount = result.draws.count
        renderedEffectCount = result.renderedEffects
        effectSummaries = result.effectSummaries
        unsupported = result.unsupported
        var problems = result.problems
        if let settings = scene.bloom {
            do {
                bloom = try SceneBloom(device: device, programs: context.programs, settings: settings)
            } catch {
                bloom = nil
                problems.append("场景泛光：\(error.localizedDescription)")
            }
        } else {
            bloom = nil
        }
        self.problems = problems
        var memory = builder.textures.memoryUsage.map { ("贴图 \($0.0)", $0.1) }
        let composeChains = result.draws.compactMap(\.chain).filter { chain in !result.chains.contains { $0 === chain } }
        for chain in result.chains + composeChains {
            let names = chain.effects.isEmpty ? "（只拷贝）" : chain.effects.map(\.name).joined(separator: "、")
            memory.append(("特效链 \(chain.bufferSize.x)×\(chain.bufferSize.y) \(names)", chain.allocatedSize))
        }
        let textBytes = result.draws.compactMap(\.text).map(\.allocatedSize).reduce(0, +)
        if textBytes > 0 { memory.append(("文字贴图", textBytes)) }
        memorySummary = memory.sorted { $0.1 > $1.1 }
    }

    /// 贴图槽没有提供贴图时绑定的 1×1 黑色纹理；形状图层的输入用全透明的
    private static func makeFallbackTexture(device: any MTLDevice, pixel: [UInt8] = [0, 0, 0, 255]) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw FormatError("无法创建备用纹理") }
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: pixel, bytesPerRow: 4)
        return texture
    }

    // MARK: - 渲染

    /// 画到目标纹理上。画布按"铺满裁切"对齐目标：短边撑满，长边居中裁掉。
    /// - Parameters:
    ///   - time: 场景开始以来的秒数，驱动特效动画
    ///   - pointer: 鼠标在屏幕上的位置，0–1，原点在左上角
    public func encode(
        into target: any MTLTexture, commandBuffer: any MTLCommandBuffer, time: Float = 0,
        pointer: SIMD2<Float> = SIMD2(0.5, 0.5), pointerEvents: [PointerEvent] = []
    ) {
        // 脚本运行时建的图层（thisScene.createLayer）：这一帧把它们建成绘制项
        for request in state.drainPendingLayers() { appendRuntimeLayer(request.id, model: request.model) }
        // 文字可能变了（时钟）：先把贴图刷新到当前字符串，挂了特效链的输入也跟着换
        for draw in draws {
            guard let text = draw.text,
                  let loaded = text.texture(at: time, canvasScale: canvasScaleFor(target)) else { continue }
            if let chain = draw.chain, chain.source.texture !== loaded.texture { chain.source = loaded }
        }
        // 精灵图动画图层上的特效：链子的输入换成这一时刻的那一帧
        for draw in draws {
            guard let sprite = draw.sprite, let chain = draw.chain else { continue }
            let index = sprite.frameIndex(at: time)
            chain.source = LoadedTexture(
                texture: sprite.image(of: index), imageSize: sprite.frameSize, uvScale: SIMD2(1, 1), clampsUVs: true,
                usesNearestFiltering: false)
            chain.sourceCorners = sprite.corners(of: index)
        }
        // 属性脚本（位置、悬浮缩放、显隐…）：时间相关的字段每帧重算
        let frameTime = lastEncodeTime.map { min(max(time - $0, 0), 0.25) } ?? 1 / 30
        lastEncodeTime = time
        // 音频频谱先推给脚本（`engine.registerAudioBuffers` 返回的数组），脚本这一帧就能用到当前的频谱
        if let audio = audioSpectrum?.bands {
            for draw in draws { draw.scripted?.refreshAudio(audio) }
            for layer in controllerScripts { layer.refreshAudio(audio) }
        }
        // 先跑"控制器"脚本（挂在没有绘制的图层上，例如幻灯片控制器），它们会改别的图层
        for layer in controllerScripts { layer.evaluate(at: time, frameTime: frameTime) }
        for draw in draws { draw.scripted?.evaluate(at: time, frameTime: frameTime) }
        // 挂在木偶骨骼上的图层：按父木偶这一帧的骨骼姿势挪到挂点上
        updateAttachments(at: time)
        // 脚本可能改了父图层，世界变换要重算（没被改过的图层直接复用构建时的值）
        state.refreshWorlds()
        // 文字、纯色图层的颜色和透明度在特效之前作用（见 colorIntoChain）。要在脚本跑完之后刷：
        // 脚本这一帧改的颜色 / 透明度当帧就要进链子（颜色变了静态链也会重算，见 EffectChain.inputColor）
        for draw in draws where draw.colorIntoChain {
            draw.chain?.inputColor = state.color(draw.objectID)
        }
        // 特效链各自在离屏纹理里画，必须在屏幕这一遍开始之前做完
        let audio = audioSpectrum?.bands
        for chain in chains where !(chain.isStatic && chain.hasEncodedStatic) {
            // 静态链算一次就够，算完放掉用不上的那张中间缓冲（命令缓冲会留着它直到 GPU 做完）；重算时再建
            guard (try? chain.restoreSpareBuffer()) != nil else { continue }
            chain.encode(into: commandBuffer, time: time, pointer: pointer, audio: audio)
            if chain.isStatic {
                chain.hasEncodedStatic = true
                chain.releaseSpareBuffer()
            }
        }

        func screenPass(clearing: Bool) -> (any MTLRenderCommandEncoder)? {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = clearing ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(clearColor.x), green: Double(clearColor.y), blue: Double(clearColor.z), alpha: 1)
            return commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        }
        guard var encoder = screenPass(clearing: true) else { return }

        // 屏幕投影 × 2D 摄像机
        let projection = Self.projection(
            kind: projectionKind, canvas: canvasSize, center: canvasCenter, fill: fillBox, camera: sceneCamera,
            fov: fov, near: nearz, far: farz,
            target: SIMD2(Float(target.width), Float(target.height)), focus: focus) * cameraMatrix(at: time)
        // 鼠标在画布坐标里的位置（粒子的控制点可以跟随鼠标）
        let pointerClip = projection.inverse * SIMD4(pointer.x * 2 - 1, 1 - pointer.y * 2, 0, 1)
        let canvasPointer = SIMD2(pointerClip.x, pointerClip.y)
        /// 最上面那个鼠标点到的脚本图层（绘制顺序里靠后的在上面）
        func scriptedLayer(under point: SIMD2<Float>) -> ScriptedLayer? {
            for objectID in state.drawOrder().reversed() {
                guard let position = drawIndexByObject[objectID], let scripted = draws[position].scripted,
                      scripted.handlesPointer
                else { continue }
                let quad = Self.moved(draws[position].vertices, by: state.delta(objectID))
                if Self.contains(quad, point) { return scripted }
            }
            return nil
        }
        // 点击/拖动（全局鼠标监听来的）：送给鼠标指着的那个图层的脚本；
        // 按下时记下这一层，拖动和抬起都还给它（鼠标快速拖动时会跑到图层外面）
        for event in pointerEvents {
            let clip = projection.inverse
                * SIMD4(event.position.x * 2 - 1, 1 - event.position.y * 2, 0, 1)
            let canvasPoint = SIMD2(clip.x, clip.y)
            let handler = switch event.kind {
            case .down: "cursorDown"
            case .up: "cursorUp"
            case .dragged: "cursorMove"
            case .click: "cursorClick"
            }
            let underPointer = scriptedLayer(under: canvasPoint)
            let target = (event.kind == .dragged || event.kind == .up) ? (pointerCapture ?? underPointer) : underPointer
            if event.kind == .down { pointerCapture = underPointer }
            if event.kind == .up { pointerCapture = nil }
            target?.pointerEvent(handler, position: canvasPoint)
        }
        // 鼠标进了哪个图层：桌面窗口忽略鼠标事件，所以这里用全局鼠标位置给脚本补 cursorEnter / Leave / Move
        for draw in draws {
            guard let scripted = draw.scripted, scripted.handlesPointer else { continue }
            let quad = Self.moved(draw.vertices, by: state.delta(draw.objectID))
            scripted.pointerMoved(inside: Self.contains(quad, canvasPointer), position: canvasPointer)
        }
        for objectID in state.drawOrder() {
            guard let position = drawIndexByObject[objectID] else { continue }
            let draw = draws[position]
            guard state.isVisible(objectID) else { continue }
            // 脚本改了位置/缩放时，把它当作画布坐标里的额外变换乘在投影前面
            let viewProjection = projection * state.delta(objectID)
            // 从池子借了主缓冲的链子：画完这一层就还回去（`defer` 在这一轮循环结束时执行）
            var pooledChain: EffectChain?
            defer { pooledChain?.releaseBuffers(to: bufferPool) }
            // 延后到这里的链子：轮到这一层绘制时才在离屏缓冲里算（不被别的特效引用，所以不会有人等它的结果）
            if let chain = draw.chain, draw.composeCorners == nil, !chain.needsScreenCopy,
               !chains.contains(where: { $0 === chain }) {
                // 链子要在离屏缓冲里画，先收掉屏幕这一遍的编码器，算完再接着画
                encoder.endEncoding()
                let ready = chain.borrowBuffers(from: bufferPool)
                if ready {
                    pooledChain = chain
                    chain.encode(into: commandBuffer, time: time, pointer: pointer, audio: audio)
                }
                guard let resumed = screenPass(clearing: false) else { return }
                encoder = resumed
                // 借不到主缓冲（显存不够）就别画这一层，免得拿 1×1 占位缓冲画出花屏
                if !ready { continue }
            }
            if let corners = draw.composeCorners, let chain = draw.chain {
                // 合成层：暂停屏幕这一遍，拷一份到这里为止的画面，从中取出图层矩形那一块跑特效链
                encoder.endEncoding()
                guard let copy = frameCopy.copy(of: target, device: device, commandBuffer: commandBuffer) else { return }
                chain.source = LoadedTexture(
                    texture: copy, imageSize: SIMD2(Float(copy.width), Float(copy.height)), uvScale: SIMD2(1, 1),
                    clampsUVs: true, usesNearestFiltering: false)
                chain.sourceCorners = corners.map { corner in
                    let clip = viewProjection * SIMD4(corner.x, corner.y, 0, 1)
                    return SIMD2(clip.x * 0.5 + 0.5, 0.5 - clip.y * 0.5)
                }
                chain.encode(into: commandBuffer, time: time, pointer: pointer, audio: audio)
                guard let resumed = screenPass(clearing: false) else { return }
                encoder = resumed
            }
            if let chain = draw.chain, chain.needsScreenCopy, draw.composeCorners == nil {
                // 这一层的特效要读"到这里为止的画面"（WE 的 `_rt_FullFrameBuffer`，
                // 辉光/光线类特效开"复制背景"时用的就是它）：和合成层一样，先暂停屏幕这一遍、
                // 拷一份当前画面，再跑特效链（通道用 g_EffectModelViewProjectionMatrix 换算出屏幕坐标去取样）
                encoder.endEncoding()
                guard let copy = frameCopy.flippedCopy(
                    of: target, device: device, commandBuffer: commandBuffer,
                    pipeline: pipelines[PipelineKey(blend: .opaque, textured: true)]!)
                else { return }
                chain.screenCopy = copy
                chain.encode(into: commandBuffer, time: time, pointer: pointer, audio: audio)
                guard let resumed = screenPass(clearing: false) else { return }
                encoder = resumed
            }
            if let particles = draw.particles {
                // 折射粒子要读"到这里为止的画面"（WE 的 _rt_FullFrameBuffer）：和合成层一样，
                // 先结束屏幕这一遍、拷一份，再接着画
                var copy: (any MTLTexture)?
                if particles.needsScreenCopy {
                    encoder.endEncoding()
                    guard let flipped = frameCopy.flippedCopy(
                        of: target, device: device, commandBuffer: commandBuffer,
                        pipeline: pipelines[PipelineKey(blend: .opaque, textured: true)]!)
                    else { return }
                    guard let resumed = screenPass(clearing: false) else { return }
                    encoder = resumed
                    copy = flipped
                }
                particles.encode(
                    into: encoder, projection: viewProjection, time: time, pointer: canvasPointer, screenCopy: copy)
                continue
            }
            if let material = draw.material {
                // 材质自带着色器的图层（旗帜类）：用它自己的顶点/片段着色器画
                encodeMaterial(
                    material, vertices: draw.vertices, encoder: encoder, projection: viewProjection, time: time)
                continue
            }
            guard let pipeline = pipelines[draw.pipeline] else { continue }
            encoder.setRenderPipelineState(pipeline)
            // 带特效的文字/纯色图层：颜色和透明度已经在特效链的输入端乘过了。WE 是先上色再跑特效的——
            // Lucy 的时钟透明度 0.66，WE 截图里字芯却是纯白（255），因为辉光的合成通道会把透明度加回 1；
            // 先跑特效、最后再乘 0.66 的话字芯最亮只有 168，辉光也跟着发灰
            var uniforms = Uniforms(
                projection: viewProjection, color: draw.colorIntoChain ? SIMD4(1, 1, 1, 1) : state.color(objectID),
                mode: SIMD4(draw.blendMode, 0, 0, 0))
            if let mesh = draw.mesh {
                encoder.setVertexBuffer(mesh.animator?.vertexBuffer(at: time) ?? mesh.vertices, offset: 0, index: 0)
            } else if let sprite = draw.sprite, draw.chain == nil {
                // 精灵图动画：纹理坐标换成这一帧在图集上的那一格
                let vertices = sprite.vertices(draw.vertices, frame: sprite.frameIndex(at: time))
                vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            } else {
                draw.vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            var texture: LoadedTexture?
            if let text = draw.text {
                texture = draw.chain?.output ?? text.texture(at: time, canvasScale: canvasScaleFor(target))
                if texture == nil { continue }
            } else if let sprite = draw.sprite, draw.chain == nil, let base = draw.texture {
                // 精灵图动画：这一帧可能在第 2、3…张图像上
                texture = LoadedTexture(
                    texture: sprite.image(of: sprite.frameIndex(at: time)), imageSize: base.imageSize,
                    uvScale: base.uvScale, clampsUVs: base.clampsUVs, usesNearestFiltering: base.usesNearestFiltering)
            } else {
                texture = draw.chain?.output ?? draw.texture
            }
            // 视频纹理：换成这一时刻的帧（贴图是共用的，按时间顺序解，命中缓存就不重新解码）
            if let video = texture?.video, let frame = video.texture(at: time, waits: waitsForVideoFrames) {
                texture = LoadedTexture(
                    texture: frame, imageSize: texture!.imageSize, uvScale: SIMD2(1, 1), clampsUVs: true,
                    usesNearestFiltering: false)
            }
            if let texture {
                encoder.setFragmentTexture(texture.texture, index: 0)
                let key = SamplerKey(clamp: texture.clampsUVs, nearest: texture.usesNearestFiltering)
                encoder.setFragmentSamplerState(samplers[key], index: 0)
            }
            if let mesh = draw.mesh {
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: mesh.indexCount, indexType: .uint16, indexBuffer: mesh.indices,
                    indexBufferOffset: 0)
            } else if let corners = draw.regionCorners {
                // 特效链只算了内容附近那一块：只让这块在屏幕上的外接矩形里的像素参与，外面本来就是透明的
                guard let scissor = EffectRegion.screenScissor(
                    corners, projection: viewProjection, target: SIMD2(target.width, target.height))
                else { continue }
                encoder.setScissorRect(scissor)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
            } else {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.endEncoding()
        // 场景泛光：所有图层画完以后，把亮的部分模糊了加回去
        if let bloom, let frame = frameCopy.copy(of: target, device: device, commandBuffer: commandBuffer) {
            bloom.encode(into: commandBuffer, target: target, frame: frame)
        }
    }

    /// 脚本运行时建的图层：读模型 → 材质 → 第一张贴图，按图层当前的 origin/scale/朝向摆一个四边形。
    /// 特效不处理（语料里这几处都没有），混合方式照材质里的 blending
    private func appendRuntimeLayer(_ id: Int, model path: String) {
        guard let model = runtimeFiles.json(path),
              let materialPath = model["material"] as? String, let material = runtimeFiles.json(materialPath),
              let pass = (material["passes"] as? [[String: Any]])?.first,
              let textureName = (pass["textures"] as? [Any])?.first as? String,
              let texture = try? runtimeTextures.texture(named: textureName)
        else { return }
        let blend: Blend = switch pass["blending"] as? String {
        case "additive": .additive
        case "opaque": .opaque
        default: .translucent
        }
        let size = texture.imageSize
        // 四边形按"不带缩放"的世界摆好：脚本刚 createLayer 出来的图层 scale 往往是 0
        // （模板里是 `new Vec3(barWidth)`，y、z 都是 0），把它烘进顶点的话四边形会被压成一条线，
        // 而且缩放 0 乘出来的分量在 Float 里直接丢精度，之后脚本再改 scale 也救不回来。
        // 这里只烘平移和旋转，缩放留给每帧的 delta 施加
        // 对齐（脚本通常在建图层时就设好，例如可视化条的底边对齐）在去掉缩放之后再挪，
        // 这样缩放始终以对齐点为基准，和每帧的 delta 一致
        state.setQuadSize(id, size)
        let base = state.bakeBuildWorld(id, keepsScale: false)
        let vertices = Self.runtimeQuad(world: base, size: size, uvScale: texture.uvScale)
        draws.append(
            Draw(
                vertices: vertices, color: state.color(id), pipeline: PipelineKey(blend: blend, textured: true),
                texture: texture, blendMode: 0, scripted: nil, objectID: id))
        drawIndexByObject[id] = draws.count - 1
    }

    /// 以对象原点为中心、给定尺寸的矩形（和 DrawListBuilder 里那份一致）
    private static func runtimeQuad(world: simd_float4x4, size: SIMD2<Float>, uvScale: SIMD2<Float>) -> [SIMD4<Float>] {
        let half = size / 2
        let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2(-half.x, -half.y), SIMD2(0, uvScale.y)),
            (SIMD2(half.x, -half.y), SIMD2(uvScale.x, uvScale.y)),
            (SIMD2(-half.x, half.y), SIMD2(0, 0)),
            (SIMD2(half.x, half.y), SIMD2(uvScale.x, 0)),
        ]
        return corners.map { position, uv in
            let transformed = world * SIMD4(position.x, position.y, 0, 1)
            return SIMD4(transformed.x, transformed.y, uv.x, uv.y)
        }
    }

    /// 离屏画一帧，读回成图片。用于截图同步系统壁纸和开发工具
    public func renderImage(
        width: Int, height: Int, time: Float = 0, pointer: SIMD2<Float> = SIMD2(0.5, 0.5),
        pointerEvents: [PointerEvent] = []
    ) throws -> CGImage {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer()
        else { throw FormatError("无法创建离屏渲染目标") }
        encode(into: target, commandBuffer: commands, time: time, pointer: pointer, pointerEvents: pointerEvents)
        commands.commit()
        commands.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw FormatError("无法生成图片") }
        return image
    }

    public func makeCommandBuffer() -> (any MTLCommandBuffer)? {
        queue.makeCommandBuffer()
    }

    /// 用材质自带的着色器画一个四边形：顶点转成 WE 的"位置 3f + 纹理坐标 2f"布局，
    /// `g_ModelViewProjectionMatrix` 设为画布坐标 → 裁剪空间的投影
    private func encodeMaterial(
        _ material: MaterialDraw, vertices drawVertices: [SIMD4<Float>], encoder: any MTLRenderCommandEncoder,
        projection: simd_float4x4, time: Float
    ) {
        encoder.setRenderPipelineState(material.program.pipeline)
        var vertices: [Float] = []
        vertices.reserveCapacity(drawVertices.count * 5)
        for vertex in drawVertices {
            vertices.append(contentsOf: [vertex.x, vertex.y, 0, vertex.z, vertex.w])
        }
        var vertexUniforms = material.vertexUniforms
        var fragmentUniforms = material.fragmentUniforms
        vertexUniforms.set("g_Time", [time])
        fragmentUniforms.set("g_Time", [time])
        vertexUniforms.setMatrix("g_ModelViewProjectionMatrix", projection)
        fragmentUniforms.setMatrix("g_ModelViewProjectionMatrix", projection)
        vertices.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: ProgramCache.vertexBufferIndex)
        }
        encoder.setVertexBytes(vertexUniforms.bytes, length: vertexUniforms.bytes.count, index: 0)
        encoder.setFragmentBytes(fragmentUniforms.bytes, length: fragmentUniforms.bytes.count, index: 0)
        let sampler = samplers[SamplerKey(clamp: true, nearest: false)]
        var slots = Set(material.program.interface.textures.map(\.index))
        slots.formUnion(material.textures.keys)
        for slot in slots {
            let texture = material.textures[slot]?.texture ?? fallbackTexture
            encoder.setFragmentTexture(texture, index: slot + 1)
            encoder.setFragmentSamplerState(sampler, index: slot + 1)
            encoder.setVertexTexture(texture, index: slot + 1)
            encoder.setVertexSamplerState(sampler, index: slot + 1)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func canvasScaleFor(_ target: any MTLTexture) -> Float {
        canvasScale(target: SIMD2(Float(target.width), Float(target.height)))
    }

    /// 画布单位 → 目标像素的比例（和投影用的是同一个取景，包括避开空边时的放大）
    public func canvasScale(target: SIMD2<Float>) -> Float {
        Self.framing(canvas: canvasSize, center: canvasCenter, fill: fillBox, target: target, focus: focus).scale
    }

    /// 不构建场景、只读 scene.json 得到的固定画布尺寸（正交场景写了宽高时）；auto / 透视场景为 nil。
    /// 壁纸设置里"完整显示"要先知道画布比例，才能按缩小后的尺寸构建
    public static func fixedCanvasSize(of package: ScenePackage) -> SIMD2<Float>? {
        guard let data = package.contents(of: "scene.json"), let scene = try? SceneDescription(json: data),
              case .fixed(let size) = scene.projection, size.x > 0, size.y > 0
        else { return nil }
        return size
    }

    /// 作者声明的画布有时比真正有内容的区域大：3681810302 声明 4000×2650，背景图只有 4000×2508，顶上
    /// 142 单位没有任何图层。铺满裁切正好露出这一条时，屏幕上就是一条场景清屏色（0.7 灰）的边。
    /// 返回画布里真正有内容的框（画布与内容包围盒的交集），只在内容几乎盖满画布、只差一条薄边
    /// （≥ 88% 面积）时才给：内容本来就只占一小块的场景（时钟、单张小图）不能为了"不露边"放大。
    /// 内容已经盖满画布时为 nil
    static func fillBox(
        canvas: SIMD2<Float>, content: (size: SIMD2<Float>, center: SIMD2<Float>)?
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let content, canvas.x > 0, canvas.y > 0 else { return nil }
        let lo = simd_max(content.center - content.size / 2, .zero)
        let hi = simd_min(content.center + content.size / 2, canvas)
        let size = hi - lo
        guard size.x > 0, size.y > 0, size.x < canvas.x || size.y < canvas.y,
              size.x * size.y >= 0.88 * canvas.x * canvas.y
        else { return nil }
        return (lo, hi)
    }

    /// 正交场景在目标上的取景：画布按铺满裁切放到目标上，`visible` 是屏幕上看得见的那块画布的尺寸，
    /// `center` 是它的中心（画布坐标），`scale` 是画布单位 → 目标像素的比例。
    ///
    /// 给了 `fill`（画布里真正有内容的框）时，只在铺满裁切**真的会露出**框外的空边时才动：先把取景平移进框里，
    /// 框比取景还窄的方向再放大到刚好不露。屏幕比例本来就把空边切掉的时候（例如 16:9 屏上的 3681810302）
    /// 取景和原来完全一样
    ///
    /// `focus` 是用户在壁纸设置里选的取景位置：画布被裁掉的那个方向上从最左 / 最上（0）到最右 / 最下（1），
    /// 默认 0.5 居中（和 WE 一样）
    static func framing(
        canvas: SIMD2<Float>, center: SIMD2<Float>, fill: (min: SIMD2<Float>, max: SIMD2<Float>)?,
        target: SIMD2<Float>, focus: SIMD2<Float> = SIMD2(0.5, 0.5)
    ) -> (visible: SIMD2<Float>, center: SIMD2<Float>, scale: Float) {
        let scale = max(target.x / canvas.x, target.y / canvas.y)
        var visible = target / scale
        // 画布坐标是 y 朝上：focus.y = 0（看最上面）时取景中心往上挪
        let slack = simd_max(canvas - visible, .zero)
        let center = center + SIMD2((focus.x - 0.5) * slack.x, (0.5 - focus.y) * slack.y)
        guard let fill else { return (visible, center, scale) }
        let room = fill.max - fill.min
        let zoom = max(1, visible.x / room.x, visible.y / room.y)
        visible /= zoom
        let lowest = fill.min + visible / 2
        let highest = fill.max - visible / 2
        return (visible, simd_min(simd_max(center, lowest), highest), scale * zoom)
    }

    /// 画布坐标（原点左下、y 向上）→ Metal 裁剪空间，按铺满裁切居中
    static func coverProjection(canvas: SIMD2<Float>, target: SIMD2<Float>) -> simd_float4x4 {
        coverProjection(canvas: canvas, center: canvas / 2, target: target)
    }

    /// 铺满裁切，但以 `center`（画布坐标）为屏幕中心——`.auto` 场景的画布是按内容包围盒撑出来的，
    /// 内容中心不一定落在画布正中，要拿包围盒中心来对齐屏幕中心。给了 `fill` 时按 `framing` 避开空边
    static func coverProjection(
        canvas: SIMD2<Float>, center: SIMD2<Float>, fill: (min: SIMD2<Float>, max: SIMD2<Float>)? = nil,
        target: SIMD2<Float>, focus: SIMD2<Float> = SIMD2(0.5, 0.5)
    ) -> simd_float4x4 {
        let (visible, center, _) = framing(canvas: canvas, center: center, fill: fill, target: target, focus: focus)
        return simd_float4x4(columns: (
            SIMD4(2 / visible.x, 0, 0, 0),
            SIMD4(0, 2 / visible.y, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(-2 * center.x / visible.x, -2 * center.y / visible.y, 0, 1)))
    }

    /// 场景投影：正交场景按"铺满裁切"把画布映射到目标；透视场景用顶层相机做 look-at + 透视投影。
    ///
    /// 透视的未知量是"1 世界单位等于多少画布像素"：这里取"相机停在 center 平面上时看到的高度正好是画布
    /// 高度"（`unitsPerPixel = 2·distance·tan(fov/2) / canvasHeight`），于是 cap 到相机距离 1 个单位、
    /// fov 50 的旗帜类作者数据下，物体按像素尺寸摆好就正好铺满画面。目标比例和画布不一致时按"铺满"放宽
    /// 纵向视场角，避免露出画面外的空白
    /// 父木偶在动时，挂在它骨骼上的图层每帧跟着挪（和蒙皮用同一个时间）
    private func updateAttachments(at time: Float) {
        guard !attachmentLinks.isEmpty else { return }
        var bonesByParent: [Int: [simd_float4x4]] = [:]
        for link in attachmentLinks {
            guard let position = drawIndexByObject[link.parent], let animator = draws[position].mesh?.animator
            else { continue }
            if bonesByParent[link.parent] == nil { bonesByParent[link.parent] = animator.boneWorlds(at: time) }
            guard let bones = bonesByParent[link.parent], link.bone < bones.count else { continue }
            state.setAttachment(link.child, bones[link.bone] * link.offset)
        }
    }

    static func projection(
        kind: SceneDescription.Projection, canvas: SIMD2<Float>, center: SIMD2<Float>,
        fill: (min: SIMD2<Float>, max: SIMD2<Float>)? = nil,
        camera: SceneDescription.ViewCamera?, fov: Float, near: Float, far: Float, target: SIMD2<Float>,
        focus: SIMD2<Float> = SIMD2(0.5, 0.5)
    ) -> simd_float4x4 {
        guard case .perspective = kind, let camera else {
            return coverProjection(canvas: canvas, center: center, fill: fill, target: target, focus: focus)
        }
        let direction = camera.center - camera.eye
        let distance = simd_length(direction)
        guard distance > 1e-4, canvas.x > 0, canvas.y > 0, target.x > 0, target.y > 0 else {
            return coverProjection(canvas: canvas, center: center, target: target)
        }
        let halfFov = min(max(fov, 1), 170) * .pi / 360
        let unitsPerPixel = 2 * distance * tan(halfFov) / canvas.y
        let canvasAspect = canvas.x / canvas.y
        let targetAspect = target.x / target.y
        // 目标比画布窄时要把横向也盖住：纵向视场角按比例放大
        let halfTan = tan(halfFov)
        let verticalHalfTan = targetAspect < canvasAspect ? halfTan * canvasAspect / targetAspect : halfTan
        let projection = perspectiveMatrix(
            verticalFov: 2 * atan(verticalHalfTan), aspect: targetAspect, near: near, far: far)
        let view = lookAt(eye: camera.eye, center: camera.center, up: camera.up)
        // 画布像素 → 世界单位（以画布中心为原点）
        return projection * view * simd_float4x4(diagonal: SIMD4(unitsPerPixel, unitsPerPixel, unitsPerPixel, 1))
            * {
                var recenter = matrix_identity_float4x4
                recenter.columns.3 = SIMD4(-center.x, -center.y, 0, 1)
                return recenter
            }()
    }

    /// 右手坐标系、视线沿 -z、深度范围 0…1（Metal 的约定）的透视矩阵
    static func perspectiveMatrix(verticalFov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(verticalFov / 2)
        let x = y / max(aspect, 1e-4)
        let z = far / max(near - far, 1e-4)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)))
    }

    /// 世界 → 观察矩阵（右手，相机在观察空间里沿 -z 看）
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(center - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let trueUp = simd_cross(right, forward)
        return simd_float4x4(columns: (
            SIMD4(right.x, trueUp.x, -forward.x, 0),
            SIMD4(right.y, trueUp.y, -forward.y, 0),
            SIMD4(right.z, trueUp.z, -forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(trueUp, eye), simd_dot(forward, eye), 1)))
    }

    /// 2D 摄像机的视图变换：把画布绕中心按 zoom 缩放，再按摄像机位置平移。
    /// 摄像机停在正常取景（zoom 1、origin 0）时是单位矩阵。
    private func cameraMatrix(at time: Float) -> simd_float4x4 {
        guard let camera else { return matrix_identity_float4x4 }
        let state = camera.state(at: time)
        let center = canvasSize / 2
        var toCenter = matrix_identity_float4x4
        toCenter.columns.3 = SIMD4(center.x, center.y, 0, 1)
        var toCamera = matrix_identity_float4x4
        toCamera.columns.3 = SIMD4(-center.x - state.origin.x, -center.y - state.origin.y, 0, 1)
        return toCenter * simd_float4x4(diagonal: SIMD4(state.zoom, state.zoom, 1, 1)) * toCamera
    }

    /// 点在不在这块四边形里（凸四边形，允许旋转）
    static func contains(_ quad: [SIMD4<Float>], _ point: SIMD2<Float>) -> Bool {
        guard quad.count == 4 else { return false }
        // 顶点是 triangle strip 的顺序：左下、右下、左上、右上 → 沿边界走一圈是 0 → 1 → 3 → 2
        let order = [0, 1, 3, 2]
        var positive = false
        var negative = false
        for (step, index) in order.enumerated() {
            let a = SIMD2(quad[index].x, quad[index].y)
            let next = order[(step + 1) % order.count]
            let b = SIMD2(quad[next].x, quad[next].y)
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross > 0 { positive = true } else if cross < 0 { negative = true }
            if positive && negative { return false }
        }
        return true
    }

    /// 把构建时的四边形按变换增量搬到当前位置（脚本改了 origin / scale 时用）
    static func moved(_ quad: [SIMD4<Float>], by delta: simd_float4x4) -> [SIMD4<Float>] {
        quad.map { vertex in
            let point = delta * SIMD4(vertex.x, vertex.y, 0, 1)
            return SIMD4(point.x, point.y, vertex.z, vertex.w)
        }
    }

    /// 铺满裁切以后，画布上真正能在屏幕上看到的那块（画布坐标，左下原点）。
    /// 屏幕比例比画布窄（或宽）时它就是画布里居中的一条，两侧（或上下）会被切掉
    static func visibleRegion(
        canvas: SIMD2<Float>, target: SIMD2<Float>, focus: SIMD2<Float> = SIMD2(0.5, 0.5)
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        let scale = max(target.x / canvas.x, target.y / canvas.y)
        let visible = target / scale
        // 画布坐标左下原点：focus.y = 0（看最上面）时露出的是画布顶上那条
        let min = (canvas - visible) * SIMD2(focus.x, 1 - focus.y)
        return (min, min + visible)
    }

    /// 同上，但按 `framing` 的取景（避开空边时平移 / 放大过的那块）
    static func visibleRegion(
        canvas: SIMD2<Float>, center: SIMD2<Float>, fill: (min: SIMD2<Float>, max: SIMD2<Float>)?,
        target: SIMD2<Float>, focus: SIMD2<Float> = SIMD2(0.5, 0.5)
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        let (visible, center, _) = framing(canvas: canvas, center: center, fill: fill, target: target, focus: focus)
        return (center - visible / 2, center + visible / 2)
    }

    /// 把一个矩形挪进可见区域要加的画布坐标偏移：放得下就贴边挪，比可见区域还大就居中。
    /// 时钟这类文字图层用它把被裁掉的那一半拉回屏幕里
    static func fitOffset(
        lo: SIMD2<Float>, hi: SIMD2<Float>, regionMin: SIMD2<Float>, regionMax: SIMD2<Float>
    ) -> SIMD2<Float> {
        func axis(_ lo: Float, _ hi: Float, _ regionLo: Float, _ regionHi: Float) -> Float {
            if hi - lo >= regionHi - regionLo { return (regionLo + regionHi - lo - hi) / 2 }
            if hi > regionHi { return regionHi - hi }
            if lo < regionLo { return regionLo - lo }
            return 0
        }
        return SIMD2(
            axis(lo.x, hi.x, regionMin.x, regionMax.x), axis(lo.y, hi.y, regionMin.y, regionMax.y))
    }

    /// 文字图层摆好以后的框如果超出了可见区域，返回挪进去以后的世界变换；没超出就返回 nil
    static func placedInView(
        world: simd_float4x4, size: SIMD2<Float>, region: (min: SIMD2<Float>, max: SIMD2<Float>)
    ) -> simd_float4x4? {
        let half = size / 2
        let corners = [
            SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(-half.x, half.y), SIMD2(half.x, half.y),
        ].map { corner -> SIMD2<Float> in
            let point = world * SIMD4(corner.x, corner.y, 0, 1)
            return SIMD2(point.x, point.y)
        }
        var lo = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        for corner in corners { lo = simd_min(lo, corner) }
        var hi = -lo
        for corner in corners { hi = simd_max(hi, corner) }
        let offset = fitOffset(lo: lo, hi: hi, regionMin: region.min, regionMax: region.max)
        guard offset.x != 0 || offset.y != 0 else { return nil }
        var placed = world
        placed.columns.3.x += offset.x
        placed.columns.3.y += offset.y
        return placed
    }

    private static func makePipeline(
        device: any MTLDevice, library: any MTLLibrary, key: PipelineKey
    ) throws -> any MTLRenderPipelineState {
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = 8
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = 16

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "layer_vertex")
        let fragment = switch (key.blend, key.textured) {
        case (.programmable, true): "blend_image_fragment"
        case (.programmable, false): "blend_solid_fragment"
        case (_, true): "image_fragment"
        case (_, false): "solid_fragment"
        }
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.vertexDescriptor = vertexDescriptor
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        switch key.blend {
        case .opaque, .programmable:
            attachment.isBlendingEnabled = false
        case .translucent, .additive:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = key.blend == .additive ? .one : .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - 构建绘制列表

    /// 构建特效链要用到的共享对象
    private struct EffectContext {
        let device: any MTLDevice
        let programs: ProgramCache
        let copyPipeline: any MTLRenderPipelineState
        let fallback: any MTLTexture
        let transparent: any MTLTexture
        /// 1×1 不透明白色纹理：纯色图层的特效链拿它当输入，乘上图层的颜色就是一块纯色
        let white: any MTLTexture
    }

    private struct DrawListBuilder {
        let scene: SceneDescription
        let files: SceneFiles
        let textures: TextureLoader
        let context: EffectContext
        /// 画布坐标到屏幕像素的缩放（铺满裁切）；nil 表示不限制特效缓冲的尺寸
        let screenScale: Float?
        /// 画布坐标到屏幕裁剪坐标的投影；nil 时（离屏工具）特效的投影矩阵用单位矩阵
        let screenProjection: simd_float4x4?
        /// 屏幕上真正看得见的那块画布；没有目标尺寸（离屏工具）时为 nil，此时不做边界保护
        let visibleCanvasRegion: (min: SIMD2<Float>, max: SIMD2<Float>)?
        var renderedEffects = 0
        var particleSystems = 0
        /// 屏幕这一遍之前要算的特效链，按构建顺序（被引用的图层总在引用它的图层之前）
        var chains: [EffectChain] = []
        /// 限制在内容附近算的特效链：各自要算的面积占整块缓冲的比例（诊断用）
        var regionLimitedChains: [Double] = []
        /// 图层特效只在内容附近算（见 `EffectRegion`）
        var limitsEffectsToContent = true
        /// 按遮罩限制的特效：各自要跑的面积占整块缓冲的比例（诊断用）
        var maskLimitedEffects: [Double] = []
        /// 没能限制的特效链：原因 → 条数（诊断用，SHOW_STATS 时打印）
        var regionSkipReasons: [String: Int] = [:]
        /// 图层编号 → 这个图层（连同它自己的特效）的结果，给 _rt_imageLayerComposite_<编号>_a 用
        private var composites: [Int: LoadedTexture] = [:]
        /// 被别的特效当贴图引用的图层编号
        private let referencedLayers: Set<Int>
        /// 正在构建的特效链是否读了别的图层的结果
        private var usesCompositeInput = false
        /// 正在构建的是文字图层的特效链（辉光强度要按 WE 截图校准，见 textGlowCalibration）
        private var buildingTextChain = false
        /// 文字图层上辉光（shine 的射线通道：同时有 g_Length 和 g_Intensity）的强度系数。
        /// **按 WE 截图实测校准，原因待查**：Lucy 的时钟存的是 rayintensity = 2，WE 4K 截图里却和我们按 1 画的
        /// 一样（字芯占比、光晕占比最接近；按 2 画时光晕把字撑胖、看着发糊）。方向数和采样数用 WE 自己编译的
        /// 着色器缓存核对过（4 个方向、8 个采样，和我们一致），着色器算术、缓冲格式也一致。比较可能的解释是
        /// 我们用 CoreText 画出的笔画比 WE 粗约 1.4 倍，辉光按笔画面积累加、合成时又平方一次，被放大了一倍左右。
        /// 语料里只有 Lucy 的时钟在文字上挂了辉光；以后把字形画得和 WE 一样细了，这个系数应当回到 1
        static let textGlowCalibration: Float = 0.5
        /// 用户属性的当前值，给脚本的 engine.userProperties
        let userProperties: Data?
        /// 运行时图层状态：脚本改的就是它，绘制时按它算
        let state: SceneState
        /// 所有属性脚本（含没有绘制的图层上的，例如幻灯片控制器）
        var scriptedLayers: [ScriptedLayer] = []
        var sounds: [SceneSound] = []
        var effectSummaries: [String] = []
        var unsupported: [String: Int] = [:]
        var problems: [String] = []
        private var worldCache: [Int: simd_float4x4] = [:]
        /// 挂在父木偶挂点上的图层（每帧按父木偶的骨骼更新位置）
        private(set) var attachmentLinks: [AttachmentLink] = []
        private let byID: [Int: SceneDescription.Object]
        /// 每个对象的属性脚本（构建时先建好、跑过 init）
        private var scriptedByObject: [Int: ScriptedLayer] = [:]
        /// 已经建好的图片绘制：特效引用了排在后面的图层时会先把它建出来，主循环轮到它直接复用，
        /// 免得同一条特效链建两遍
        private var drawCache: [Int: Draw] = [:]
        /// 正在按需构建的图层（防止图层互相引用时转圈）
        private var buildingComposites: Set<Int> = []

        /// 按图层的对齐方式（WE 的 alignment）摆四边形：登记四边形尺寸，返回"对齐后"的世界变换并记成构建时的
        /// （脚本运行时改对齐、改缩放，按它算增量；对齐点始终落在原点上）
        private func alignedWorld(_ object: SceneDescription.Object, quad size: SIMD2<Float>) -> simd_float4x4 {
            state.setQuadSize(object.id, size)
            return state.bakeBuildWorld(object.id)
        }

        /// 在**图层自己的框**里算特效链时的缓冲尺寸：图层在屏幕上占的像素（没有屏幕尺寸时按画布坐标），
        /// 每边不超过 4096。文字和形状图层用它，而不是整屏的合成空间：
        /// - 光束（lightshafts）这类 DIRECTDRAW 特效的角点、羽化、遮罩都按图层 0–1 纹理坐标定义，
        ///   放到整屏坐标里算，光就铺满整屏、再被图层四边形切出一块硬边的方块（Lucy 背上那块）；
        /// - 辉光（shine）的射线长度是"缓冲宽度的比例"，整屏宽的缓冲里时钟会拖出一百多像素的横向残影，
        ///   WE 里只是贴着字的一圈光；WE 的文字图层另有 padding 专门给特效留边，也说明特效在框里算
        private func layerSpaceBufferSize(quad: SIMD2<Float>, world: simd_float4x4) -> SIMD2<Int> {
            let worldScale = SIMD2(simd_length(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z)),
                                   simd_length(SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z)))
            let pixels = simd_min(quad * worldScale * (screenScale ?? 1), SIMD2(repeating: 4096))
            return SIMD2(max(1, Int(saturating: pixels.x.rounded())), max(1, Int(saturating: pixels.y.rounded())))
        }

        init(
            scene: SceneDescription, files: SceneFiles, textures: TextureLoader, context: EffectContext,
            screenScale: Float?, screenProjection: simd_float4x4?,
            visibleCanvasRegion: (min: SIMD2<Float>, max: SIMD2<Float>)?,
            userProperties: Data?, state: SceneState
        ) {
            self.scene = scene
            self.userProperties = userProperties
            self.state = state
            self.files = files
            self.textures = textures
            self.context = context
            self.screenScale = screenScale
            self.screenProjection = screenProjection
            self.visibleCanvasRegion = visibleCanvasRegion
            byID = Dictionary(scene.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            referencedLayers = Set(scene.objects.flatMap(\.effects).flatMap(\.passes).flatMap(\.textures).compactMap {
                $0.flatMap(Self.compositeLayerID)
            })
        }

        /// "_rt_imageLayerComposite_421_a" → 421
        static func compositeLayerID(_ name: String) -> Int? {
            let prefix = "_rt_imageLayerComposite_"
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count).prefix { $0.isNumber })
        }

        /// 这条链能不能留到"轮到这一层绘制时"再算：
        /// - 要看"到这里为止的画面"的链本来就得等轮到它（见绘制那一遍的 frameCopy）；
        /// - 被别的特效当贴图引用的链（`_rt_imageLayerComposite_<编号>`）必须先算好，别的链才拿得到结果；
        /// - 静态链只算一次、之后每帧直接用结果，留着更省事。
        /// 其余的都可以延后，好处是链子的缓冲用完就能还给池子
        private func canDeferChain(_ chain: EffectChain, object: SceneDescription.Object) -> Bool {
            !chain.needsScreenCopy && !chain.isStatic && !referencedLayers.contains(object.id)
        }

        /// 按需算出某个图层（连同它自己的特效）的结果。特效可以引用排在它**后面**的图层
        /// （WE 里就是这么用的），主循环还没轮到它们时在这里先建出来，结果记进 composites。
        /// 建好的绘制放进 drawCache，主循环复用，不会重复建链
        private mutating func buildComposite(onDemand layer: Int) -> LoadedTexture? {
            if let cached = composites[layer] { return cached }
            guard !buildingComposites.contains(layer), let object = byID[layer],
                  case .image(let model) = object.kind
            else { return nil }
            buildingComposites.insert(layer)
            defer { buildingComposites.remove(layer) }
            if let draw = makeDraw(object, model: model, scripted: scriptedByObject[object.id]) {
                drawCache[object.id] = draw
                if let chain = draw.chain {
                    chains.append(chain)
                    composites[object.id] = chain.output
                } else if let texture = draw.texture {
                    registerComposite(object, texture: texture, world: worldTransform(object))
                }
            }
            return composites[layer]
        }

        mutating func build() -> (
            draws: [Draw], chains: [EffectChain], renderedEffects: Int, particleSystems: Int, effectSummaries: [String],
            unsupported: [String: Int], problems: [String]
        ) {
        var draws: [Draw] = []
        // 挂在父木偶挂点上的子图层：先按绑定姿势登记挂点，后面算世界变换（烘进顶点、粒子发射位置）都要用到
        prepareAttachments()
        // 先把所有属性脚本建起来跑一遍 init：幻灯片控制器会在 init 里遍历子图层、
        // 把它们的透明度清零，后面的构建和绘制都要看到这些改动
        var scriptedByObject: [Int: ScriptedLayer] = [:]
        for object in scene.objects where !object.fieldScripts.isEmpty {
            if let layer = makeScripted(object) { scriptedByObject[object.id] = layer }
        }
        self.scriptedByObject = scriptedByObject
        for object in scene.objects {
                note(object)
                let scripted = scriptedByObject[object.id]
                guard isVisible(object) else {
                    // 隐藏的图层不画，但被别的特效引用时照样要算出它的结果
                    if case .image(let model) = object.kind, referencedLayers.contains(object.id),
                       composites[object.id] == nil {
                        makeHiddenComposite(object, model: model)
                    }
                    continue
                }
                if let scripted, !scripted.isVisible, !scripted.isDynamic { continue }
                switch object.kind {
                case .image(let model):
                if let cached = drawCache.removeValue(forKey: object.id) {
                        // 特效引用排在后面的图层时已经建好了（链子也加过了），这里只把它排进绘制顺序
                        draws.append(cached)
                    } else if let draw = makeDraw(object, model: model, scripted: scripted) {
                        // 只有"被别的特效当输入"的链必须先算好（引用它的链要拿它的结果）；
                        // 其余链留到轮到这一层绘制时再算（见绘制那一遍），缓冲用完就能还回池子
                        if let chain = draw.chain, draw.composeCorners == nil {
                            if canDeferChain(chain, object: object) {
                                chain.prepareForPooling()
                            } else {
                                chains.append(chain)
                            }
                        }
                        if referencedLayers.contains(object.id), composites[object.id] == nil {
                            if let chain = draw.chain {
                                composites[object.id] = chain.output
                            } else if let texture = draw.texture {
                                registerComposite(object, texture: texture, world: worldTransform(object))
                            }
                        }
                        draws.append(draw)
                    }
                case .shape:
                    if let draw = makeShapeDraw(object, scripted: scripted) {
                        if let chain = draw.chain {
                            if canDeferChain(chain, object: object) { chain.prepareForPooling() }
                            else { chains.append(chain) }
                        }
                        draws.append(draw)
                    }
                case .text:
                    if let draw = makeTextDraw(object, scripted: scripted) {
                        if let chain = draw.chain {
                            if canDeferChain(chain, object: object) { chain.prepareForPooling() }
                            else { chains.append(chain) }
                        }
                        draws.append(draw)
                    }
                case .sound:
                    collectSound(object)
                case .particle(let path):
                    if let layer = makeParticleLayer(object, path: path) {
                        draws.append(Draw(
                            vertices: [], color: .zero, pipeline: PipelineKey(blend: .opaque, textured: false), texture: nil,
                            blendMode: 0, particles: layer, objectID: object.id))
                    }
                default:
                    break
                }
            }
            scriptedLayers = Array(scriptedByObject.values)
            return (draws, chains, renderedEffects, particleSystems, effectSummaries, unsupported, problems)
        }

        private mutating func note(_ object: SceneDescription.Object) {
            switch object.kind {
            case .light: unsupported["灯光", default: 0] += 1
            // 2D 摄像机的开场动画已经支持；透视场景在构建时就被挡下了
            case .camera where object.camera == nil: unsupported["摄像机对象", default: 0] += 1
            case .shape where object.effects.isEmpty: unsupported["没有特效的形状（不画）", default: 0] += 1
            case .image, .group, .particle, .shape, .text, .sound, .camera: break
            }
            switch object.kind {
            case .image, .shape, .text: break
            default:
                guard !object.effects.isEmpty else { break }
                unsupported["非图片图层上的特效", default: 0] += object.effects.count
            }
            // WE 的 common_blending.h 一共定义了 1–32 号混合模式
            if object.colorBlendMode > 32 { unsupported["未知的图层混合模式（按普通处理）", default: 0] += 1 }
        }

        /// 解析图层上的属性脚本（origin / scale / alpha / color / visible）。构建时算一遍当静态值，
        /// 时间相关的字段留给绘制时每帧重算
        private mutating func makeScripted(_ object: SceneDescription.Object) -> ScriptedLayer? {
            guard !object.fieldScripts.isEmpty else { return nil }
            guard let layer = ScriptedLayer(
                object: object, canvasSize: scene.canvasSize ?? SIMD2(1920, 1080), state: state,
                userProperties: userProperties)
            else { return nil }
            problems.append(contentsOf: layer.problems.map { "\(object.name)：\($0)" })
            if !layer.problems.isEmpty {
                unsupported["脚本驱动的字段（按静态值处理）", default: 0] += layer.problems.count
            }
            return layer
        }

        private mutating func makeDraw(
            _ object: SceneDescription.Object, model modelPath: String, scripted: ScriptedLayer?
        ) -> Draw? {
            guard let model = files.json(modelPath) else {
                problems.append("读不到模型 \(modelPath)")
                return nil
            }
            // 世界变换和颜色都从运行时状态取：图层自己的脚本、场景对象接口的改动都在里面
            // （脚本已经把缩放设成 0 的轴按 1 烘，见 bakeBuildWorld）
            let world = state.bakeBuildWorld(object.id)
            let color = state.color(object.id)
            let layerMode = (1...32).contains(object.colorBlendMode) ? Int32(object.colorBlendMode) : 0

            if model["solidlayer"] as? Bool == true {
                let size = object.size ?? SIMD2(256, 256)
                let world = alignedWorld(object, quad: size)
                var draw = Draw(
                    vertices: quad(world: world, size: size, uvScale: SIMD2(1, 1)), color: color,
                    pipeline: PipelineKey(blend: layerMode != 0 ? .programmable : .translucent, textured: false),
                    texture: nil, blendMode: layerMode, scripted: scripted, objectID: object.id)
                // 纯色层上的特效（语料里是音频可视化条）：把这一层的纯色当成特效链的输入。
                // 输入用 1×1 的白贴图，拷贝那一步乘上图层颜色就是一块纯色；特效在图层自己的框里算
                // （和图片、形状、文字一致），图层被缩放/旋转时特效也跟着走
                if !object.effects.isEmpty {
                    let source = LoadedTexture(
                        texture: context.white, imageSize: size, uvScale: SIMD2(1, 1), clampsUVs: true,
                        usesNearestFiltering: false)
                    let layerProjection = screenProjection.map {
                        $0 * world * simd_float4x4(diagonal: SIMD4(size.x / 2, size.y / 2, 1, 1))
                    } ?? matrix_identity_float4x4
                    if let chain = buildChain(
                        object, source: source, size: layerSpaceBufferSize(quad: size, world: world), pixelSize: size,
                        layerModel: world, layerProjection: layerProjection) {
                        chain.inputColor = color
                        draw = Draw(
                            vertices: quad(world: world, size: size, uvScale: SIMD2(1, 1)),
                            color: SIMD4(1, 1, 1, 1),
                            pipeline: PipelineKey(
                                blend: layerMode != 0 ? .programmable : .translucent, textured: true),
                            texture: source, blendMode: layerMode, chain: chain, scripted: scripted,
                            objectID: object.id, colorIntoChain: true)
                    }
                }
                return draw
            }
            if model["fullscreen"] as? Bool == true || model["passthrough"] as? Bool == true {
                return makeComposeDraw(object, fullscreen: model["fullscreen"] as? Bool == true, scripted: scripted)
            }

            guard let materialPath = model["material"] as? String, let material = files.json(materialPath),
                  let pass = (material["passes"] as? [[String: Any]])?.first
            else {
                problems.append("读不到 \(modelPath) 的材质")
                return nil
            }
            guard let textureName = (pass["textures"] as? [Any])?.first as? String else {
                unsupported["没有贴图的图片图层", default: 0] += 1
                return nil
            }
            let texture: LoadedTexture
            do {
                // 只加载屏幕上用得到的分辨率（4K 壁纸在小屏幕上、缩小摆放的图层都用不到原图）
                texture = try textures.texture(named: textureName, fitting: onScreenFitting(quad: object.size, world: world))
            } catch {
                problems.append("\(object.name)：\(error.localizedDescription)")
                return nil
            }
            let blend: Blend
            switch (layerMode, pass["blending"] as? String) {
            case (1..., _): blend = .programmable
            case (_, "additive"): blend = .additive
            case (_, "normal"), (_, "disabled"): blend = .opaque
            default: blend = .translucent
            }
            // 木偶变形：贴图是身体部件拼成的图集，按模型网格拼装成完整的人物。
            // 网格顶点和四边形一样以图层框中心为原点（2572528403 的人物网格 x ±966、y ±670，图层框 1933×1336），
            // 所以也按对齐方式挪：左上对齐的部件原来整体偏了半个框，人物和背景留给它的位置对不上
            if let puppetPath = model["puppet"] as? String {
                return makePuppetDraw(
                    object, path: puppetPath, world: alignedWorld(object, quad: object.size ?? texture.imageSize),
                    texture: texture, color: color, blend: blend, layerMode: layerMode, scripted: scripted)
            }
            // WE 材质自带的着色器（旗帜的 flag 就是这样：顶点只做 MVP 变换，飘动全在片元的法线图滚动里）：
            // 没有特效时直接用那个着色器画四边形，而不是固定的图层管线
            let shaderName = pass["shader"] as? String
            if object.effects.isEmpty, let shaderName, !shaderName.hasPrefix("genericimage"), model["fullscreen"] == nil {
                let quadSize = object.size ?? texture.imageSize
                let world = alignedWorld(object, quad: quadSize)
                if let material = makeMaterialDraw(
                    object, world: world, pass: pass, shaderName: shaderName, blend: blend) {
                    return Draw(
                        vertices: quad(world: world, size: quadSize, uvScale: texture.uvScale),
                        color: color, pipeline: PipelineKey(blend: blend, textured: true), texture: texture,
                        blendMode: layerMode, material: material, scripted: scripted, objectID: object.id)
                }
            } else if let shader = shaderName, !shader.hasPrefix("genericimage") {
                unsupported["着色器 \(shader)（按普通图片处理）", default: 0] += 1
            }
            // GIF 转来的动画图层：贴图是一张排着很多帧的大图，每帧只画当前那一格；没写图层尺寸时按一帧的大小摆
            let sprite = texture.spriteSheet.flatMap {
                SpriteAnimation(sheet: $0, images: [texture.texture] + texture.spriteImages,
                                imageSizes: texture.spriteImageSizes)
            }
            let quadSize = object.size ?? sprite?.frameSize ?? texture.imageSize
            // 按图层的对齐方式摆四边形（底边对齐时从原点往上长）
            let layerWorld = alignedWorld(object, quad: quadSize)
            var draw = Draw(
                vertices: quad(world: layerWorld, size: quadSize, uvScale: texture.uvScale),
                color: color, pipeline: PipelineKey(blend: blend, textured: true), texture: texture,
                blendMode: layerMode, scripted: scripted, objectID: object.id)
            draw.sprite = sprite
            if !object.effects.isEmpty {
                // 图层自身坐标（-1…1）→ 屏幕裁剪坐标。xray 这类特效用它的逆矩阵把鼠标位置换算到图层里
                let layerProjection = screenProjection.map {
                    $0 * layerWorld * simd_float4x4(diagonal: SIMD4(quadSize.x / 2, quadSize.y / 2, 1, 1))
                } ?? matrix_identity_float4x4
                // 特效在图层自己的空间里算（缓冲按贴图分辨率，不超过图层在屏幕上占的像素）：作者画在图层上的
                // 遮罩、X-ray 读的别的图层（`_rt_imageLayerComposite_*`）都按图层 0–1 坐标对齐。
                // 放进整屏缓冲的话遮罩会套到屏幕上的另一块、X-ray 露出来的图整体错位，伸出屏幕的部分也会被切掉
                draw.chain = buildChain(
                    object, source: texture,
                    size: bufferSize(image: sprite?.frameSize ?? texture.imageSize, quad: quadSize, world: layerWorld),
                    pixelSize: sprite?.frameSize ?? texture.imageSize, layerModel: layerWorld,
                    layerProjection: layerProjection)
                if let sprite, let chain = draw.chain {
                    // 链子的输入是当前这一帧（绘制前每帧换），不能只算一次
                    chain.isStatic = false
                    chain.sourceCorners = sprite.corners(of: 0)
                }
                // 特效链的结果没有补齐边距，采样范围用满
                if draw.chain != nil {
                    draw = Draw(
                        vertices: quad(world: layerWorld, size: quadSize, uvScale: SIMD2(1, 1)),
                        color: color,
                        pipeline: PipelineKey(
                            blend: draw.chain!.outputIncludesBackground ? .opaque : draw.pipeline.blend,
                            textured: true),
                        texture: texture, blendMode: layerMode,
                        chain: draw.chain, scripted: scripted, objectID: object.id)
                    draw.sprite = sprite
                    limitChainToContent(&draw, object: object, texture: texture)
                }
            }
            return draw
        }

        /// 特效链只在图层内容附近算、结果也只画那一块（见 `EffectRegion`）。不满足条件时什么也不改
        private mutating func limitChainToContent(
            _ draw: inout Draw, object: SceneDescription.Object, texture: LoadedTexture
        ) {
            guard limitsEffectsToContent, let chain = draw.chain else { return }
            limitEffectsToMasks(chain)
            func skip(_ reason: String) { regionSkipReasons[reason, default: 0] += 1 }
            guard draw.sprite == nil, texture.video == nil, chain.sourceCorners == nil else { return skip("精灵图或视频贴图") }
            guard !chain.needsScreenCopy, !chain.outputIncludesBackground else { return skip("读画面 / 复制背景") }
            guard !referencedLayers.contains(object.id) else { return skip("结果被别的特效引用") }
            // 透明像素的颜色也会画上去的混合方式不行（不透明、5 号深色、10 号浅色）
            switch draw.pipeline.blend {
            case .translucent, .additive: break
            case .programmable where draw.blendMode != 5 && draw.blendMode != 10: break
            default: return skip("混合方式")
            }
            let size = chain.bufferSize
            let bufferSize = SIMD2(Float(size.x), Float(size.y))
            var reach = SIMD2<Float>.zero
            var longest: Float = 0
            for effect in chain.effects {
                guard let effectReach = EffectRegion.reach(of: effect, bufferSize: bufferSize, files: files)
                else { return skip("特效 \(effect.name) 不在核对表里") }
                reach += effectReach
                longest = max(longest, (effectReach * bufferSize).max())
            }
            guard let bounds = textures.contentBounds(of: texture) else { return skip("读不出贴图的内容范围") }
            // 第 0 步把贴图画满缓冲，缩小采样时会读到更粗的 mipmap，内容边缘会洇出去一点
            let margin = EffectRegion.samplingMargin(of: texture, bufferSize: bufferSize)
            let content = bounds + SIMD4(-margin.x, -margin.y, margin.x, margin.y)
            let region = EffectRegion.scissor(
                content: content, reach: EffectRegion.chainGrowth(reach: reach, effects: chain.effects.count, bufferSize: bufferSize),
                bufferSize: size)
            let fraction = Double(region.width * region.height) / Double(max(size.x * size.y, 1))
            // 差不多整块都要算的就不必了
            guard fraction < 0.9 else { return skip("内容几乎铺满") }
            chain.activeRegion = region
            chain.regionGuard = Int(saturating: longest.rounded(.up)) + 2
            draw.regionCorners = EffectRegion.subQuad(
                draw.vertices,
                u: Float(region.x) / bufferSize.x...Float(region.x + region.width) / bufferSize.x,
                v: Float(region.y) / bufferSize.y...Float(region.y + region.height) / bufferSize.y)
            regionLimitedChains.append(fraction)
        }

        /// 各特效只在遮罩范围里跑，外面照抄输入（见 `EffectRegion.changedRegion`）。结果和整块都跑逐像素一样，
        /// 所以不挑混合方式、被不被引用
        private mutating func limitEffectsToMasks(_ chain: EffectChain) {
            let size = chain.bufferSize
            let regions = chain.effects.map { effect in
                EffectRegion.changedRegion(of: effect, bufferSize: size, files: files) { textures.bounds(of: $0, test: $1) }
            }
            guard regions.contains(where: { $0 != nil }) else { return }
            chain.effectRegions = regions
            if let first = regions.first ?? nil, let effect = chain.effects.first,
               let reach = EffectRegion.reach(
                   of: effect, bufferSize: SIMD2(Float(size.x), Float(size.y)), files: files) {
                // 第一个特效在"范围 + 偏移"里读输入（再多 2 像素给线性插值）
                let scaled = (reach * SIMD2(Float(size.x), Float(size.y))).rounded(.up)
                let grow = SIMD2(Int(saturating: scaled.x), Int(saturating: scaled.y)) &+ 2
                let x0 = max(0, first.x - grow.x), y0 = max(0, first.y - grow.y)
                let x1 = min(size.x, first.x + first.width + grow.x), y1 = min(size.y, first.y + first.height + grow.y)
                chain.copyRegion = MTLScissorRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
            }
            for region in regions {
                guard let region else { continue }
                maskLimitedEffects.append(Double(region.width * region.height) / Double(max(size.x * size.y, 1)))
            }
        }

        /// 用材质自带的着色器画一个四边形。顶点是画布坐标 + 纹理坐标（和 WE 的顶点布局一致），
        /// `g_ModelViewProjectionMatrix` 是画布坐标 → 裁剪空间的投影；材质参数（如 flag 的 Speed/Strength）
        /// 按"场景覆盖 → 材质 → 着色器默认值"取
        private mutating func makeMaterialDraw(
            _ object: SceneDescription.Object, world: simd_float4x4, pass: [String: Any], shaderName: String,
            blend: Blend
        ) -> MaterialDraw? {
            let combos = (pass["combos"] as? [String: Any] ?? [:]).compactMapValues { SceneValue.int($0) }
            var provided: Set<Int> = []
            var slots: [Int: LoadedTexture] = [:]
            for (index, value) in (pass["textures"] as? [Any] ?? []).enumerated() {
                guard let name = value as? String, !name.isEmpty, !name.hasPrefix("_rt_") else { continue }
                provided.insert(index)
                if let texture = try? textures.texture(
                    named: name, fitting: onScreenFitting(quad: object.size, world: world)) {
                    slots[index] = texture
                } else {
                    problems.append("\(object.name)：读不到贴图 \(name)")
                }
            }
            let blending: ProgramCache.Blending = switch blend {
            case .additive: .additive
            case .opaque: .none
            default: .translucent
            }
            let program: CompiledProgram
            do {
                program = try context.programs.program(
                    shader: shaderName, combos: combos, providedTextures: provided, vertexFormat: .effectQuad,
                    blending: blending)
            } catch {
                unsupported["着色器 \(shaderName)（按普通图片处理）", default: 0] += 1
                problems.append("\(object.name)：着色器 \(shaderName) \(error.localizedDescription)")
                return nil
            }
            var vertex = UniformBuffer(layout: program.vertexLayout)
            var fragment = UniformBuffer(layout: program.fragmentLayout)
            func set(_ uniform: String, _ values: [Float]) {
                vertex.set(uniform, values)
                fragment.set(uniform, values)
            }
            let constants = (pass["constantshadervalues"] as? [String: Any] ?? [:]).mapValues(SceneValue.floats)
            for parameter in program.interface.parameters {
                set(parameter.uniform, constants[parameter.key] ?? parameter.defaultValue)
            }
            set("g_Color", [1, 1, 1])
            set("g_Color4", [1, 1, 1, 1])
            set("g_Alpha", [1])
            for (index, texture) in slots {
                let stored = SIMD2(Float(texture.texture.width), Float(texture.texture.height))
                let image = stored * texture.uvScale
                set("g_Texture\(index)Resolution", [stored.x, stored.y, image.x, image.y])
            }
            return MaterialDraw(program: program, textures: slots, vertexUniforms: vertex, fragmentUniforms: fragment)
        }

        /// 木偶网格：顶点位置经图层变换放到画布上，纹理坐标乘补齐比例。有骨骼和动画层时每帧蒙皮。
        ///
        /// 木偶图层上的特效作用在贴图（身体部件图集）上，而不是拼装后的画面：Lucy 的遮罩有大片涂抹落在
        /// 图层右侧 58% 的区域，而拼装后的网格根本不覆盖那里，只有图集的部件在那。所以和图片图层一样，
        /// 图集先经过特效链，再用网格画特效链的结果（结果没有补齐边距，纹理坐标不再乘补齐比例）。
        ///
        /// 链子在**图集自己的空间**里算（不是整屏的合成空间）：图集里部件的摆放和它在画面上的位置无关，
        /// 按屏幕位置摆进整屏缓冲的话，图层框伸出屏幕的那部分图集会被切掉——Lucy 的长发就在那里，
        /// 网格取到的只剩屏幕边缘被拉长的像素，头发变成几道灰色横条
        private mutating func makePuppetDraw(
            _ object: SceneDescription.Object, path: String, world: simd_float4x4, texture: LoadedTexture,
            color: SIMD4<Float>, blend: Blend, layerMode: Int32, scripted: ScriptedLayer?
        ) -> Draw? {
            let mesh: PuppetMesh
            do {
                guard let data = files.data(path) else { throw FormatError("找不到 \(path)") }
                mesh = try PuppetMesh(data: data)
            } catch {
                unsupported["木偶模型读不了", default: 0] += 1
                problems.append("\(object.name) 的木偶模型：\(error.localizedDescription)")
                return nil
            }
            var chain: EffectChain?
            if !object.effects.isEmpty {
                let quadSize = object.size ?? texture.imageSize
                let layerProjection = screenProjection.map {
                    $0 * world * simd_float4x4(diagonal: SIMD4(quadSize.x / 2, quadSize.y / 2, 1, 1))
                } ?? matrix_identity_float4x4
                chain = buildChain(
                    object, source: texture, size: bufferSize(image: texture.imageSize, quad: quadSize, world: world),
                    pixelSize: texture.imageSize, layerModel: world, layerProjection: layerProjection)
            }
            let uvScale = chain == nil ? texture.uvScale : SIMD2(1, 1)
            let vertices = mesh.vertices.map { vertex -> SIMD4<Float> in
                let position = world * SIMD4(vertex.position.x, vertex.position.y, vertex.position.z, 1)
                return SIMD4(position.x, position.y, vertex.uv.x * uvScale.x, vertex.uv.y * uvScale.y)
            }
            guard let vertexBuffer = context.device.makeBuffer(
                    bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride),
                  let indexBuffer = context.device.makeBuffer(
                    bytes: mesh.indices, length: mesh.indices.count * MemoryLayout<UInt16>.stride)
            else {
                problems.append("\(object.name)：无法创建木偶网格的缓冲")
                return nil
            }
            var animator: PuppetAnimator?
            if let problem = mesh.skeletonProblem {
                unsupported["木偶骨骼读不了（按静态姿势绘制）", default: 0] += 1
                problems.append("\(object.name) 的木偶骨骼：\(problem)")
            } else if !mesh.bones.isEmpty {
                var layers: [PuppetAnimator.Layer] = []
                for layer in object.animationLayers where layer.isVisible && layer.blend > 0 {
                    guard let animation = mesh.animations.first(where: { $0.id == layer.animation }) else {
                        problems.append("\(object.name)：动画层引用的动画 \(layer.animation) 不在模型里")
                        continue
                    }
                    layers.append(.init(
                        animation: animation, blend: layer.blend, rate: layer.rate, additive: layer.additive,
                        startOffset: layer.startProgress * animation.duration))
                }
                if !layers.isEmpty {
                    animator = PuppetAnimator(
                        mesh: mesh, layers: layers, world: world, uvScale: uvScale, device: context.device)
                }
            }
            return Draw(
                vertices: [], color: color, pipeline: PipelineKey(blend: blend, textured: true), texture: texture,
                blendMode: layerMode, chain: chain,
                mesh: MeshBuffers(
                    vertices: vertexBuffer, indices: indexBuffer, indexCount: mesh.indices.count, animator: animator),
                scripted: scripted, objectID: object.id)
        }

        // MARK: 声音

        /// 声音对象：读出声音文件，交给 SceneContent 播放（渲染器本身不出声）
        private mutating func collectSound(_ object: SceneDescription.Object) {
            guard let content = object.sound else { return }
            var loaded: [(path: String, data: Data)] = []
            for path in content.files {
                if let data = files.data(path) { loaded.append((path, data)) } else { problems.append("读不到声音文件 \(path)") }
            }
            guard !loaded.isEmpty else {
                unsupported["声音文件读不到", default: 0] += 1
                return
            }
            sounds.append(SceneSound(name: object.name, content: content, files: loaded))
        }

        // MARK: 合成层与图层结果

        /// 文字图层：内容可能是固定的字符串，也可能是脚本算出来的（时钟就是）。
        /// 文字画成一张贴图贴在图层框里，颜色和透明度交给图层自己的 color / alpha
        private mutating func makeTextDraw(_ object: SceneDescription.Object, scripted: ScriptedLayer?) -> Draw? {
            guard let content = object.textContent else { return nil }
            let world = state.bakeBuildWorld(object.id)
            let color = state.color(object.id)
            // 画布 → 屏幕的缩放乘上图层的缩放，就是文字最终画在屏幕上的像素大小
            let layerScale = max(
                simd_length(SIMD2(world.columns.0.x, world.columns.0.y)),
                simd_length(SIMD2(world.columns.1.x, world.columns.1.y)))
            guard let layer = TextLayer(
                files: files, content: content, canvasSize: scene.canvasSize ?? SIMD2(1920, 1080),
                layerScale: layerScale, canvasScale: screenScale ?? 1,
                device: context.device, userProperties: userProperties)
            else {
                unsupported["文字（字体读不了）", default: 0] += 1
                problems.append("\(object.name)：读不到字体 \(content.font)")
                return nil
            }
            if let problem = layer.problem {
                unsupported["文字脚本（显示编辑器里的静态文字）", default: 0] += 1
                problems.append("\(object.name)：\(problem)")
            }
            let layerMode = (1...32).contains(object.colorBlendMode) ? Int32(object.colorBlendMode) : 0
            let texture = layer.texture(at: 0)
            // 第一次画完才知道文字框要不要放大（字号调大时放不下），四边形按放大后的框摆
            let size = layer.boxSize
            // 文字框也按图层的对齐方式摆（对齐点落在原点上）
            let boxWorld = alignedWorld(object, quad: size)
            // 屏幕比例和画布比例不一样时，铺满裁切会把画布两侧（或上下）切掉，作者摆在角落的时钟
            // 正好会被切掉一半。文字的框整块挪进"屏幕上真正看得见的那块画布"里，其余画面照旧铺满
            let placed = visibleCanvasRegion.flatMap {
                SceneRenderer.placedInView(world: boxWorld, size: size, region: $0)
            }
            if let placed {
                state.setBuildWorld(object.id, placed)
                if ProcessInfo.processInfo.environment["SHOW_STATS"] != nil {
                    let offset = SIMD2(placed.columns.3.x - boxWorld.columns.3.x, placed.columns.3.y - boxWorld.columns.3.y)
                    print("  文字图层「\(object.name)」超出屏幕，挪回可见区域 \(offset.x.rounded()) \(offset.y.rounded())")
                }
            }
            let textWorld = placed ?? boxWorld
            var chain: EffectChain?
            var quadSize = size
            if !object.effects.isEmpty {
                // 文字图层上的特效作用在文字贴图上（Lucy 的时钟挂了一个 shine），在"文字框 + 四周留边"里算
                // （见 layerSpaceBufferSize）：文字贴图画在缓冲中间，留边给辉光铺开，画的时候整块按留边后的框摆
                let padded = size + SIMD2(repeating: content.padding * 2)
                let layerProjection = screenProjection.map {
                    $0 * textWorld * simd_float4x4(diagonal: SIMD4(padded.x / 2, padded.y / 2, 1, 1))
                } ?? matrix_identity_float4x4
                let inset = simd_float4x4(diagonal: SIMD4(size.x / padded.x, size.y / padded.y, 1, 1))
                buildingTextChain = true
                chain = buildChain(
                    object, source: texture ?? LoadedTexture(
                        texture: context.fallback, imageSize: size, uvScale: SIMD2(1, 1), clampsUVs: true,
                        usesNearestFiltering: false),
                    size: layerSpaceBufferSize(quad: padded, world: textWorld), pixelSize: padded,
                    layerModel: textWorld, layerProjection: layerProjection, inputProjection: inset)
                buildingTextChain = false
                // 时钟的文字每秒钟都可能变，特效链不能只算一次
                if layer.isDynamic { chain?.isStatic = false }
                if chain != nil { quadSize = padded }
            }
            return Draw(
                vertices: quad(world: textWorld, size: quadSize, uvScale: SIMD2(1, 1)),
                color: color,
                pipeline: PipelineKey(blend: layerMode != 0 ? .programmable : .translucent, textured: true),
                texture: chain?.output ?? texture, blendMode: layerMode, chain: chain, text: layer, scripted: scripted,
                objectID: object.id, colorIntoChain: chain != nil)
        }

        /// 形状图层（shape: "quad"）：本身没有贴图，特效在一块透明的区域上直接画（例如光束的 DIRECTDRAW）。
        /// 没写尺寸时按 128×128：WE 自带的光束预设场景画布 256×256，形状缩放约 2.04–2.09，刚好铺满
        private mutating func makeShapeDraw(_ object: SceneDescription.Object, scripted: ScriptedLayer?) -> Draw? {
            guard !object.effects.isEmpty else { return nil }
            let size = object.size ?? SIMD2(128, 128)
            let world = alignedWorld(object, quad: size)
            let source = LoadedTexture(
                texture: context.transparent, imageSize: size, uvScale: SIMD2(1, 1), clampsUVs: true,
                usesNearestFiltering: false)
            let layerProjection = screenProjection.map {
                $0 * world * simd_float4x4(diagonal: SIMD4(size.x / 2, size.y / 2, 1, 1))
            } ?? matrix_identity_float4x4
            // 形状本身就是特效画出来的东西（光束的那一束光），特效在形状自己的框里算，见 layerSpaceBufferSize
            guard let chain = buildChain(
                object, source: source, size: layerSpaceBufferSize(quad: size, world: world), pixelSize: size,
                layerModel: world, layerProjection: layerProjection)
            else { return nil }
            return Draw(
                vertices: quad(world: world, size: size, uvScale: SIMD2(1, 1)),
                color: state.color(object.id),
                pipeline: PipelineKey(blend: .translucent, textured: true), texture: source, blendMode: 0,
                chain: chain, scripted: scripted, objectID: object.id)
        }

        /// 合成层（composelayer）和全屏后处理层（fullscreenlayer）。WE 自带的 composelayer 着色器从
        /// _rt_FullFrameBuffer（到这里为止的画面）里按图层四边形在屏幕上的位置取样，填满图层自己的缓冲；
        /// 全屏层取整个画面。之后跑图层上的特效，结果按半透明混合画回原位。没有特效时什么也不做
        private mutating func makeComposeDraw(
            _ object: SceneDescription.Object, fullscreen: Bool, scripted: ScriptedLayer?
        ) -> Draw? {
            let canvas = scene.canvasSize ?? SIMD2(1920, 1080)
            let size = fullscreen ? canvas : (object.size ?? canvas)
            // 合成层也按对齐方式摆（3142391697 时钟两侧的音频条是右上 / 右下对齐的合成层）
            let layerWorld = fullscreen
                ? Self.translation(SIMD3(canvas.x / 2, canvas.y / 2, 0)) : alignedWorld(object, quad: size)
            // 输入先放一张占位纹理，绘制时换成画面的拷贝
            let placeholder = LoadedTexture(
                texture: context.fallback, imageSize: size, uvScale: SIMD2(1, 1), clampsUVs: true, usesNearestFiltering: false)
            let layerProjection = screenProjection.map {
                $0 * layerWorld * simd_float4x4(diagonal: SIMD4(size.x / 2, size.y / 2, 1, 1))
            } ?? matrix_identity_float4x4
            guard let chain = buildChain(
                object, source: placeholder, size: bufferSize(image: size, quad: size, world: layerWorld),
                pixelSize: size, layerModel: layerWorld, layerProjection: layerProjection)
            else { return nil }
            chain.isStatic = false
            let vertices = quad(world: layerWorld, size: size, uvScale: SIMD2(1, 1))
            // 特效链的结果按图层的混合模式合回画面，和图片图层一样。3142391697 时钟外的光环是
            // "相加"（31）：特效在光环以外输出黑色，按普通模式画的话整块黑（有声音时是灰）盖住时钟和音频条
            let layerMode = (1...32).contains(object.colorBlendMode) ? Int32(object.colorBlendMode) : 0
            return Draw(
                vertices: vertices, color: state.color(object.id),
                pipeline: PipelineKey(blend: layerMode != 0 ? .programmable : .translucent, textured: true),
                texture: placeholder, blendMode: layerMode,
                chain: chain, composeCorners: vertices.map { SIMD2($0.x, $0.y) },
                scripted: scripted,
                objectID: object.id)
        }

        /// 隐藏但被别的特效引用的图层：只算它的结果（贴图经过它自己的特效），不画
        private mutating func makeHiddenComposite(_ object: SceneDescription.Object, model modelPath: String) {
            guard let model = files.json(modelPath), let materialPath = model["material"] as? String,
                  let material = files.json(materialPath), let pass = (material["passes"] as? [[String: Any]])?.first,
                  let textureName = (pass["textures"] as? [Any])?.first as? String
            else {
                problems.append("被引用的隐藏图层 \(object.name) 读不到贴图")
                return
            }
            let world = worldTransform(object)
            let texture: LoadedTexture
            do {
                // 它的结果长边不超过 maxCompositeDimension，贴图也只要这么大
                texture = try textures.texture(
                    named: textureName,
                    fitting: onScreenFitting(quad: object.size, world: world, cap: Self.maxCompositeDimension))
            } catch {
                problems.append("\(object.name)：\(error.localizedDescription)")
                return
            }
            let quadSize = object.size ?? texture.imageSize
            if !object.effects.isEmpty, let chain = buildChain(
                object, source: texture,
                size: compositeSize(bufferSize(image: texture.imageSize, quad: quadSize, world: world)),
                pixelSize: texture.imageSize, layerModel: world, layerProjection: matrix_identity_float4x4) {
                chains.append(chain)
                composites[object.id] = chain.output
            } else {
                registerComposite(object, texture: texture, world: world)
            }
        }

        /// 被别的特效引用的图层结果的最长边。它们是被取样的贴图，不直接上屏，按自己在屏幕上的尺寸算会偏大
        /// （Lucy 里 4000×2000 的地球贴图按它自己的变换要 3819×1910，而合成层只按约 950 像素取样）
        static let maxCompositeDimension: Float = 2048

        private func compositeSize(_ size: SIMD2<Int>) -> SIMD2<Int> {
            Self.capped(size, longest: Self.maxCompositeDimension)
        }

        private static func capped(_ size: SIMD2<Int>, longest limit: Float) -> SIMD2<Int> {
            let longest = Float(max(size.x, size.y))
            guard longest > limit else { return size }
            let factor = limit / longest
            return SIMD2(max(1, Int(saturating: (Float(size.x) * factor).rounded())),
                         max(1, Int(saturating: (Float(size.y) * factor).rounded())))
        }

        /// 没有特效的图层：用一条空的特效链把贴图拷成没有补齐边距的纹理，别的特效按 0–1 取样才对得上
        private mutating func registerComposite(_ object: SceneDescription.Object, texture: LoadedTexture, world: simd_float4x4) {
            let size = compositeSize(bufferSize(image: texture.imageSize, quad: object.size ?? texture.imageSize, world: world))
            do {
                let chain = try EffectChain(
                    effects: [], source: texture, size: size, device: context.device, copyPipeline: context.copyPipeline,
                    fallback: context.fallback)
                chains.append(chain)
                composites[object.id] = chain.output
            } catch {
                problems.append("\(object.name)：\(error.localizedDescription)")
            }
        }

        // MARK: 粒子

        private mutating func makeParticleLayer(_ object: SceneDescription.Object, path: String) -> ParticleLayer? {
            let override = object.particleOverride ?? ParticleOverride()
            do {
                let root = try makeParticleNode(
                    path: path, override: override, transform: matrix_identity_float4x4, followsParent: false,
                    probability: 1, seed: UInt64(truncatingIfNeeded: object.id) &* 0x1000_0001, depth: 0)
                return try ParticleLayer(
                    root: root, world: particleWorld(object), override: override, device: context.device,
                    fallback: context.fallback)
            } catch {
                unsupported["粒子系统画不了", default: 0] += 1
                problems.append("粒子 \(object.name)（\(path)）：\(error.localizedDescription)")
                return nil
            }
        }

        /// 粒子系统的世界变换带上绕 x、y 轴的转角（编辑器里能把 2D 场景的粒子系统立体地转）：整个系统按
        /// Rz·Ry·Rx 转。精灵的四个角也是在系统自己的坐标里算的——WE 的 g_OrientationRight/Up/Forward 是世界坐标的轴
        ///（genericropeparticle.vert 要先乘 g_ModelMatrixInverse 才把 g_OrientationForward 换到系统坐标里），
        /// 所以精灵跟着系统一起转：转成侧面朝前（x 或 y 转 90°）的系统，每个粒子都压成一条线，整个看不见。
        /// 以前只认 z 轴转角，这样的系统（1457591167 的 Snow storm）画成了铺满屏幕的雾。
        /// 别的对象仍只认 z 轴转角（本机库里图层用到 x、y 转角的只有两个纯色层）
        private mutating func particleWorld(_ object: SceneDescription.Object) -> simd_float4x4 {
            let base = worldTransform(object)
            let tilt = SIMD2(object.angles.x, object.angles.y)
            guard tilt != .zero, tilt.x.isFinite, tilt.y.isFinite else { return base }
            // worldTransform = 父对象 × 平移 × Rz × 缩放；把 Ry·Rx 插在 Rz 和缩放之间
            let scale = Self.scaling(object.scale)
            return base * scale.inverse * Self.rotationY(tilt.y) * Self.rotationX(tilt.x) * scale
        }

        /// 一个粒子系统及其子系统。材质（2026-09-28 核对 38 个系统）都用 genericparticle 着色器，
        /// blending 为 additive 或 translucent；引擎按贴图和画法补上的开关：
        /// SPRITESHEET（精灵图）、THICKFORMAT（顶点带速度和寿命）、TRAILRENDERER（拖尾）、
        /// TEX0FORMAT（贴图的像素格式，R8/RG88 要换算）、SPRITESHEETBLENDNPOT（精灵图有补齐边距）。
        /// 折射粒子（REFRACT）用 3 号槽读"到这里为止的画面"，还要 1 号槽的法线图
        private mutating func makeParticleNode(
            path: String, override: ParticleOverride, transform: simd_float4x4, followsParent: Bool, probability: Float,
            seed: UInt64, depth: Int
        ) throws -> ParticleLayer.Node {
            guard let data = files.data(path) else { throw FormatError("找不到 \(path)") }
            let definition = try ParticleDefinition(json: data)
            guard let material = files.json(definition.material),
                  let pass = (material["passes"] as? [[String: Any]])?.first,
                  let shader = pass["shader"] as? String
            else { throw FormatError("读不到材质 \(definition.material)") }
            guard shader == "genericparticle" else { throw FormatError("粒子着色器 \(shader) 还不支持") }
            // 材质里的贴图按槽位取：0 号是反照率，折射粒子的 1 号是法线图
            var slotTextures: [Int: LoadedTexture] = [:]
            var slotNames: [Int: String] = [:]
            for (index, value) in (pass["textures"] as? [Any] ?? []).enumerated() {
                guard let name = value as? String, !name.isEmpty, !name.hasPrefix("_rt_") else { continue }
                do {
                    slotTextures[index] = try textures.texture(named: name)
                    slotNames[index] = name
                } catch {
                    if index == 0 { throw error }
                    problems.append("粒子 \(path) 的贴图 \(name)：\(error.localizedDescription)")
                }
            }
            guard let texture = slotTextures[0] else {
                throw FormatError("材质 \(definition.material) 没有贴图")
            }

            var combos = (pass["combos"] as? [String: Any] ?? [:]).compactMapValues { SceneValue.int($0) }

            // 画法
            var renderer = ParticleLayer.Renderer.sprite
            if let component = definition.renderers.first {
                switch component.name {
                case "sprite": break
                case "spritetrail":
                    renderer = .spriteTrail(
                        length: component.float("length", 0.05), maxLength: component.float("maxlength", 10),
                        minLength: component.float("minlength", 0))
                case "ropetrail":
                    renderer = .ropeTrail(
                        length: component.float("length", 0.5), segments: Int(component.float("segments", 0)),
                        subdivision: Int(component.float("subdivision", 0)), uvScale: component.float("uvscale", 1),
                        scrolling: component.float("uvscrolling", 0) != 0)
                case "rope":
                    renderer = .rope(
                        // WE 文档的演示视频里，rope 的拐角是圆的（几个粒子就能连成流畅的弧线），
                        // 所以 subdivision 的默认值取正数；`~/wp` 里显式写过的值是 0 和 3
                        subdivision: Int(component.float("subdivision", 3)), uvScale: component.float("uvscale", 1),
                        scrolling: component.float("uvscrolling", 0) != 0)
                default:
                    unsupported["粒子画法 \(component.name)（按精灵画）", default: 0] += 1
                }
            }

            // 精灵图：g_RenderVar1 = (帧宽, 帧高)（占整张纹理的比例）、帧数、单帧的高宽比
            let stored = SIMD2(Float(texture.texture.width), Float(texture.texture.height))
            let image = stored * texture.uvScale
            var frameCount = 0
            var renderVar1 = SIMD4<Float>(1, 1, 1, stored.y / stored.x)
            if let sheet = texture.spriteSheet, sheet.frames.count > 1, let first = sheet.frames.first,
               first.width > 0, first.height > 0 {
                frameCount = sheet.frames.count
                renderVar1 = SIMD4(first.width / stored.x, first.height / stored.y, Float(frameCount), first.height / first.width)
                combos["SPRITESHEET"] = 1
                if image != stored { combos["SPRITESHEETBLENDNPOT"] = 1 }
            }
            combos["THICKFORMAT"] = 1
            if case .spriteTrail = renderer { combos["TRAILRENDERER"] = 1 }
            combos["TEX0FORMAT"] = Int(texture.rawFormat)

            let blending: ProgramCache.Blending = switch pass["blending"] as? String {
            case "additive": .additive
            case "normal", "disabled": .none
            default: .translucent
            }
            let program = try context.programs.program(
                shader: shader, combos: combos, providedTextures: Set(slotTextures.keys), vertexFormat: .particle,
                blending: blending)

            var vertex = UniformBuffer(layout: program.vertexLayout)
            var fragment = UniformBuffer(layout: program.fragmentLayout)
            func set(_ uniform: String, _ values: [Float]) {
                vertex.set(uniform, values)
                fragment.set(uniform, values)
            }
            let constants = (pass["constantshadervalues"] as? [String: Any] ?? [:]).mapValues(SceneValue.floats)
            for parameter in program.interface.parameters {
                set(parameter.uniform, constants[parameter.key] ?? parameter.defaultValue)
            }
            // 正交的 2D 画面：粒子平铺在 xy 平面上，视线沿 -z；拖尾用"眼睛到粒子"的方向和速度叉乘求宽度方向，
            // 眼睛放在 z 很远处，求出来的宽度方向就在 xy 平面内
            set("g_OrientationRight", [1, 0, 0])
            set("g_OrientationUp", [0, 1, 0])
            set("g_OrientationForward", [0, 0, 1])
            set("g_ViewRight", [1, 0, 0])
            set("g_ViewUp", [0, 1, 0])
            set("g_EyePosition", [0, 0, 100_000])
            vertex.setMatrix("g_ModelMatrixInverse", matrix_identity_float4x4)
            if case .spriteTrail(let length, let maxLength, let minLength) = renderer {
                set("g_RenderVar0", [length, maxLength, minLength, 0])
            }
            set("g_RenderVar1", [renderVar1.x, renderVar1.y, renderVar1.z, renderVar1.w])
            set("g_Texture0Resolution", [stored.x, stored.y, image.x, image.y])

            let simulation = ParticleSimulation(
                definition: definition, override: override, seed: seed, trailLength: renderer.trailLength)
            for name in simulation.unsupported { unsupported["粒子\(name)（跳过）", default: 0] += 1 }
            particleSystems += 1
            let textureList = slotNames.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)\($0.key == 0 && frameCount > 1 ? "（\(frameCount) 帧）" : "")" }
                .joined(separator: " ")
            // 头文件里的参数在关掉对应开关时也会被读出来，只列出真的进了 uniform 块的那些
            let parameterList = program.interface.parameters.filter { parameter in
                program.vertexLayout.member(parameter.uniform) != nil
                    || program.fragmentLayout.member(parameter.uniform) != nil
            }.map { parameter -> String in
                let value = constants[parameter.key] ?? parameter.defaultValue
                return "\(parameter.key)=\(value.map { String(format: "%g", $0) }.joined(separator: " "))"
            }
            effectSummaries.append("粒子 \(path)：材质 \(definition.material) 贴图[\(textureList)] 混合 \(blending) 开关[\(program.defines.filter { $0.value != 0 }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))] 参数[\(parameterList.joined(separator: " "))]")

            var children: [ParticleLayer.Node] = []
            for (index, child) in definition.children.enumerated() where depth < 4 {
                let follows: Bool
                switch child.kind {
                case .static: follows = false
                case .eventFollow: follows = true
                default:
                    unsupported["粒子子系统 \(child.typeName)（跳过）", default: 0] += 1
                    continue
                }
                let childTransform = Self.translation(child.origin) * Self.rotationZ(child.angles.z) * Self.scaling(child.scale)
                do {
                    children.append(try makeParticleNode(
                        path: child.path, override: override, transform: childTransform, followsParent: follows,
                        probability: child.probability, seed: seed &+ UInt64(index + 1) &* 0x9E37_79B9, depth: depth + 1))
                } catch {
                    problems.append("粒子子系统 \(child.path)：\(error.localizedDescription)")
                }
            }

            return ParticleLayer.Node(
                name: path, simulation: simulation, program: program, vertexUniforms: vertex, fragmentUniforms: fragment,
                textures: slotTextures, transform: transform, followsParent: followsParent, probability: probability,
                frameCount: frameCount, randomFrame: definition.animationMode == "randomframe",
                sequenceMultiplier: definition.sequenceMultiplier, renderer: renderer, textureRatio: renderVar1.w,
                children: children)
        }

        // MARK: 特效

        /// 特效缓冲的尺寸：图像原尺寸，但不超过图层在屏幕上实际占的像素（保持宽高比，只缩小不放大）
        private func bufferSize(image: SIMD2<Float>, quad: SIMD2<Float>, world: simd_float4x4) -> SIMD2<Int> {
            Self.fittedSize(image: image, quad: quad, world: world, screenScale: screenScale)
        }

        /// 图像原尺寸，但不超过图层在屏幕上实际占的像素（保持宽高比，只缩小不放大）；
        /// 没有屏幕尺寸（离屏工具）时就是原尺寸
        static func fittedSize(
            image: SIMD2<Float>, quad: SIMD2<Float>, world: simd_float4x4, screenScale: Float?
        ) -> SIMD2<Int> {
            var size = image
            if let screenScale {
                let worldScale = SIMD2(simd_length(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z)),
                                       simd_length(SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z)))
                let onScreen = quad * worldScale * screenScale
                let factor = min(1, max(onScreen.x / image.x, onScreen.y / image.y))
                size = image * factor
            }
            // 不超过 Metal 纹理的上限（坏场景里的尺寸、缩放可能是任何数）
            return SIMD2(min(16384, max(1, Int(saturating: size.x.rounded()))),
                         min(16384, max(1, Int(saturating: size.y.rounded()))))
        }

        /// 给贴图加载用的"按屏幕尺寸够用就行"（quad 为 nil 时图层尺寸就是图像尺寸）
        private func onScreenFitting(
            quad: SIMD2<Float>?, world: simd_float4x4, cap: Float? = nil
        ) -> (SIMD2<Float>) -> SIMD2<Int> {
            let screenScale = screenScale
            return { image in
                let size = Self.fittedSize(image: image, quad: quad ?? image, world: world, screenScale: screenScale)
                return cap.map { Self.capped(size, longest: $0) } ?? size
            }
        }

        /// - Parameter pixelSize: 图层原本的像素尺寸（缓冲按屏幕缩小之前；顶点模式的特效按它挪顶点），
        ///   不给就是缓冲尺寸
        private mutating func buildChain(
            _ object: SceneDescription.Object, source: LoadedTexture, size: SIMD2<Int>, pixelSize: SIMD2<Float>? = nil,
            layerModel: simd_float4x4 = matrix_identity_float4x4, layerProjection: simd_float4x4,
            inputProjection: simd_float4x4 = matrix_identity_float4x4
        ) -> EffectChain? {
            let chainSize = SIMD2(Float(size.x), Float(size.y))
            let layerPixels = simd_max(pixelSize ?? chainSize, SIMD2(1, 1))
            var effects: [ChainEffect] = []
            usesCompositeInput = false
            for effect in object.effects where effect.isVisible {
                let name = effect.file.replacingOccurrences(of: "/effect.json", with: "")
                guard let definition = files.json(effect.file), let passes = definition["passes"] as? [[String: Any]] else {
                    problems.append("读不到特效 \(effect.file)")
                    continue
                }
                do {
                    effects.append(try makeEffect(
                        name: name, definition: definition, passes: passes, instance: effect, size: chainSize,
                        pixelSize: layerPixels, layerModel: layerModel, layerProjection: layerProjection))
                    renderedEffects += 1
                } catch {
                    unsupported["特效翻译失败 \(name)", default: 0] += 1
                    problems.append("特效 \(name)：\(error.localizedDescription)")
                }
            }
            guard !effects.isEmpty else { return nil }
            do {
                let chain = try EffectChain(
                    effects: effects, source: source, size: size, device: context.device,
                    copyPipeline: context.copyPipeline, fallback: context.fallback,
                    inputProjection: inputProjection)
                // 读别的图层结果的链跟着那些图层变，不能只算一次
                if usesCompositeInput { chain.isStatic = false }
                return chain
            } catch {
                problems.append("\(object.name)：\(error.localizedDescription)")
                return nil
            }
        }

        /// 一个特效实例。effect.json 的结构（2026-09-28 用真实文件核对）：
        /// - fbos：本特效的中间缓冲，scale 是分辨率的除数（2 为半分辨率）；
        /// - passes[]：material；target 为画到哪个缓冲（不写就是特效的输出）；
        ///   bind 为 [{name, index}]，把 "previous"（特效的输入）或某个缓冲接到 g_Texture{index}；
        ///   不写 bind 时 0 号槽接 previous；
        /// - 场景里特效实例的 passes[] 按顺序覆盖各通道的开关、贴图和参数
        private mutating func makeEffect(
            name: String, definition: [String: Any], passes: [[String: Any]], instance: SceneDescription.Effect,
            size: SIMD2<Float>, pixelSize: SIMD2<Float>, layerModel: simd_float4x4, layerProjection: simd_float4x4
        ) throws -> ChainEffect {
            var bufferIndex: [String: Int] = [:]
            var bufferSizes: [SIMD2<Float>] = []
            for fbo in definition["fbos"] as? [[String: Any]] ?? [] {
                guard let fboName = fbo["name"] as? String else { continue }
                let scale = max(1, SceneValue.float(fbo["scale"]) ?? 1)
                bufferIndex[fboName] = bufferSizes.count
                bufferSizes.append(simd_max(SIMD2(1, 1), (size / scale).rounded(.down)))
            }

            var steps: [EffectStep] = []
            // 老格式的 "compose": true：这个通道画进一张合成缓冲，后面的通道读的 previous 就是它
            //（WE 自带的折射先用它把背景合成进来，老版精确模糊的横向一遍也这么写）
            var composed: Int?
            for (index, pass) in passes.enumerated() {
                // 通道也可以是命令：{"command": "copy", "target": …, "source": …} —— 把源缓冲整块拷过去
                if let command = pass["command"] as? String {
                    guard command == "copy",
                          let targetName = pass["target"] as? String, let target = bufferIndex[targetName],
                          let sourceName = pass["source"] as? String
                    else { throw FormatError("第 \(index + 1) 个通道是还不认识的命令 \(command)") }
                    let binding: EffectTexture
                    if sourceName == "previous" {
                        binding = .previous
                    } else if let buffer = bufferIndex[sourceName] {
                        binding = .buffer(buffer)
                    } else {
                        throw FormatError("第 \(index + 1) 个通道命令引用了不认识的缓冲 \(sourceName)")
                    }
                    steps.append(EffectStep(
                        name: name, program: nil, textures: [:], bindings: [0: binding], frameBufferSlots: [],
                        includesBackground: false, target: target,
                        vertexUniforms: UniformBuffer(layout: UniformBlockLayout([])),
                        fragmentUniforms: UniformBuffer(layout: UniformBlockLayout([]))))
                    continue
                }
                var bindings: [Int: EffectTexture] = [:]
                if let binds = pass["bind"] as? [[String: Any]] {
                    for bind in binds {
                        guard let slot = (bind["index"] as? NSNumber)?.intValue, let source = bind["name"] as? String else { continue }
                        if source == "previous" {
                            bindings[slot] = composed.map { .buffer($0) } ?? .previous
                        } else if let buffer = bufferIndex[source] {
                            bindings[slot] = .buffer(buffer)
                        } else {
                            throw FormatError("第 \(index + 1) 个通道绑定了不认识的缓冲 \(source)")
                        }
                    }
                } else {
                    bindings[0] = composed.map { .buffer($0) } ?? .previous
                }
                var target: Int?
                if let targetName = pass["target"] as? String {
                    guard let buffer = bufferIndex[targetName] else {
                        throw FormatError("第 \(index + 1) 个通道要画到不认识的缓冲 \(targetName)")
                    }
                    target = buffer
                } else if (pass["compose"] as? Bool) == true, index < passes.count - 1 {
                    target = bufferSizes.count
                    bufferSizes.append(size)
                    composed = target
                }
                let boundSizes = bindings.mapValues { binding -> SIMD2<Float> in
                    switch binding {
                    case .previous: return size
                    case .buffer(let buffer): return bufferSizes[buffer]
                    }
                }
                steps.append(try makeStep(
                    effect: name, pass: pass, override: index < instance.passes.count ? instance.passes[index] : nil,
                    bindings: bindings, target: target, boundSizes: boundSizes,
                    targetSize: target.map { bufferSizes[$0] } ?? size, pixelSize: pixelSize,
                    layerModel: layerModel, layerProjection: layerProjection))
            }
            let buffers = try bufferSizes.map {
                try EffectChain.makeBuffer(device: context.device, size: SIMD2(Int($0.x), Int($0.y)))
            }
            return ChainEffect(name: name, steps: steps, buffers: buffers)
        }

        /// 一个特效通道：取材质，合并开关和贴图（场景覆盖 → 材质 → 着色器注释里的默认值），
        /// 翻译着色器，预先写好不随时间变化的 uniform
        private mutating func makeStep(
            effect: String, pass: [String: Any], override: SceneDescription.Effect.PassOverride?,
            bindings: [Int: EffectTexture], target: Int?, boundSizes: [Int: SIMD2<Float>], targetSize: SIMD2<Float>,
            pixelSize: SIMD2<Float>, layerModel: simd_float4x4, layerProjection: simd_float4x4
        ) throws -> EffectStep {
            guard let materialPath = pass["material"] as? String, let material = files.json(materialPath),
                  let materialPass = (material["passes"] as? [[String: Any]])?.first,
                  let shader = materialPass["shader"] as? String
            else { throw FormatError("读不到特效的材质") }

            var combos = (materialPass["combos"] as? [String: Any] ?? [:]).compactMapValues { SceneValue.int($0) }
            combos.merge(override?.combos ?? [:]) { $1 }
            var explicitTextures: [Int: String] = [:]
            for (index, name) in (materialPass["textures"] as? [Any] ?? []).enumerated() {
                if let name = name as? String { explicitTextures[index] = name }
            }
            for (index, name) in (override?.textures ?? []).enumerated() {
                if let name { explicitTextures[index] = name }
            }
            // 接了运行时纹理的槽不再用素材贴图
            for slot in bindings.keys { explicitTextures[slot] = nil }
            let program = try context.programs.program(
                shader: shader, combos: combos, providedTextures: Set(explicitTextures.keys).union(bindings.keys))

            var slots: [Int: LoadedTexture] = [:]
            for slot in program.interface.textures where bindings[slot.index] == nil {
                if let name = explicitTextures[slot.index], let layer = Self.compositeLayerID(name) {
                    if let composite = composites[layer] {
                        slots[slot.index] = composite
                        usesCompositeInput = true
                    } else if let composite = buildComposite(onDemand: layer) {
                        // 引用的图层排在后面：先把它算出来（WE 允许这种顺序）
                        slots[slot.index] = composite
                        usesCompositeInput = true
                    } else {
                        problems.append("特效 \(effect) 引用的图层 \(layer) 算不出来")
                    }
                    continue
                }
                guard let name = explicitTextures[slot.index] ?? slot.defaultTexture, !name.hasPrefix("_rt_") else { continue }
                do {
                    slots[slot.index] = try textures.texture(named: name)
                } catch {
                    problems.append("特效 \(effect) 的贴图 \(name)：\(error.localizedDescription)")
                }
            }

            var vertex = UniformBuffer(layout: program.vertexLayout)
            var fragment = UniformBuffer(layout: program.fragmentLayout)
            func set(_ uniform: String, _ values: [Float]) {
                vertex.set(uniform, values)
                fragment.set(uniform, values)
            }
            func setMatrix(_ uniform: String, _ matrix: simd_float4x4) {
                vertex.setMatrix(uniform, matrix)
                fragment.setMatrix(uniform, matrix)
            }
            let materialConstants = (materialPass["constantshadervalues"] as? [String: Any] ?? [:]).mapValues(SceneValue.floats)
            for parameter in program.interface.parameters {
                set(parameter.uniform, override?.constants[parameter.key] ?? materialConstants[parameter.key] ?? parameter.defaultValue)
            }
            if buildingTextChain,
               let intensity = program.interface.parameters.first(where: { $0.uniform == "g_Intensity" }),
               program.interface.parameters.contains(where: { $0.uniform == "g_Length" }) {
                let value = override?.constants[intensity.key] ?? materialConstants[intensity.key] ?? intensity.defaultValue
                set("g_Intensity", value.map { $0 * Self.textGlowCalibration })
            }

            // 内置 uniform。特效通道画的是铺满缓冲的四边形。画到特效输出的通道（没有 target）：四边形用图层像素
            // 坐标（中心为原点、y 朝上），模型视图投影矩阵把它变成裁剪坐标——WE 的顶点模式特效（植物摇摆、倾斜、
            // 透视的 Vertex 模式）按像素挪顶点，以前四边形是裁剪坐标（−1…1），挪 100 像素就成了挪 50 个画面宽，
            // 整张图跟着大幅摆动。画到中间缓冲的通道用裁剪坐标的四边形、单位矩阵：WE 自带的这类通道直接写
            // gl_Position = vec4(a_Position, 1.0)；画到特效输出、却也这么写的着色器（不读这个矩阵）同样给裁剪坐标。
            // 两种画出来的范围一样，不挪顶点的特效结果不变
            let usesPixelQuad = target == nil && program.readsModelViewProjection
            let pixelToClip = usesPixelQuad
                ? simd_float4x4(diagonal: SIMD4(2 / pixelSize.x, 2 / pixelSize.y, 1, 1)) : matrix_identity_float4x4
            setMatrix("g_ModelViewProjectionMatrix", pixelToClip)
            setMatrix("g_ViewProjectionMatrix", pixelToClip)
            setMatrix("g_ModelMatrix", matrix_identity_float4x4)
            // 图层自己的世界变换（画布坐标）：有的工作坊特效从它的前两列取图层的缩放（rounded_mask 的"防变形"）
            setMatrix("g_LayerModelMatrix", layerModel)
            // 特效纹理投影矩阵是"图层自身坐标 → 屏幕裁剪坐标"
            setMatrix("g_EffectTextureProjectionMatrix", layerProjection)
            setMatrix("g_EffectTextureProjectionMatrixInverse", layerProjection.inverse)
            // 特效通道的四边形 → 这个像素在屏幕上的裁剪坐标。"复制背景"（shine / godrays 的 COPYBG）
            // 靠它算出屏幕坐标，去 `_rt_FullFrameBuffer` 里取图层底下的画面；以前没设，是全零矩阵
            setMatrix("g_EffectModelViewProjectionMatrix", layerProjection * pixelToClip)
            // g_TextureNResolution = (纹理宽, 纹理高, 图像宽, 图像高)；运行时纹理没有补齐，两组相同
            for (slot, size) in boundSizes {
                set("g_Texture\(slot)Resolution", [size.x, size.y, size.x, size.y])
            }
            for (index, texture) in slots {
                let stored = SIMD2(Float(texture.texture.width), Float(texture.texture.height))
                let image = stored * texture.uvScale
                set("g_Texture\(index)Resolution", [stored.x, stored.y, image.x, image.y])
            }
            let inputSize = boundSizes[0] ?? targetSize
            set("g_TexelSize", [1 / inputSize.x, 1 / inputSize.y])
            // 缓冲按屏幕缩小过时是"缩小前的像素 / 缓冲的像素"：倾斜的 Vertex 模式拿 g_Texture0Resolution 乘它换回
            // 顶点坐标用的像素（以前没设，是 0，倾斜的 Vertex 模式不动）
            set("g_TextureReductionScale", [pixelSize.x / max(inputSize.x, 1)])
            // WE 自带的 xray 用 g_ModelViewProjectionMatrixInverse 把屏幕上的鼠标位置反投影成"图层贴图的像素坐标"
            // （以图层中心为原点、y 朝上，再除以 g_Texture0Resolution 得到 −0.5…0.5；着色器里 texCoord − 它，
            // 鼠标处正好是 0.5）：它是"图层像素 → 屏幕裁剪坐标"的逆。以前没设（全零矩阵），X-ray 的洞出不来
            let pixelToLayer = simd_float4x4(diagonal: SIMD4(2 / max(inputSize.x, 1), 2 / max(inputSize.y, 1), 1, 1))
            setMatrix("g_ModelViewProjectionMatrixInverse", (layerProjection * pixelToLayer).inverse)
            set("g_Color4", [1, 1, 1, 1])
            set("g_Color", [1, 1, 1])
            set("g_Alpha", [1])
            set("g_Texture0Rotation", [1, 0, 0, 1])
            set("g_Texture0Translation", [0, 0])
            let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            set("g_Daytime", [Float((now.hour ?? 0) * 3600 + (now.minute ?? 0) * 60 + (now.second ?? 0)) / 86400])

            let slotNames = program.interface.textures.map { slot -> String in
                switch bindings[slot.index] {
                case .previous: return "\(slot.index)=上一步"
                case .buffer(let buffer): return "\(slot.index)=缓冲\(buffer)"
                case nil:
                    return "\(slot.index)=\(slots[slot.index] == nil ? "无" : (explicitTextures[slot.index] ?? slot.defaultTexture ?? "?"))"
                }
            }
            let parameters = program.interface.parameters.map { parameter in
                let value = override?.constants[parameter.key] ?? materialConstants[parameter.key] ?? parameter.defaultValue
                return "\(parameter.key)=\(value.map { String(format: "%g", $0) }.joined(separator: " "))"
            }
            effectSummaries.append("\(effect)：\(shader) 开关[\(program.defines.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))] 贴图[\(slotNames.joined(separator: " "))] 参数[\(parameters.joined(separator: " "))]")
            return EffectStep(
                name: effect, program: program, textures: slots, bindings: bindings,
                // 贴图槽的默认值指向"到这里为止的画面"时要走运行时拷贝（"复制背景"的辉光类特效）
                frameBufferSlots: Set(
                    program.interface.textures
                        .filter { $0.defaultTexture == "_rt_FullFrameBuffer" }.map(\.index)),
                includesBackground: (program.defines["COPYBG"] ?? 0) != 0,
                target: target,
                vertexUniforms: vertex, fragmentUniforms: fragment,
                quad: usesPixelQuad ? EffectChain.pixelQuad(size: pixelSize) : EffectChain.clipQuad)
        }

        /// 以对象原点为中心、给定尺寸的矩形；顶边对应纹理第一行（v = 0）
        private func quad(world: simd_float4x4, size: SIMD2<Float>, uvScale: SIMD2<Float>) -> [SIMD4<Float>] {
            let half = size / 2
            let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
                (SIMD2(-half.x, -half.y), SIMD2(0, uvScale.y)),
                (SIMD2(half.x, -half.y), SIMD2(uvScale.x, uvScale.y)),
                (SIMD2(-half.x, half.y), SIMD2(0, 0)),
                (SIMD2(half.x, half.y), SIMD2(uvScale.x, 0)),
            ]
            return corners.map { position, uv in
                let transformed = world * SIMD4(position.x, position.y, 0, 1)
                return SIMD4(transformed.x, transformed.y, uv.x, uv.y)
            }
        }

        private func isVisible(_ object: SceneDescription.Object) -> Bool {
            var current: SceneDescription.Object? = object
            var depth = 0
            while let node = current, depth < 64 {
                if !node.isVisible { return false }
                current = node.parent.flatMap { byID[$0] }
                depth += 1
            }
            return true
        }

        /// 世界变换 = 父对象的世界变换 × 平移(origin) × 绕 z 旋转(angles.z) × 缩放(scale)
        private mutating func worldTransform(_ object: SceneDescription.Object, depth: Int = 0) -> simd_float4x4 {
            if let cached = worldCache[object.id] { return cached }
            // 自己或祖先挂在木偶挂点上：挂点的变换在运行时状态里（见 prepareAttachments）
            if !attachmentLinks.isEmpty, isAttached(object) {
                let world = state.world(object.id)
                worldCache[object.id] = world
                return world
            }
            let local = Self.translation(object.origin) * Self.rotationZ(object.angles.z) * Self.scaling(object.scale)
            var world = local
            if depth < 64, let parentID = object.parent, parentID != object.id, let parent = byID[parentID] {
                world = worldTransform(parent, depth: depth + 1) * local
            }
            worldCache[object.id] = world
            return world
        }

        /// 自己或某个祖先挂在木偶挂点上
        private func isAttached(_ object: SceneDescription.Object) -> Bool {
            var current: SceneDescription.Object? = object
            var depth = 0
            while let node = current, depth < 64 {
                if attachmentLinks.contains(where: { $0.child == node.id }) { return true }
                current = node.parent.flatMap { byID[$0] }
                depth += 1
            }
            return false
        }

        /// scene.json 里写了 `attachment` 的图层：在父图层的木偶模型里按名字找挂点（MDAT 段），
        /// 按绑定姿势登记进运行时状态；父木偶有动画时渲染器每帧再按当前骨骼更新
        private mutating func prepareAttachments() {
            var meshes: [String: PuppetMesh] = [:]
            for object in scene.objects {
                guard let name = object.attachment, let parentID = object.parent, parentID != object.id,
                      let parent = byID[parentID], case .image(let modelPath) = parent.kind,
                      let model = files.json(modelPath), let puppetPath = model["puppet"] as? String
                else { continue }
                if meshes[puppetPath] == nil, let data = files.data(puppetPath) {
                    meshes[puppetPath] = try? PuppetMesh(data: data)
                }
                guard let mesh = meshes[puppetPath], let attachment = mesh.attachment(named: name) else {
                    problems.append("\(object.name)：父模型里没有挂点「\(name)」，按父图层中心摆放")
                    continue
                }
                let bind = mesh.bindWorlds
                guard attachment.bone < bind.count else { continue }
                state.setAttachment(object.id, bind[attachment.bone] * attachment.matrix, isBuild: true)
                attachmentLinks.append(AttachmentLink(
                    child: object.id, parent: parentID, bone: attachment.bone, offset: attachment.matrix))
            }
            if !attachmentLinks.isEmpty { worldCache.removeAll() }
        }

        private static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
            var matrix = matrix_identity_float4x4
            matrix.columns.3 = SIMD4(offset.x, offset.y, offset.z, 1)
            return matrix
        }

        private static func rotationZ(_ angle: Float) -> simd_float4x4 {
            let c = cos(angle)
            let s = sin(angle)
            return simd_float4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        }

        private static func rotationX(_ angle: Float) -> simd_float4x4 {
            let c = cos(angle)
            let s = sin(angle)
            return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
        }

        private static func rotationY(_ angle: Float) -> simd_float4x4 {
            let c = cos(angle)
            let s = sin(angle)
            return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
        }

        private static func scaling(_ scale: SIMD3<Float>) -> simd_float4x4 {
            simd_float4x4(diagonal: SIMD4(
                SceneState.safeScale(scale.x), SceneState.safeScale(scale.y), SceneState.safeScale(scale.z), 1))
        }
    }
}

/// 合成层用的"到这里为止的画面"拷贝，按目标尺寸复用
private final class FrameCopy: @unchecked Sendable {
    private var texture: (any MTLTexture)?
    private var flippedTexture: (any MTLTexture)?
    private var sampler: (any MTLSamplerState)?
    private let lock = NSLock()

    func copy(
        of target: any MTLTexture, device: any MTLDevice, commandBuffer: any MTLCommandBuffer
    ) -> (any MTLTexture)? {
        lock.lock()
        defer { lock.unlock() }
        if texture?.width != target.width || texture?.height != target.height || texture?.pixelFormat != target.pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: target.pixelFormat, width: target.width, height: target.height, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture, let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, to: texture)
        blit.endEncoding()
        return texture
    }

    /// 上下翻转的一份拷贝：第 0 行放的是画面的底部。
    ///
    /// 折射粒子的着色器按 GL 习惯算屏幕坐标（裁剪坐标 y 向上，纹理坐标 v = 0 在底部），
    /// 而 Metal 的纹理第 0 行在顶部；把画面翻过来，WE 的 `v_ScreenCoord` 数学不用改就能对上。
    func flippedCopy(
        of target: any MTLTexture, device: any MTLDevice, commandBuffer: any MTLCommandBuffer,
        pipeline: any MTLRenderPipelineState
    ) -> (any MTLTexture)? {
        lock.lock()
        defer { lock.unlock() }
        if flippedTexture?.width != target.width || flippedTexture?.height != target.height
            || flippedTexture?.pixelFormat != target.pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: target.pixelFormat, width: target.width, height: target.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            flippedTexture = device.makeTexture(descriptor: descriptor)
        }
        if sampler == nil {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: descriptor)
        }
        guard let copy = flippedTexture, let sampler else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = copy
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        // 顶点按照画到目标上的位置给纹理坐标：裁剪坐标 y = -1（目标最后一行）读画面顶部那一行
        let vertices: [SIMD4<Float>] = [
            SIMD4(-1, -1, 0, 0), SIMD4(1, -1, 1, 0),
            SIMD4(-1, 1, 0, 1), SIMD4(1, 1, 1, 1),
        ]
        var uniforms = LayerUniformValues(projection: matrix_identity_float4x4, color: SIMD4(1, 1, 1, 1), mode: .zero)
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniformValues>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniformValues>.stride, index: 1)
        encoder.setFragmentTexture(target, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return copy
    }
}
