import Foundation
import Metal
import ShaderCompiler
import WallpaperFormats

/// WE 的场景泛光（scene.json 的 general.bloom，非 HDR 场景）：整帧画完以后，
/// 把亮的部分提出来、缩小模糊，再加回画面。用的全是 WE 自带素材里的着色器：
///
/// 1. `downsample_quarter_bloom`：整帧 → 1/4 尺寸，取 2×2 四个点平均，按阈值提亮部分、乘强度和色调；
/// 2. `downsample_eighth_blur_v`：1/4 → 1/8 尺寸，13 点高斯横向模糊；
/// 3. `blur_h_bloom`：1/8 尺寸上 13 点高斯纵向模糊；
/// 4. `combine`：原画面 + 泛光。
///
/// 这几步的先后和每步的尺寸 WE 没有公开（渲染图写在引擎里），是按着色器推出来的：两个模糊的采样间隔都是
/// `g_TexelSize × 8`，只有 `g_TexelSize` 是**整帧**的像素尺寸、模糊画在 1/8 尺寸上时，才正好一格一采样；
/// 降采样那步在 ±1 个整帧像素处取四个点，也只有这样才是"2×2 取平均"。
final class SceneBloom {
    private let settings: SceneDescription.Bloom
    private let downsample: CompiledProgram
    private let blurX: CompiledProgram
    private let blurY: CompiledProgram
    private let combine: CompiledProgram
    private let sampler: any MTLSamplerState
    private let device: any MTLDevice
    /// 1/4、1/8、1/8（模糊后）三张缓冲，按画面尺寸建
    private var buffers: [any MTLTexture] = []
    private var bufferSourceSize = SIMD2<Int>(0, 0)

    /// 裁剪空间的整张四边形（位置 3f、纹理坐标 2f）；左上角 (-1, 1) 对应纹理坐标 (0, 0)
    private static let quad: [Float] = [
        -1, -1, 0, 0, 1,
        1, -1, 0, 1, 1,
        -1, 1, 0, 0, 0,
        1, 1, 0, 1, 0,
    ]

    init(device: any MTLDevice, programs: ProgramCache, settings: SceneDescription.Bloom) throws {
        self.device = device
        self.settings = settings
        downsample = try programs.program(shader: "downsample_quarter_bloom", combos: [:], providedTextures: [0])
        blurX = try programs.program(shader: "downsample_eighth_blur_v", combos: [:], providedTextures: [0])
        blurY = try programs.program(shader: "blur_h_bloom", combos: [:], providedTextures: [0])
        combine = try programs.program(shader: "combine", combos: [:], providedTextures: [0, 1])
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw FormatError("无法创建泛光的采样器")
        }
        self.sampler = sampler
    }

    /// 缓冲占的显存（诊断用）
    var allocatedSize: Int { buffers.map(\.allocatedSize).reduce(0, +) }

    /// - Parameters:
    ///   - target: 画面（已经画完所有图层），泛光加回到这里
    ///   - frame: 画面的一份拷贝（combine 要同时读原画面、写目标）
    func encode(into commandBuffer: any MTLCommandBuffer, target: any MTLTexture, frame: any MTLTexture) {
        let size = SIMD2(target.width, target.height)
        if size != bufferSourceSize {
            let quarter = SIMD2(max(1, size.x / 4), max(1, size.y / 4))
            let eighth = SIMD2(max(1, size.x / 8), max(1, size.y / 8))
            guard let a = try? EffectChain.makeBuffer(device: device, size: quarter),
                  let b = try? EffectChain.makeBuffer(device: device, size: eighth),
                  let c = try? EffectChain.makeBuffer(device: device, size: eighth)
            else { return }
            buffers = [a, b, c]
            bufferSourceSize = size
        }
        let texel = [1 / Float(size.x), 1 / Float(size.y)]
        pass(downsample, into: buffers[0], textures: [0: frame], texel: texel, commandBuffer: commandBuffer)
        pass(blurX, into: buffers[1], textures: [0: buffers[0]], texel: texel, commandBuffer: commandBuffer)
        pass(blurY, into: buffers[2], textures: [0: buffers[1]], texel: texel, commandBuffer: commandBuffer)
        pass(combine, into: target, textures: [0: frame, 1: buffers[2]], texel: texel, commandBuffer: commandBuffer)
    }

    private func pass(
        _ program: CompiledProgram, into target: any MTLTexture, textures: [Int: any MTLTexture], texel: [Float],
        commandBuffer: any MTLCommandBuffer
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        // 四个通道都画满整个目标
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        var vertex = UniformBuffer(layout: program.vertexLayout)
        var fragment = UniformBuffer(layout: program.fragmentLayout)
        func set(_ uniform: String, _ values: [Float]) {
            vertex.set(uniform, values)
            fragment.set(uniform, values)
        }
        for parameter in program.interface.parameters { set(parameter.uniform, parameter.defaultValue) }
        set("g_TexelSize", texel)
        set("g_BloomStrength", [settings.strength])
        set("g_BloomThreshold", [settings.threshold])
        set("g_BloomTint", [settings.tint.x, settings.tint.y, settings.tint.z])
        encoder.setRenderPipelineState(program.pipeline)
        Self.quad.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: ProgramCache.vertexBufferIndex)
        }
        encoder.setVertexBytes(vertex.bytes, length: vertex.bytes.count, index: 0)
        encoder.setFragmentBytes(fragment.bytes, length: fragment.bytes.count, index: 0)
        // g_TextureN 绑定在 N + 1（和特效通道一致）
        for (slot, texture) in textures {
            encoder.setFragmentTexture(texture, index: slot + 1)
            encoder.setFragmentSamplerState(sampler, index: slot + 1)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}
