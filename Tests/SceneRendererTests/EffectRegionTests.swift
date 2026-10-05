import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 按 scene.pkg 的结构把文件打成包
private func makePackage(_ files: [String: Data]) throws -> ScenePackage {
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
    return try ScenePackage(data: header + body)
}

/// width×height 的 RGBA8888 TEX
private func makeTex(width: Int, height: Int, pixels: [UInt8]) -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    u32(0); u32(2); u32(UInt32(width)); u32(UInt32(height)); u32(UInt32(width)); u32(UInt32(height)); u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1); u32(UInt32(bitPattern: -1))
    u32(1); u32(UInt32(width)); u32(UInt32(height)); u32(0); u32(UInt32(pixels.count)); u32(UInt32(pixels.count))
    return data + Data(pixels)
}

private func json(_ text: String) -> Data { Data(text.utf8) }

/// 一个和 WE 的 shake 同一类的特效：在当前位置加上"偏移 × 强度²"处取样，偏移在 −1…1
private let shakeVertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
    """
private let shakeFragment = """
    uniform sampler2D g_Texture0;
    uniform float g_Time;
    uniform float g_Amp; // {"material":"strength","default":0.3}
    varying vec2 v_TexCoord;
    void main() {
        float offset = sin(g_Time * 3.0);
        gl_FragColor = texSample2D(g_Texture0, v_TexCoord + vec2(offset, -offset) * g_Amp * g_Amp);
    }
    """

/// 串行：两个整场景渲染的测试都要往 `EffectRegion.additionalVerified` 里登记自己的特效
@Suite(.serialized) struct EffectRegionTests {
    /// 指纹只认代码：注释、空白、换行符不同也一样；代码不同就不一样
    @Test func codeHashIgnoresCommentsAndWhitespace() {
        let a = "uniform float g_Amp; // {\"default\":0.1}\nvoid main() {\n\tgl_FragColor = x;\n}\n"
        let b = "/* 旧版 */ uniform float g_Amp;\r\nvoid main(){gl_FragColor=x;} // 结束"
        let c = "uniform float g_Amp;\nvoid main() { gl_FragColor = y; }"
        #expect(EffectRegion.codeHash(a) == EffectRegion.codeHash(b))
        #expect(EffectRegion.codeHash(a) != EffectRegion.codeHash(c))
    }

    /// RGBA 贴图：找出 alpha 不为 0 的那一块；全透明时是空的盒子
    @Test func alphaBoundsFindTheOpaquePart() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func texture(_ fill: (Int, Int) -> UInt8) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 64, height: 32, mipmapped: false)
            descriptor.storageMode = .shared
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            var pixels = [UInt8](repeating: 0, count: 64 * 32 * 4)
            for y in 0..<32 { for x in 0..<64 { pixels[(y * 64 + x) * 4 + 3] = fill(x, y); pixels[(y * 64 + x) * 4] = 200 } }
            texture.replace(region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 64 * 4)
            return texture
        }
        let square = try texture { x, y in (10..<20).contains(x) && (5..<9).contains(y) ? 1 : 0 }
        #expect(EffectRegion.alphaBounds(of: square) == SIMD4(10.0 / 64, 5.0 / 32, 20.0 / 64, 9.0 / 32))
        let empty = try texture { _, _ in 0 }
        #expect(EffectRegion.alphaBounds(of: empty) == .zero)
    }

    /// BC3（DXT5）：按 4×4 的块判断，块里有一个像素 alpha 不为 0 就算
    @Test func alphaBoundsReadCompressedBlocks() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard device.supportsBCTextureCompression else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bc3_rgba, width: 8, height: 8, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        // 四个块：只有右上那块的 alpha 端点是 255（索引全 0 → 取端点 0）
        var blocks = [UInt8](repeating: 0, count: 4 * 16)
        blocks[16] = 255
        texture.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: blocks, bytesPerRow: 2 * 16)
        #expect(EffectRegion.alphaBounds(of: texture) == SIMD4(0.5, 0, 1, 0.5))
    }

    /// 裁剪矩形：包围盒向外扩出各特效最多挪开的距离再多 2 像素，夹在缓冲里
    @Test func scissorGrowsByReachAndStaysInside() {
        let rect = EffectRegion.scissor(
            content: SIMD4(0.25, 0.25, 0.5, 0.5), reach: SIMD2(0.1, 0.1), bufferSize: SIMD2(100, 100))
        // 要覆盖 13…62（浮点误差可以多出 1 像素，宁可多算不能少算）
        #expect((12...13).contains(rect.x) && (12...13).contains(rect.y))
        #expect((62...63).contains(rect.x + rect.width) && (62...63).contains(rect.y + rect.height))
        let full = EffectRegion.scissor(content: SIMD4(0, 0, 1, 1), reach: SIMD2(0.1, 0.1), bufferSize: SIMD2(100, 50))
        #expect(full.x == 0 && full.y == 0 && full.width == 100 && full.height == 50)
    }

    /// 四边形里对应一段纹理坐标的那一小块（左下、右下、左上、右上）
    @Test func subQuadFollowsTheTextureCoordinates() {
        let quad: [SIMD4<Float>] = [
            SIMD4(-50, -25, 0, 1), SIMD4(50, -25, 1, 1), SIMD4(-50, 25, 0, 0), SIMD4(50, 25, 1, 0),
        ]
        let part = EffectRegion.subQuad(quad, u: 0.25...0.75, v: 0.5...1)
        #expect(part == [
            SIMD4(-25, -25, 0.25, 1), SIMD4(25, -25, 0.75, 1), SIMD4(-25, 0, 0.25, 0.5), SIMD4(25, 0, 0.75, 0.5),
        ])
    }

    /// 画结果时的屏幕裁剪矩形：那一块投影到屏幕上的外接矩形，每边放宽 1 像素；整块在屏幕外时不画
    @Test func screenScissorCoversTheProjectedRegion() throws {
        // 画布 100×50 铺满 200×100 的目标：画布坐标 ×2，y 翻过来
        let projection = SceneRenderer.coverProjection(canvas: SIMD2(100, 50), target: SIMD2(200, 100))
        let corners: [SIMD4<Float>] = [
            SIMD4(25, 10, 0, 0), SIMD4(50, 10, 0, 0), SIMD4(25, 30, 0, 0), SIMD4(50, 30, 0, 0),
        ]
        let rect = try #require(EffectRegion.screenScissor(corners, projection: projection, target: SIMD2(200, 100)))
        #expect(rect.x == 49 && rect.y == 39 && rect.width == 52 && rect.height == 42)
        let outside = corners.map { SIMD4($0.x + 500, $0.y, 0, 0) }
        #expect(EffectRegion.screenScissor(outside, projection: projection, target: SIMD2(200, 100)) == nil)
    }

    /// 采样洇出去的范围：放大采样或只有一层时 2 格；缩小采样且有 mipmap 时按用得上的最粗一层放宽
    @Test func samplingMarginGrowsWithTheCoarsestMipmapUsed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func loaded(_ width: Int, _ height: Int, mipmapped: Bool) throws -> LoadedTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: mipmapped)
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            return LoadedTexture(
                texture: texture, imageSize: SIMD2(Float(width), Float(height)), uvScale: SIMD2(1, 1),
                clampsUVs: true, usesNearestFiltering: false)
        }
        func texels(_ count: Float) -> SIMD2<Float> { SIMD2(repeating: count) / SIMD2(1000, 500) }
        let big = try loaded(1000, 500, mipmapped: true)
        // 放大采样：只读第 0 层
        #expect(EffectRegion.samplingMargin(of: big, bufferSize: SIMD2(2000, 1000)) == texels(2))
        // 缩小到 0.8 倍：第 0、1 层混合，放宽 2 + 4 × 2 格
        #expect(EffectRegion.samplingMargin(of: big, bufferSize: SIMD2(800, 400)) == texels(10))
        // 缩小到 0.3 倍：用到第 2 层
        #expect(EffectRegion.samplingMargin(of: big, bufferSize: SIMD2(300, 150)) == texels(18))
        // 只有一层：缩小采样也只读第 0 层
        let single = try loaded(1000, 500, mipmapped: false)
        #expect(EffectRegion.samplingMargin(of: single, bufferSize: SIMD2(300, 150)) == texels(2))
    }

    /// 矩形的交集，以及"外框去掉中间一块"拆成的几条
    @Test func stripsCoverTheOuterRectExceptTheMiddle() {
        let outer = MTLScissorRect(x: 0, y: 0, width: 100, height: 50)
        let inner = MTLScissorRect(x: 20, y: 10, width: 30, height: 20)
        let strips = EffectChain.strips(around: inner, within: outer)
        #expect(strips.count == 4)
        // 每个像素恰好被盖一次（中间那块不算）
        var covered = [Int](repeating: 0, count: 100 * 50)
        for rect in strips + [inner] {
            for y in rect.y..<(rect.y + rect.height) { for x in rect.x..<(rect.x + rect.width) { covered[y * 100 + x] += 1 } }
        }
        #expect(covered.allSatisfy { $0 == 1 })
        #expect(EffectChain.intersection(inner, MTLScissorRect(x: 60, y: 0, width: 10, height: 10)) == nil)
        #expect(EffectChain.strips(around: MTLScissorRect(x: 200, y: 0, width: 5, height: 5), within: outer).count == 1)
    }

    /// 真渲染：整张不透明的图层挂一个"pulse 类"特效（按时间调暗，遮罩为 0 的地方照原样）。
    /// 只在遮罩范围里跑、外面照抄输入，和整块都跑逐像素一样；遮罩里确实变了
    @Test func maskLimitedEffectRendersExactlyTheSame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let vertex = shakeVertex
        let fragment = """
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture1;
            uniform sampler2D g_Texture2; // {"combo":"MASK"}
            uniform float g_Time;
            varying vec2 v_TexCoord;
            void main() {
                vec4 sample = texSample2D(g_Texture0, v_TexCoord);
                vec4 albedo = vec4(sample.rgb * (0.5 + 0.4 * sin(g_Time * 4.0)), sample.a);
            #if MASK
                float mask = texSample2D(g_Texture2, v_TexCoord).r;
                albedo = mix(sample, albedo, mask);
            #endif
                gl_FragColor = albedo;
            }
            """
        EffectRegion.additionalVerified["pulse"] = [
            String(format: "%016llx-%016llx", EffectRegion.codeHash(fragment), EffectRegion.codeHash(vertex)): .perPixel,
        ]
        // 图层整张不透明（渐变，线性插值取到邻居时才看得出差别）；遮罩只有一小块白的
        var layer = [UInt8](repeating: 255, count: 64 * 64 * 4)
        var mask = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                layer[i] = UInt8(x * 4); layer[i + 1] = UInt8(y * 4); layer[i + 2] = 90
                mask[i + 3] = 255
                if (8..<16).contains(x) && (40..<48).contains(y) { mask[i] = 255; mask[i + 1] = 255; mask[i + 2] = 255 }
            }
        }
        let files: [String: Data] = [
            "scene.json": json("""
                {"general": {"orthogonalprojection": {"width": 64, "height": 64}, "clearcolor": "0 0 0"},
                 "objects": [{"id": 1, "image": "models/layer.json", "origin": "32 32 0", "size": "64 64",
                              "effects": [{"file": "effects/pulse/effect.json",
                                           "passes": [{"textures": [null, null, "mask"]}]}]}]}
                """),
            "models/layer.json": json(#"{"material": "materials/layer.json"}"#),
            "materials/layer.json": json(#"{"passes": [{"shader": "genericimage2", "textures": ["layer"]}]}"#),
            "materials/layer.tex": makeTex(width: 64, height: 64, pixels: layer),
            "materials/mask.tex": makeTex(width: 64, height: 64, pixels: mask),
            "effects/pulse/effect.json": json(#"{"passes": [{"material": "materials/effects/pulse.json"}]}"#),
            "materials/effects/pulse.json": json(#"{"passes": [{"shader": "effects/pulse"}]}"#),
            "shaders/effects/pulse.vert": json(vertex),
            "shaders/effects/pulse.frag": json(fragment),
        ]
        let limited = try SceneRenderer(device: device, package: try makePackage(files), assets: nil, limitsEffectsToContent: true)
        let full = try SceneRenderer(device: device, package: try makePackage(files), assets: nil, limitsEffectsToContent: false)
        #expect(limited.maskLimitedEffects == 1)
        #expect(full.maskLimitedEffects == 0)
        for time: Float in [0, 0.3, 1.1] {
            let a = try limited.renderImage(width: 64, height: 64, time: time)
            let b = try full.renderImage(width: 64, height: 64, time: time)
            #expect((a.dataProvider!.data! as Data) == (b.dataProvider!.data! as Data), "第 \(time) 秒画面不一样")
        }
        // 遮罩里确实被调暗了（不然这个测试什么也没测到）：画面 y 向下，遮罩在贴图的第 40–47 行
        let image = try limited.renderImage(width: 64, height: 64, time: 1.1)
        let bytes = image.dataProvider!.data! as Data
        func red(_ x: Int, _ y: Int) -> UInt8 { bytes[y * image.bytesPerRow + x * 4 + 2] }
        #expect(red(12, 44) < UInt8(12 * 4) - 5, "遮罩里的颜色没变")
        #expect(red(30, 44) == UInt8(30 * 4), "遮罩外的颜色变了")
    }

    /// 真渲染：整张画布大小、只有一小块不透明的图层挂一个"shake 类"特效。
    /// 只在内容附近算、结果也只画那一块，和整块都算逐像素一样
    /// 几个"位移随位置变"的特效串起来、透明处颜色不是 0：范围外清成 0 和整块算时的"透明但有颜色"不一样，
    /// 这点差别每过一个特效往里渗一段，范围留得不够宽就会渗到内容边上（线性插值把透明像素的颜色也混进来）
    @Test func chainedWarpsDoNotLeakTheClearedOutside() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fragment = """
            uniform sampler2D g_Texture0;
            uniform float g_Time;
            uniform float g_Strength; // {"material":"strength","default":0.2}
            varying vec2 v_TexCoord;
            void main() {
                vec2 wave = vec2(sin(v_TexCoord.y * 50.0 + g_Time * 3.0), cos(v_TexCoord.x * 40.0 + g_Time * 2.0));
                gl_FragColor = texSample2D(g_Texture0, v_TexCoord + wave * g_Strength * g_Strength);
            }
            """
        EffectRegion.additionalVerified["waterwaves"] = [
            String(format: "%016llx-%016llx", EffectRegion.codeHash(fragment), EffectRegion.codeHash(shakeVertex)):
                .waterwaves(perspective: false),
        ]
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                if (28..<36).contains(x) && (28..<36).contains(y) {
                    pixels.replaceSubrange(i..<i + 4, with: [255, 60, 30, 255])
                } else {
                    pixels.replaceSubrange(i..<i + 4, with: [30, 250, 90, 0])
                }
            }
        }
        for (strength, count, size) in [(0.1, 4, 64), (0.1, 6, 100), (0.05, 8, 100), (0.15, 3, 150), (0.12, 5, 47)] {
        let effect = #"{"file": "effects/waterwaves/effect.json", "passes": [{"constantshadervalues": {"strength": \#(strength)}}]}"#
        let effects = Array(repeating: effect, count: count).joined(separator: ", ")
        let files: [String: Data] = [
            "scene.json": json("""
                {"general": {"orthogonalprojection": {"width": 64, "height": 64}, "clearcolor": "0.2 0.2 0.2"},
                 "objects": [{"id": 1, "image": "models/layer.json", "origin": "32 32 0", "size": "64 64",
                              "effects": [\(effects)]}]}
                """),
            "models/layer.json": json(#"{"material": "materials/layer.json"}"#),
            "materials/layer.json": json(#"{"passes": [{"shader": "genericimage2", "textures": ["layer"]}]}"#),
            "materials/layer.tex": makeTex(width: 64, height: 64, pixels: pixels),
            "effects/waterwaves/effect.json": json(#"{"passes": [{"material": "materials/effects/waterwaves.json"}]}"#),
            "materials/effects/waterwaves.json": json(#"{"passes": [{"shader": "effects/waterwaves"}]}"#),
            "shaders/effects/waterwaves.vert": json(shakeVertex),
            "shaders/effects/waterwaves.frag": json(fragment),
        ]
        let limited = try SceneRenderer(device: device, package: try makePackage(files), assets: nil, limitsEffectsToContent: true)
        let full = try SceneRenderer(device: device, package: try makePackage(files), assets: nil, limitsEffectsToContent: false)
        #expect(limited.regionLimitedChains == 1)
        for step in 0..<12 {
            let time = Float(step) * 0.37
            let a = try limited.renderImage(width: size, height: size, time: time)
            let b = try full.renderImage(width: size, height: size, time: time)
            let bytesA = a.dataProvider!.data! as Data, bytesB = b.dataProvider!.data! as Data
            let worst = zip(bytesA, bytesB).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst == 0, "强度 \(strength)、\(count) 个特效、\(size) 像素：第 \(time) 秒画面最多差 \(worst)")
        }
        }
    }

    @Test func limitedChainRendersExactlyTheSame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        EffectRegion.additionalVerified["shake"] = [
            String(format: "%016llx-%016llx", EffectRegion.codeHash(shakeFragment), EffectRegion.codeHash(shakeVertex)):
                .shake(base: 1),
        ]
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 20..<28 { for x in 40..<48 { pixels.replaceSubrange((y * 64 + x) * 4..<(y * 64 + x) * 4 + 4, with: [255, 60, 30, 255]) } }
        // 透明的地方颜色不是 0（WE 的贴图常这样）：整块算时这些颜色也在缓冲里，但透明度为 0，画上去看不见
        for y in 0..<64 { for x in 0..<64 where pixels[(y * 64 + x) * 4 + 3] == 0 { pixels[(y * 64 + x) * 4 + 1] = 90 } }
        let files: [String: Data] = [
            "scene.json": json("""
                {"general": {"orthogonalprojection": {"width": 64, "height": 64}, "clearcolor": "0.2 0.2 0.2"},
                 "objects": [{"id": 1, "image": "models/layer.json", "origin": "32 32 0", "size": "64 64",
                              "effects": [{"file": "effects/shake/effect.json"}]}]}
                """),
            "models/layer.json": json(#"{"material": "materials/layer.json"}"#),
            "materials/layer.json": json(#"{"passes": [{"shader": "genericimage2", "textures": ["layer"]}]}"#),
            "materials/layer.tex": makeTex(width: 64, height: 64, pixels: pixels),
            "effects/shake/effect.json": json(#"{"passes": [{"material": "materials/effects/shake.json"}]}"#),
            "materials/effects/shake.json": json(#"{"passes": [{"shader": "effects/shake"}]}"#),
            "shaders/effects/shake.vert": json(shakeVertex),
            "shaders/effects/shake.frag": json(shakeFragment),
        ]
        let limited = try SceneRenderer(device: device, package: try makePackage(files), assets: nil, limitsEffectsToContent: true)
        let full = try SceneRenderer(device: device, package: try makePackage(files), assets: nil, limitsEffectsToContent: false)
        #expect(limited.regionLimitedChains == 1)
        #expect(full.regionLimitedChains == 0)
        for time: Float in [0, 0.4, 1.1] {
            let a = try limited.renderImage(width: 64, height: 64, time: time)
            let b = try full.renderImage(width: 64, height: 64, time: time)
            let bytesA = a.dataProvider!.data! as Data, bytesB = b.dataProvider!.data! as Data
            #expect(bytesA == bytesB, "第 \(time) 秒画面不一样")
        }
    }

    /// 坏场景：特效强度是 NaN、极大的数，图层尺寸、位置也是坏数。以前算特效范围时把 NaN / 无穷大转成整数，
    /// 整个 App 直接崩掉；现在坏数当成没写，算出来的偏移不是有限的小数就不限制范围，照常画出来
    @Test func brokenNumbersDoNotCrashTheRenderer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        EffectRegion.additionalVerified["shake"] = [
            String(format: "%016llx-%016llx", EffectRegion.codeHash(shakeFragment), EffectRegion.codeHash(shakeVertex)):
                .shake(base: 1),
        ]
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 20..<28 { for x in 40..<48 { pixels.replaceSubrange((y * 64 + x) * 4..<(y * 64 + x) * 4 + 4, with: [255, 60, 30, 255]) } }
        for (strength, size) in [("\"nan nan nan\"", "\"64 64\""), ("1e30", "\"64 64\""), ("1e300", "\"1e30 1e30\""),
                                 ("\"inf\"", "\"nan 64\""), ("-1e38", "\"-5 -5\"")] {
            let files: [String: Data] = [
                "scene.json": json("""
                    {"general": {"orthogonalprojection": {"width": 64, "height": 64}, "clearcolor": "0.2 0.2 0.2"},
                     "objects": [{"id": 1, "image": "models/layer.json", "origin": "nan 32 0", "size": \(size),
                                  "scale": "1e30 nan 1",
                                  "effects": [{"file": "effects/shake/effect.json",
                                               "passes": [{"constantshadervalues": {"strength": \(strength)}}]}]}]}
                    """),
                "models/layer.json": json(#"{"material": "materials/layer.json"}"#),
                "materials/layer.json": json(#"{"passes": [{"shader": "genericimage2", "textures": ["layer"]}]}"#),
                "materials/layer.tex": makeTex(width: 64, height: 64, pixels: pixels),
                "effects/shake/effect.json": json(#"{"passes": [{"material": "materials/effects/shake.json"}]}"#),
                "materials/effects/shake.json": json(#"{"passes": [{"shader": "effects/shake"}]}"#),
                "shaders/effects/shake.vert": json(shakeVertex),
                "shaders/effects/shake.frag": json(shakeFragment),
            ]
            let renderer = try SceneRenderer(
                device: device, package: try makePackage(files), assets: nil, targetSize: SIMD2(64, 64),
                limitsEffectsToContent: true)
            for time: Float in [0, 0.4] { _ = try renderer.renderImage(width: 64, height: 64, time: time) }
        }
    }

    @Test func scissorSurvivesNonFiniteNumbers() {
        for bad: Float in [.nan, .infinity, -.infinity, 1e30] {
            let rect = EffectRegion.scissor(
                content: SIMD4(bad, 0.2, 0.5, bad), reach: SIMD2(bad, bad), bufferSize: SIMD2(100, 50))
            #expect(rect.x >= 0 && rect.y >= 0 && rect.width >= 1 && rect.height >= 1)
            #expect(rect.x + rect.width <= 100 && rect.y + rect.height <= 50)
        }
    }
}
