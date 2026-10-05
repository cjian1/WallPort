import Foundation
import Metal
import simd
import Testing
@testable import ShaderCompiler
import ShaderTranslation

/// 端到端：手写一段 WE 方言着色器，完整翻译后用 Metal 真的画一帧，再读回像素核对。
/// 一次验证 scalar uniform 布局的偏移、贴图绑定编号、两个阶段的 varying 对应、mul 的矩阵约定
@Suite struct ShaderCompilerEndToEndTests {
    private let vertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    uniform mat4 g_ModelViewProjectionMatrix;
    varying vec2 v_TexCoord;
    void main() {
        gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        v_TexCoord = a_TexCoord;
    }
    """

    // g_B 是 vec3、g_Arr 是 float 数组：std140 会在它们后面补齐，scalar 不会，偏移错了颜色就会错
    private let fragment = """
    // [COMBO] {"combo":"USE_ARRAY","default":1}
    uniform sampler2D g_Texture0; // {"hidden":true}
    uniform float g_A; // {"material":"a","default":0.25}
    uniform vec3 g_B;
    uniform float g_Arr[3];
    uniform vec2 g_C;
    varying vec2 v_TexCoord;
    void main() {
    #if USE_ARRAY
        float blue = g_Arr[2];
    #else
        float blue = 0.0;
    #endif
        gl_FragColor = vec4(g_A, g_B.y, blue, g_C.x) * texSample2D(g_Texture0, v_TexCoord).r;
    }
    """

    @Test func translatedProgramRendersExpectedPixels() throws {
        let program = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: [:], providedTextures: [0]) { _ in nil }
        #expect(program.defines == ["USE_ARRAY": 1])
        #expect(program.fragmentUniforms.member("g_B")?.offset == 4)
        #expect(program.fragmentUniforms.member("g_Arr")?.offset == 16)
        #expect(program.fragmentUniforms.member("g_C")?.offset == 28)

        let device = try #require(MTLCreateSystemDefaultDevice())
        let vertexFunction = try device.makeLibrary(source: program.vertexMetal, options: nil).makeFunction(name: "main0")
        let fragmentFunction = try device.makeLibrary(source: program.fragmentMetal, options: nil).makeFunction(name: "main0")

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let layout = MTLVertexDescriptor()
        layout.attributes[0].format = .float3
        layout.attributes[0].bufferIndex = 30
        layout.attributes[1].format = .float2
        layout.attributes[1].offset = 12
        layout.attributes[1].bufferIndex = 30
        layout.layouts[30].stride = 20
        descriptor.vertexDescriptor = layout
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        // 列向量约定下"x 方向平移 +1"的矩阵：铺满裁剪空间的矩形会移到右半边
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(1, 0, 0, 1)
        var vertexUniforms = UniformBuffer(layout: program.vertexUniforms)
        vertexUniforms.setMatrix("g_ModelViewProjectionMatrix", translation)
        var fragmentUniforms = UniformBuffer(layout: program.fragmentUniforms)
        fragmentUniforms.set("g_A", [0.25])
        fragmentUniforms.set("g_B", [0, 0.5, 0])
        fragmentUniforms.set("g_Arr", [0, 0, 0.75])
        fragmentUniforms.set("g_C", [1, 0])

        let white = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
            d.storageMode = .shared
            return d
        }())!
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8(255)], bytesPerRow: 1)
        let target = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .shared
            return d
        }())!

        let quad: [Float] = [-1, -1, 0, 0, 1, 1, -1, 0, 1, 1, -1, 1, 0, 0, 0, 1, 1, 0, 1, 0]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(quad, length: quad.count * 4, index: 30)
        encoder.setVertexBytes(vertexUniforms.bytes, length: vertexUniforms.bytes.count, index: 0)
        encoder.setFragmentBytes(fragmentUniforms.bytes, length: fragmentUniforms.bytes.count, index: 0)
        encoder.setFragmentTexture(white, index: 1)
        encoder.setFragmentSamplerState(device.makeSamplerState(descriptor: MTLSamplerDescriptor()), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        target.getBytes(&pixels, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 4 + x) * 4..<(y * 4 + x) * 4 + 4]) }
        // 左半边没画到，保持清屏色；右半边是 (0.25, 0.5, 0.75, 1)，按 BGRA 存放
        #expect(pixel(0, 1) == [0, 0, 0, 0])
        #expect(pixel(1, 2) == [0, 0, 0, 0])
        #expect(pixel(2, 1) == [191, 128, 64, 255])
        #expect(pixel(3, 3) == [191, 128, 64, 255])
    }

    /// 着色器里按 HLSL 习惯构造的矩阵：mat2(0,-1, 1,0) 在 HLSL 里第 0 行是 (0, -1)，
    /// mul((1,0), M) 取第 0 行 = (0, -1)。光束特效的 squareToQuad、粒子的旋转矩阵都依赖这个约定
    @Test func matricesBuiltInShadersFollowHLSLConvention() throws {
        let fragment = """
        varying vec2 v_TexCoord;
        void main() {
            vec2 r = mul(vec2(1.0, 0.0), mat2(0.0, -1.0, 1.0, 0.0));
            vec2 c = mul(mat2(0.0, -1.0, 1.0, 0.0), vec2(1.0, 0.0));
            gl_FragColor = vec4(r * 0.5 + 0.5, c * 0.5 + 0.5);
        }
        """
        let program = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: [:], providedTextures: []) { _ in nil }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try device.makeLibrary(source: program.vertexMetal, options: nil).makeFunction(name: "main0")
        descriptor.fragmentFunction = try device.makeLibrary(source: program.fragmentMetal, options: nil).makeFunction(name: "main0")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let layout = MTLVertexDescriptor()
        layout.attributes[0].format = .float3
        layout.attributes[0].bufferIndex = 30
        layout.attributes[1].format = .float2
        layout.attributes[1].offset = 12
        layout.attributes[1].bufferIndex = 30
        layout.layouts[30].stride = 20
        descriptor.vertexDescriptor = layout
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let target = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .shared
            return d
        }())!
        var vertexUniforms = UniformBuffer(layout: program.vertexUniforms)
        vertexUniforms.setMatrix("g_ModelViewProjectionMatrix", matrix_identity_float4x4)
        let quad: [Float] = [-1, -1, 0, 0, 1, 1, -1, 0, 1, 1, -1, 1, 0, 0, 0, 1, 1, 0, 1, 0]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commands = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(quad, length: quad.count * 4, index: 30)
        encoder.setVertexBytes(vertexUniforms.bytes, length: vertexUniforms.bytes.count, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        // 行向量 × 矩阵 = 第 0 行 (0, -1)；矩阵 × 列向量 = 第 0 列 (0, 1)
        #expect(abs(Int(pixel[0]) - 128) <= 1 && pixel[1] == 0)
        #expect(abs(Int(pixel[2]) - 128) <= 1 && pixel[3] == 255)
    }

    @Test func compileErrorsCarryTheCompilerLog() {
        #expect(throws: ShaderCompiler.CompileError.self) {
            try ShaderCompiler.spirv("#version 450\nvoid main() { undefinedCall(); }", stage: .fragment)
        }
    }

    /// 材质参数也会声明在被 #include 的头文件里（WE 的 common_particles.h 就有 g_RefractAmount），
    /// 读接口时必须把展开后的头文件也算上，否则参数拿不到默认值、一直是 0
    @Test func parametersDeclaredInIncludedHeadersArePartOfTheInterface() throws {
        let vertex = """
        #include "shared.h"
        attribute vec3 a_Position;
        void main() { gl_Position = vec4(a_Position, 1.0); }
        """
        let fragment = """
        #include "shared.h"
        uniform sampler2D g_Texture0; // {"hidden":true}
        void main() {
            float value = g_HeaderValue + g_HeaderColor.x;
            gl_FragColor = vec4(value) * texSample2D(g_Texture0, vec2(0.5));
        }
        """
        let header = """
        uniform float g_HeaderValue; // {"material":"headervalue","default":0.75}
        uniform vec3 g_HeaderColor; // {"material":"headercolor","default":"0.25 0.5 0.75"}
        """
        let program = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: [:], providedTextures: [0]
        ) { $0 == "shaders/shared.h" ? header : nil }

        let value = try #require(program.interface.parameters.first { $0.uniform == "g_HeaderValue" })
        #expect(value.key == "headervalue")
        #expect(value.defaultValue == [0.75])
        let color = try #require(program.interface.parameters.first { $0.uniform == "g_HeaderColor" })
        #expect(color.defaultValue == [0.25, 0.5, 0.75])
        #expect(program.fragmentUniforms.member("g_HeaderValue") != nil)
    }
}

@Suite struct TranslationCacheTests {
    private let vertex = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }"
    private let fragment = "uniform float g_A; // {\"material\":\"a\",\"default\":0.5}\nvoid main() { gl_FragColor = vec4(g_A); }"

    @Test func secondTranslationComesFromDiskAndMatches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranslationCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: [:], providedTextures: [], include: { _ in nil }, cacheDirectory: directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)

        let second = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: [:], providedTextures: [], include: { _ in nil }, cacheDirectory: directory)
        #expect(second.fragmentMetal == first.fragmentMetal)
        #expect(second.fragmentUniforms.member("g_A")?.offset == first.fragmentUniforms.member("g_A")?.offset)
        #expect(second.interface == first.interface)

        // 不同的开关得到不同的缓存文件
        _ = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: ["X": 1], providedTextures: [], include: { _ in nil }, cacheDirectory: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func corruptedCacheFileIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranslationCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: [:], providedTextures: [], include: { _ in nil }, cacheDirectory: directory)
        let file = directory.appendingPathComponent(try FileManager.default.contentsOfDirectory(atPath: directory.path)[0])
        try Data("不是 JSON".utf8).write(to: file)
        let program = try ProgramTranslator.translate(
            vertex: vertex, fragment: fragment, combos: [:], providedTextures: [], include: { _ in nil }, cacheDirectory: directory)
        #expect(program.fragmentUniforms.member("g_A") != nil)
    }
}
