import Foundation
import Metal
import ShaderCompiler
import simd
import WallpaperFormats

/// 场景里的一个粒子对象：CPU 模拟（`ParticleSimulation`）+ 用 WE 自己的 genericparticle 着色器绘制。
///
/// 每个粒子画成一个四边形。四个角共用粒子的数据，只有角的纹理坐标不同；着色器按
/// 粒子大小、旋转（或拖尾时的速度方向）把角展开，这和 genericparticle.vert 里
/// 不用几何着色器的那条路径一致（GS_ENABLED 为 0）。每个顶点的数据：
///
///     a_Position        3f  粒子位置（系统坐标）
///     a_TexCoordVec4    4f  角的纹理坐标 uv、绕 z 的旋转、大小
///     a_Color           4f  颜色和透明度
///     a_TexCoordC2      2f  绕 x、y 的旋转
///     a_TexCoordVec4C1  4f  速度（拖尾方向）、精灵图选帧用的寿命值（THICKFORMAT）
///
/// 子系统：static 的作为独立的系统一起模拟和绘制；eventfollow 的在每个新出生的父粒子上发射，
/// 粒子位置相对于父粒子。
final class ParticleLayer {
    static let floatsPerVertex = 17

    /// 画法（WE 的 renderer 组件）：
    /// - sprite：普通精灵；
    /// - spritetrail：拉长的精灵，长度 = 速度 × length，限制在 [minLength, maxLength]，再乘粒子大小；
    /// - rope：把先后出生的粒子连成一条带子（WE 的 Rope Renderer）；
    /// - ropeTrail：沿每个粒子走过的路径画带子（WE 的 Rope Trail Renderer），需要位置历史。
    enum Renderer: Equatable {
        case sprite
        case spriteTrail(length: Float, maxLength: Float, minLength: Float)
        case rope(subdivision: Int, uvScale: Float, scrolling: Bool)
        case ropeTrail(length: Float, segments: Int, subdivision: Int, uvScale: Float, scrolling: Bool)

        /// 只有 spritetrail 用 genericparticle 的 TRAILRENDERER 分支
        var isSpriteTrail: Bool {
            if case .spriteTrail = self { return true }
            return false
        }

        /// 需要记录的位置历史时长（秒）
        var trailLength: Float {
            if case .ropeTrail(let length, _, _, _, _) = self { return length }
            return 0
        }

        /// 带子画法（rope / ropeTrail）；u 是横向、v 沿带子
        var isRope: Bool { ribbon != nil }

        var ribbon: (subdivision: Int, uvScale: Float, scrolling: Bool, segments: Int)? {
            switch self {
            case .sprite, .spriteTrail:
                return nil
            case .rope(let subdivision, let uvScale, let scrolling):
                return (subdivision, uvScale, scrolling, 0)
            case .ropeTrail(_, let segments, let subdivision, let uvScale, let scrolling):
                return (subdivision, uvScale, scrolling, segments)
            }
        }
    }

    final class Node {
        let name: String
        let simulation: ParticleSimulation
        let program: CompiledProgram
        let vertexUniforms: UniformBuffer
        let fragmentUniforms: UniformBuffer
        /// 材质里的贴图，按槽位；0 号是反照率，折射粒子的 1 号是法线图
        let textures: [Int: LoadedTexture]
        /// 相对于父系统（根系统是相对于对象）的变换
        let transform: simd_float4x4
        let followsParent: Bool
        let probability: Float
        let frameCount: Int
        let randomFrame: Bool
        let sequenceMultiplier: Float
        let renderer: Renderer
        /// 粒子的高宽比（精灵图按单帧算）
        let textureRatio: Float
        let children: [Node]
        /// 顶点缓冲按帧轮换：屏幕上最多两帧在飞，留 4 份避免改写 GPU 还在读的那一份
        fileprivate var buffers = [(any MTLBuffer)?](repeating: nil, count: ParticleLayer.bufferCount)
        fileprivate var indexBuffer: (any MTLBuffer)?
        fileprivate var indexCapacity = 0
        /// 带子（rope / ropeTrail）的顶点和索引缓冲：份数和顶点缓冲一致（按 frameIndex 轮换）
        fileprivate var ribbonBuffers = [(any MTLBuffer)?](repeating: nil, count: ParticleLayer.bufferCount)
        /// 带子的索引随带子的条数和长度每帧都变，也要轮换（GPU 可能还在画上一帧）
        fileprivate var ribbonIndexBuffers = [(any MTLBuffer)?](repeating: nil, count: ParticleLayer.bufferCount)

        init(
            name: String, simulation: ParticleSimulation, program: CompiledProgram, vertexUniforms: UniformBuffer,
            fragmentUniforms: UniformBuffer, textures: [Int: LoadedTexture], transform: simd_float4x4, followsParent: Bool,
            probability: Float, frameCount: Int, randomFrame: Bool, sequenceMultiplier: Float, renderer: Renderer,
            textureRatio: Float, children: [Node]
        ) {
            self.name = name
            self.simulation = simulation
            self.program = program
            self.vertexUniforms = vertexUniforms
            self.fragmentUniforms = fragmentUniforms
            self.textures = textures
            self.transform = transform
            self.followsParent = followsParent
            self.probability = probability
            self.frameCount = frameCount
            self.randomFrame = randomFrame
            self.sequenceMultiplier = sequenceMultiplier
            self.renderer = renderer
            self.textureRatio = textureRatio
            self.children = children
        }
    }

    let root: Node
    /// 有控制点跟着鼠标走（含子系统）
    var followsPointer: Bool {
        func follows(_ node: Node) -> Bool {
            node.simulation.controlPointFollowsPointer.contains(true) || node.children.contains(where: follows)
        }
        return follows(root)
    }
    /// 粒子对象的世界变换（系统坐标 → 画布坐标）
    let world: simd_float4x4
    let override: ParticleOverride
    private let device: any MTLDevice
    private let sampler: any MTLSamplerState
    /// 带子专用：沿带子的纹理坐标会超出 0–1，WE 文档也要求这类贴图"关掉 clamp"才能重复
    private let ribbonSampler: any MTLSamplerState
    /// 材质没提供的贴图槽绑定的 1×1 黑色纹理（折射粒子没给法线图时也会声明 1 号槽）
    private let fallback: any MTLTexture
    private let lock = NSLock()
    /// 已经模拟到的时间（含预模拟）；nil 表示还没开始
    private var simulatedTo: Float?
    private var frameIndex = 0

    /// 每一步最长的模拟时间。预模拟很长时（有的系统 starttime 是 200 秒）步长放大，总步数不超过上限
    static let stepDuration: Float = 1 / 30
    static let maxPresimulationSteps = 900
    static let maxStepsPerFrame = 60
    /// 时间往回跳多少以内算"抖动"而不是"重来"（秒）
    static let resetTolerance: Float = 0.5

    init(
        root: Node, world: simd_float4x4, override: ParticleOverride, device: any MTLDevice,
        fallback: any MTLTexture
    ) throws {
        self.root = root
        self.world = world
        self.override = override
        self.device = device
        self.fallback = fallback
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { throw FormatError("无法创建采样器") }
        self.sampler = sampler
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        guard let ribbonSampler = device.makeSamplerState(descriptor: descriptor) else {
            throw FormatError("无法创建采样器")
        }
        self.ribbonSampler = ribbonSampler
    }

    /// 预模拟的时长：根系统和 static 子系统里最长的 starttime
    var presimulation: Float {
        func longest(_ node: Node) -> Float {
            node.children.filter { !$0.followsParent }.map(longest).reduce(node.simulation.startTime, max)
        }
        return longest(root)
    }

    /// 有折射粒子时为 true：绘制前要把"到这里为止的画面"拷一份给着色器取样（`_rt_FullFrameBuffer`）
    var needsScreenCopy: Bool {
        func check(_ node: Node) -> Bool {
            (node.program.defines["REFRACT"] ?? 0) != 0 || node.children.contains(where: check)
        }
        return check(root)
    }

    /// 当前活着的粒子数（含子系统）
    var particleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        func count(_ node: Node) -> Int { node.children.map(count).reduce(node.simulation.particles.count, +) }
        return count(root)
    }

    // MARK: - 模拟

    /// 模拟到场景时间 time。时间倒退（例如场景时间每小时回绕一次）就从头预模拟
    func advance(to time: Float, pointer: SIMD2<Float>?) {
        let target = presimulation + max(0, time) * override.rate
        if let simulatedTo, target >= simulatedTo - 0.0001 {
            run(from: simulatedTo, to: target, maxSteps: Self.maxStepsPerFrame, pointer: pointer)
        } else if let simulated = simulatedTo, simulated - target < Self.resetTolerance {
            // 时间只倒退了一点点（显示链路抖动、帧时间的小修正）：停在这一帧，
            // 别整段重来——重来会让画面上所有粒子"闪一下"
            return
        } else {
            reset(root)
            let warmup = presimulation
            run(from: 0, to: warmup, maxSteps: Self.maxPresimulationSteps, pointer: nil)
            run(from: warmup, to: target, maxSteps: Self.maxPresimulationSteps, pointer: pointer)
        }
        simulatedTo = target
    }

    private func reset(_ node: Node) {
        node.simulation.reset()
        node.children.forEach(reset)
    }

    private func run(from start: Float, to end: Float, maxSteps: Int, pointer: SIMD2<Float>?) {
        let span = end - start
        guard span > 0 else { return }
        let steps = min(maxSteps, max(1, Int((span / Self.stepDuration).rounded(.up))))
        let dt = span / Float(steps)
        for _ in 0..<steps { step(root, dt: dt, transform: world * root.transform, pointer: pointer) }
    }

    private func step(
        _ node: Node, dt: Float, transform: simd_float4x4, pointer: SIMD2<Float>?,
        anchors: [UInt32: SIMD3<Float>]? = nil, newAnchors: [UInt32] = []
    ) {
        let simulation = node.simulation
        simulation.step(
            dt, controlPoints: controlPoints(simulation, transform: transform, pointer: pointer),
            anchors: anchors, newAnchors: newAnchors)
        guard !node.children.isEmpty else { return }
        var ownPositions: [UInt32: SIMD3<Float>]?
        for child in node.children {
            let childTransform = transform * child.transform
            if child.followsParent {
                if ownPositions == nil {
                    ownPositions = Dictionary(uniqueKeysWithValues: simulation.particles.map { particle in
                        (particle.id, basePosition(particle, anchors: anchors))
                    })
                }
                // 按概率决定哪些新粒子带子系统；用编号算，不消耗随机数
                let born = simulation.bornThisStep.filter { ParticleRandom.hash($0, 0x5eed) < child.probability }
                step(child, dt: dt, transform: childTransform, pointer: pointer, anchors: ownPositions, newAnchors: born)
            } else {
                step(child, dt: dt, transform: childTransform, pointer: pointer)
            }
        }
    }

    /// 粒子在它所属系统坐标里的位置（跟随父粒子的要加上父粒子的位置）
    private func basePosition(_ particle: ParticleSimulation.Particle, anchors: [UInt32: SIMD3<Float>]?) -> SIMD3<Float> {
        var position = particle.position + particle.drawnOffset
        if let anchor = particle.anchor, let base = anchors?[anchor] { position += base }
        return position
    }

    /// 8 个控制点在系统坐标里的位置：跟随鼠标 > 场景的实例覆盖 > 定义里的偏移。
    /// 实例覆盖的坐标是系统自己的坐标（未缩放），不是画布坐标：WE 自带的预览场景画布 256×256、
    /// 系统缩放 0.24–0.42，覆盖值却是 ±388、436 这样的数，按系统坐标换算后正好落在画布里
    private func controlPoints(
        _ simulation: ParticleSimulation, transform: simd_float4x4, pointer: SIMD2<Float>?
    ) -> [SIMD3<Float>] {
        let inverse = pointer != nil && simulation.controlPointFollowsPointer.contains(true)
            ? transform.inverse : matrix_identity_float4x4
        return (0..<8).map { index in
            if simulation.controlPointFollowsPointer[index], let pointer {
                let point = inverse * SIMD4(pointer.x, pointer.y, 0, 1)
                return SIMD3(point.x, point.y, 0) + simulation.controlPointOffsets[index]
            }
            return override.controlPoints[index] ?? simulation.controlPointOffsets[index]
        }
    }

    // MARK: - 绘制

    /// - Parameters:
    ///   - projection: 画布坐标 → 裁剪空间
    ///   - pointer: 鼠标在画布坐标里的位置；nil 表示不跟随鼠标
    ///   - screenCopy: 折射粒子用的"到这里为止的画面"拷贝（WE 的 `_rt_FullFrameBuffer`）。
    ///     内容是上下翻转的，好让着色器按 GL 习惯算出的屏幕坐标（v = 0 在画面底部）直接对上
    func encode(
        into encoder: any MTLRenderCommandEncoder, projection: simd_float4x4, time: Float, pointer: SIMD2<Float>?,
        screenCopy: (any MTLTexture)? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        advance(to: time, pointer: pointer)
        frameIndex = (frameIndex + 1) % Self.bufferCount
        // 粒子的 z 各不相同（球形发射器会往 z 方向撒），正交画面里不该被裁掉：投影前把 z 压平
        let flatten = simd_float4x4(diagonal: SIMD4(1, 1, 0, 1))
        draw(
            root, encoder: encoder, viewProjection: projection * flatten, transform: world * root.transform,
            time: time, screenCopy: screenCopy)
    }

    private func draw(
        _ node: Node, encoder: any MTLRenderCommandEncoder, viewProjection: simd_float4x4, transform: simd_float4x4,
        time: Float, screenCopy: (any MTLTexture)?, anchors: [UInt32: SIMD3<Float>]? = nil
    ) {
        let particles = node.simulation.particles
        if node.renderer.isRope {
            drawRibbons(node, encoder: encoder, viewProjection: viewProjection, transform: transform, time: time,
                        particles: particles, anchors: anchors, screenCopy: screenCopy)
        } else if !particles.isEmpty, let vertexBuffer = vertexBuffer(node, count: particles.count),
           let indexBuffer = indexBuffer(node, count: particles.count) {
            write(node, particles: particles, anchors: anchors, into: vertexBuffer)
            encodePipeline(node, encoder: encoder, vertexBuffer: vertexBuffer, viewProjection: viewProjection,
                           transform: transform, time: time, screenCopy: screenCopy)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: particles.count * 6, indexType: .uint32, indexBuffer: indexBuffer,
                indexBufferOffset: 0)
        }
        guard !node.children.isEmpty else { return }
        let positions = node.children.contains(where: \.followsParent)
            ? Dictionary(uniqueKeysWithValues: particles.map { ($0.id, basePosition($0, anchors: anchors)) })
            : nil
        for child in node.children {
            draw(
                child, encoder: encoder, viewProjection: viewProjection, transform: transform * child.transform,
                time: time, screenCopy: screenCopy, anchors: child.followsParent ? positions : nil)
        }
    }

    /// 统一的管线与 uniform 绑定（精灵和带子都用 WE 的 genericparticle）
    private func encodePipeline(
        _ node: Node, encoder: any MTLRenderCommandEncoder, vertexBuffer: any MTLBuffer,
        viewProjection: simd_float4x4, transform: simd_float4x4, time: Float, screenCopy: (any MTLTexture)?
    ) {
        var vertex = node.vertexUniforms
        var fragment = node.fragmentUniforms
        vertex.setMatrix("g_ModelViewProjectionMatrix", viewProjection * transform)
        vertex.set("g_Time", [time])
        fragment.set("g_Time", [time])
        encoder.setRenderPipelineState(node.program.pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: ProgramCache.vertexBufferIndex)
        encoder.setVertexBytes(vertex.bytes, length: vertex.bytes.count, index: 0)
        encoder.setFragmentBytes(fragment.bytes, length: fragment.bytes.count, index: 0)
        // g_TextureN 绑定在 N + 1；3 号槽是折射用的画面拷贝，材质没给的槽绑 1×1 黑色
        var slots = Set(node.program.interface.textures.map(\.index))
        slots.formUnion(node.textures.keys)
        // 阴影图集、光照 cookie 这类运行时贴图是别的类型（sampler2DShadow），开着对应开关才用得上；
        // 没给就干脆不绑，免得把普通纹理绑到深度纹理参数上
        let runtimeSlots = Set(
            node.program.interface.textures.filter { $0.defaultTexture?.hasPrefix("_") == true }.map(\.index))
        for slot in slots {
            let texture: any MTLTexture
            if let loaded = node.textures[slot] {
                texture = loaded.texture
            } else if slot == 3, let screenCopy {
                texture = screenCopy
            } else if runtimeSlots.contains(slot) {
                continue
            } else {
                texture = fallback
            }
            encoder.setFragmentTexture(texture, index: slot + 1)
            encoder.setFragmentSamplerState(node.renderer.isRope ? ribbonSampler : sampler, index: slot + 1)
        }
    }

    // MARK: - 带子（rope / ropeTrail）

    /// 带子上一个横截面：中心、横向单位向量、半宽、颜色、沿带子的纹理坐标
    /// 带子上的一个横截面（内部类型，好让几何部分单独测）
    struct Section: Equatable {
        var position: SIMD3<Float>
        var side: SIMD3<Float>
        var halfWidth: Float
        var color: SIMD4<Float>
        var v: Float
    }

    /// WE 的 rope renderer：把先后出生的粒子连成一条带子（docs: "draws a line between each particle that is spawned"）。
    /// 粒子按出生编号排好，宽度取各粒子的大小，颜色取各粒子的颜色和透明度（近处亮、远处淡就是历史透明度）。
    /// WE 的 rope trail renderer：沿每个粒子走过的路径画带子，路径来自模拟时记录的位置历史。
    /// 两条都按官方的参数：subdivision 把拐角磨圆、uvscale 决定贴图重复的快慢。
    private func drawRibbons(
        _ node: Node, encoder: any MTLRenderCommandEncoder, viewProjection: simd_float4x4, transform: simd_float4x4,
        time: Float, particles: [ParticleSimulation.Particle], anchors: [UInt32: SIMD3<Float>]?,
        screenCopy: (any MTLTexture)?
    ) {
        guard let ribbon = node.renderer.ribbon, !particles.isEmpty else { return }
        var runs: [[Section]] = []
        switch node.renderer {
        case .rope:
            // 出生编号递增，按编号排就是出生顺序（粒子数组会因为死亡换位，顺序不可靠）
            let ordered = particles.sorted { $0.id < $1.id }
            var sections: [Section] = []
            sections.reserveCapacity(ordered.count)
            for particle in ordered {
                let color = SIMD4(particle.color, particle.drawnAlpha)
                let size = max(particle.drawnSize, 0)
                Self.appendSection(&sections, at: basePosition(particle, anchors: anchors),
                                   halfWidth: size / 2, color: color)
            }
            if sections.count > 1 { runs.append(Self.smooth(sections, subdivision: ribbon.subdivision)) }
        case .ropeTrail:
            for particle in particles {
                let history = particle.trail
                guard history.count > 1 else { continue }
                var sections: [Section] = []
                sections.reserveCapacity(min(history.count, 64))
                for index in 0..<history.count {
                    let sample = history[index]
                    sections.append(Section(position: sample.position, side: SIMD3(1, 0, 0),
                                            halfWidth: max(sample.size, 0) / 2,
                                            color: SIMD4(particle.color, sample.alpha), v: 0))
                }
                if ribbon.segments > 0 { sections = Self.subsample(sections, to: ribbon.segments + 1) }
                runs.append(Self.smooth(sections, subdivision: ribbon.subdivision))
            }
            runs = runs.filter { $0.count > 1 }
        case .sprite, .spriteTrail:
            return
        }
        runs = runs.map { Self.assignUV($0, ribbon: ribbon, time: time) }
        let vertexCount = runs.reduce(0) { $0 + $1.count * 2 }
        guard vertexCount > 0, let buffer = ribbonVertexBuffer(node, count: vertexCount),
              let indices = ribbonIndices(node, runs: runs),
              let indexBuffer = node.ribbonIndexBuffers[frameIndex] else { return }
        writeRibbons(runs, into: buffer)
        encodePipeline(node, encoder: encoder, vertexBuffer: buffer, viewProjection: viewProjection,
                       transform: transform, time: time, screenCopy: screenCopy)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indices, indexType: .uint32, indexBuffer: indexBuffer,
            indexBufferOffset: 0)
    }

    /// 在带子末尾按一个粒子的像素位置接上新的截面（拐角由 subdivision 那一步磨圆）
    static func appendSection(
        _ sections: inout [Section], at position: SIMD3<Float>, halfWidth: Float, color: SIMD4<Float>
    ) {
        sections.append(Section(position: position, side: SIMD3(1, 0, 0), halfWidth: halfWidth, color: color, v: 0))
    }

    /// 均匀抽稀到 count 个截面（rope trail 的 segments 参数）
    static func subsample(_ sections: [Section], to count: Int) -> [Section] {
        guard count < sections.count, count >= 2 else { return sections }
        return (0..<count).map { index in
            sections[min(sections.count - 1, Int((Float(index) * Float(sections.count - 1) / Float(count - 1)).rounded()))]
        }
    }

    /// subdivision：WE 文档说"每条线上的细分数，越大拐角越圆"，所以用 Chaikin 切角
    /// （把每一段在 1/4 和 3/4 处切开，重复 subdivision 次）。切角不会像样条那样冲出去，
    /// 拐角变圆但线不会跑到粒子外面
    static func smooth(_ sections: [Section], subdivision: Int) -> [Section] {
        guard subdivision > 0, sections.count > 2 else { return sections }
        var result = sections
        for _ in 0..<min(subdivision, 4) {
            guard result.count > 2 else { break }
            var cut: [Section] = [result[0]]
            cut.reserveCapacity(result.count * 2)
            for index in 0..<(result.count - 1) {
                cut.append(Self.interpolate(result[index], result[index + 1], 0.25))
                cut.append(Self.interpolate(result[index], result[index + 1], 0.75))
            }
            cut.append(result[result.count - 1])
            result = cut
        }
        return result
    }

    static func interpolate(_ a: Section, _ b: Section, _ t: Float) -> Section {
        Section(
            position: a.position + (b.position - a.position) * t, side: SIMD3(1, 0, 0),
            halfWidth: a.halfWidth + (b.halfWidth - a.halfWidth) * t,
            color: a.color + (b.color - a.color) * t, v: a.v + (b.v - a.v) * t)
    }

    /// 沿带子累加纹理坐标（v 沿带子、u 横跨 0–1），并在需要时按时间滚动
    ///
    /// v 是"整条带子上贴图拉一次"再乘 uvscale：WE 的 UV scale 写的是"贴图重复多少次"，
    /// 默认 1 就是整条带子一张贴图（`uvsmoothing` 也是为这个设计的——按长度均匀铺才不会有跳变）。
    /// 官方文档里的演示视频可以看到：带子是一条亮芯、两端渐隐的连续弧线，没有逐段的重复。
    static func assignUV(
        _ sections: [Section], ribbon: (subdivision: Int, uvScale: Float, scrolling: Bool, segments: Int), time: Float
    ) -> [Section] {
        guard sections.count > 1 else { return sections }
        var result = sections
        var lengths: [Float] = [0]
        lengths.reserveCapacity(result.count)
        for index in 1..<result.count {
            lengths.append(lengths[index - 1] + simd_length(result[index].position - result[index - 1].position))
        }
        let total = max(lengths[lengths.count - 1], 0.001)
        // UV scrolling 的具体速度 WE 没有公开，按每秒沿带子滚一格的量级
        let scroll: Float = ribbon.scrolling ? time : 0
        for index in 0..<result.count {
            result[index].v = lengths[index] / total * ribbon.uvScale + scroll
        }
        return result
    }

    /// 横截面朝向：在 xy 平面内取路径的法线（粒子带子都是 2D 的，z 不参与）
    static func ribbonSides(_ sections: [Section]) -> [SIMD3<Float>] {
        var sides: [SIMD3<Float>] = []
        sides.reserveCapacity(sections.count)
        for index in 0..<sections.count {
            let previous = index > 0 ? sections[index - 1].position : sections[index].position
            let next = index + 1 < sections.count ? sections[index + 1].position : sections[index].position
            let tangent = next - previous
            let length = simd_length(SIMD2(tangent.x, tangent.y))
            guard length > 1e-5 else {
                sides.append(sides.last ?? SIMD3(0, 1, 0))
                continue
            }
            sides.append(SIMD3(-tangent.y / length, tangent.x / length, 0))
        }
        return sides
    }

    /// 把带子写成 17 个 float 的粒子顶点：位置直接给到顶点上，所以大小填 0、绕 z 的旋转填 0，
    /// 着色器的 ComputeParticlePosition 算出来就是原位置（和 WE 引擎自己生成带子顶点时一个道理）
    private func writeRibbons(_ runs: [[Section]], into buffer: any MTLBuffer) {
        var pointer = buffer.contents().bindMemory(to: Float.self, capacity: runs.reduce(0) { $0 + $1.count * 2 * Self.floatsPerVertex })
        for run in runs {
            let sides = Self.ribbonSides(run)
            for (index, section) in run.enumerated() {
                let side = sides[index]
                for edge in [-1.0, 1.0] as [Float] {
                    let position = section.position + side * (section.halfWidth * edge)
                    pointer[0] = position.x
                    pointer[1] = position.y
                    pointer[2] = position.z
                    pointer[3] = edge < 0 ? 0 : 1
                    pointer[4] = section.v
                    pointer[5] = 0
                    pointer[6] = 0            // 大小 0：位置已经算好，不让着色器再展
                    pointer[7] = section.color.x
                    pointer[8] = section.color.y
                    pointer[9] = section.color.z
                    pointer[10] = section.color.w
                    pointer[11] = 0
                    pointer[12] = 0
                    pointer[13] = 0
                    pointer[14] = 0
                    pointer[15] = 0
                    pointer[16] = 0
                    pointer = pointer.advanced(by: Self.floatsPerVertex)
                }
            }
        }
    }

    private func ribbonVertexBuffer(_ node: Node, count: Int) -> (any MTLBuffer)? {
        let needed = count * Self.floatsPerVertex * 4
        if let buffer = node.ribbonBuffers[frameIndex], buffer.length >= needed { return buffer }
        let capacity = max(needed, (node.ribbonBuffers[frameIndex]?.length ?? 0) * 2, 256 * Self.floatsPerVertex * 4)
        node.ribbonBuffers[frameIndex] = device.makeBuffer(length: capacity, options: .storageModeShared)
        return node.ribbonBuffers[frameIndex]
    }

    /// 每条带子自己的三角形索引（带子之间不连），返回索引个数
    private func ribbonIndices(_ node: Node, runs: [[Section]]) -> Int? {
        var indices: [UInt32] = []
        var base: UInt32 = 0
        for run in runs {
            for section in 0..<(run.count - 1) {
                let a = base + UInt32(section * 2)
                indices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            }
            base += UInt32(run.count * 2)
        }
        guard !indices.isEmpty else { return nil }
        let needed = indices.count * 4
        if (node.ribbonIndexBuffers[frameIndex]?.length ?? 0) < needed {
            let capacity = max(needed, (node.ribbonIndexBuffers[frameIndex]?.length ?? 0) * 2, 1024 * 4)
            node.ribbonIndexBuffers[frameIndex] = device.makeBuffer(length: capacity, options: .storageModeShared)
        }
        guard let buffer = node.ribbonIndexBuffers[frameIndex] else { return nil }
        buffer.contents().copyMemory(from: indices, byteCount: needed)
        return indices.count
    }

    /// 四个缓冲轮流用，避免改写 GPU 还在读的那一份；容量按需翻倍
    private func vertexBuffer(_ node: Node, count: Int) -> (any MTLBuffer)? {
        let needed = count * 4 * Self.floatsPerVertex * 4
        if let buffer = node.buffers[frameIndex], buffer.length >= needed { return buffer }
        let capacity = max(needed, (node.buffers[frameIndex]?.length ?? 0) * 2, 64 * 4 * Self.floatsPerVertex * 4)
        node.buffers[frameIndex] = device.makeBuffer(length: capacity, options: .storageModeShared)
        return node.buffers[frameIndex]
    }

    private func indexBuffer(_ node: Node, count: Int) -> (any MTLBuffer)? {
        if count <= node.indexCapacity, let buffer = node.indexBuffer { return buffer }
        let capacity = max(count, node.indexCapacity * 2, 64)
        var indices: [UInt32] = []
        indices.reserveCapacity(capacity * 6)
        for particle in 0..<UInt32(capacity) {
            let base = particle * 4
            indices.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 1, base + 3])
        }
        node.indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
        node.indexCapacity = capacity
        return node.indexBuffer
    }

    private static let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
    /// 顶点缓冲的份数（每帧轮换一份）
    fileprivate static let bufferCount = 4

    private func write(
        _ node: Node, particles: [ParticleSimulation.Particle], anchors: [UInt32: SIMD3<Float>]?, into buffer: any MTLBuffer
    ) {
        let floats = buffer.contents().bindMemory(to: Float.self, capacity: particles.count * 4 * Self.floatsPerVertex)
        var offset = 0
        let frames = Float(max(node.frameCount, 1))
        for particle in particles {
            let position = basePosition(particle, anchors: anchors)
            let velocity = particle.velocity
            let lifeValue: Float
            if node.frameCount > 1, node.randomFrame {
                lifeValue = ((particle.frameSeed * frames).rounded(.down) + 0.5) / frames
            } else {
                let value = particle.life * node.sequenceMultiplier
                lifeValue = value - value.rounded(.down)
            }
            for corner in Self.corners {
                floats[offset + 0] = position.x
                floats[offset + 1] = position.y
                floats[offset + 2] = position.z
                floats[offset + 3] = corner.x
                floats[offset + 4] = corner.y
                floats[offset + 5] = particle.rotation.z
                floats[offset + 6] = particle.drawnSize
                floats[offset + 7] = particle.color.x
                floats[offset + 8] = particle.color.y
                floats[offset + 9] = particle.color.z
                floats[offset + 10] = particle.drawnAlpha
                floats[offset + 11] = particle.rotation.x
                floats[offset + 12] = particle.rotation.y
                floats[offset + 13] = velocity.x
                floats[offset + 14] = velocity.y
                floats[offset + 15] = velocity.z
                floats[offset + 16] = lifeValue
                offset += Self.floatsPerVertex
            }
        }
    }
}
