import CoreGraphics
import CoreText
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 壁坞自带的兼容素材：没有 WE 自带素材时场景照样能放。和 WE 原版逐像素对照要用 WE 的素材
/// （`WallpaperTool compat-check`，素材不进仓库），这里只测不依赖 WE 素材的部分
@Suite struct CompatAssetsTests {
    private func package(_ files: [String: Data]) throws -> ScenePackage {
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

    private func tex(width: Int, height: Int, pixels: [UInt8]) -> Data {
        var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        u32(0); u32(2); u32(UInt32(width)); u32(UInt32(height)); u32(UInt32(width)); u32(UInt32(height)); u32(0)
        data += Data("TEXB0003".utf8) + Data([0])
        u32(1); u32(UInt32(bitPattern: -1))
        u32(1); u32(UInt32(width)); u32(UInt32(height)); u32(0); u32(UInt32(pixels.count)); u32(UInt32(pixels.count))
        return data + Data(pixels)
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return [Int(data[offset + 2]), Int(data[offset + 1]), Int(data[offset])]
    }

    /// 查找顺序：场景包 → WE 自带素材 → 兼容素材
    @Test func packageAndImportedAssetsWinOverCompatAssets() throws {
        let assets = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompatAssetsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: assets) }
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try Data("WE 的".utf8).write(to: assets.appendingPathComponent("shaders/common_blur.h"))

        let files = SceneFiles(
            package: try package(["shaders/common.h": Data("包里的".utf8)]), assets: assets)
        #expect(files.text("shaders/common.h") == "包里的")
        #expect(files.text("shaders/common_blur.h") == "WE 的")
        #expect(files.text("shaders/common_blending.h")?.contains("ApplyBlending") == true)
        // 没有 WE 素材时全部来自兼容素材
        let bare = SceneFiles(package: try package([:]), assets: nil)
        for path in CompatAssets.allPaths {
            #expect(bare.data(path) != nil, "\(path)")
        }
    }

    /// 每个头文件单独引用都能编译、几个一起引用也不冲突（场景包里的特效常同时引用几个）
    @Test func everyHeaderCompilesInAnEffect() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let headers = CompatAssets.allPaths.filter { $0.hasSuffix(".h") }.map { String($0.dropFirst("shaders/".count)) }
        #expect(headers.count >= 7)
        let includes = headers.sorted().map { "#include \"\($0)\"" }.joined(separator: "\n")
        let fragment = """
            #define BLENDMODE 2
            #define COMPOSITE 1
            \(includes)
            varying vec4 v_TexCoord;
            uniform sampler2D g_Texture0;
            void main() {
                vec4 albedo = blur13a(v_TexCoord.xy, vec2(0.01, 0.0));
                albedo.rgb = ApplyBlending(BLENDMODE, albedo.rgb, hsv2rgb(vec3(0.3, 0.5, 0.5)), 0.5);
                albedo = ApplyComposite(albedo, vec4(rotateVec2(vec2(1.0, 0.0), M_PI_2), greyscale(albedo.rgb), 1.0));
                mat3 xform = inverse(squareToQuad(vec2(0.0), vec2(1.0, 0.0), vec2(1.0), vec2(0.0, 1.0)));
                gl_FragColor = vec4(mul(vec3(albedo.xy, 1.0), xform), albedo.a);
            }
            """
        let vertex = """
            uniform mat4 g_ModelViewProjectionMatrix;
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec4 v_TexCoord;
            void main() {
                gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
                v_TexCoord = vec4(a_TexCoord, a_TexCoord);
            }
            """
        let files: [String: Data] = [
            "scene.json": Data("""
                {"general": {"orthogonalprojection": {"width": 16, "height": 16}},
                 "objects": [{"id": 1, "image": "models/layer.json", "origin": "8 8 0", "size": "16 16",
                              "effects": [{"file": "effects/all/effect.json"}]}]}
                """.utf8),
            "models/layer.json": Data(#"{"material": "materials/layer.json"}"#.utf8),
            "materials/layer.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["layer"]}]}"#.utf8),
            "materials/layer.tex": tex(width: 4, height: 4, pixels: [UInt8](repeating: 200, count: 64)),
            "effects/all/effect.json": Data(#"{"passes": [{"material": "materials/effects/all.json"}]}"#.utf8),
            "materials/effects/all.json": Data(#"{"passes": [{"shader": "effects/all"}]}"#.utf8),
            "shaders/effects/all.vert": Data(vertex.utf8),
            "shaders/effects/all.frag": Data(fragment.utf8),
        ]
        let renderer = try SceneRenderer(device: device, package: try package(files), assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(renderer.renderedEffectCount == 1)
    }

    /// 没有 WE 素材时粒子用兼容的 genericparticle 画出来；场景泛光用兼容的四个着色器
    @Test func particlesAndBloomWorkWithoutImportedAssets() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let particle = """
            {"material": "materials/dot.json", "maxcount": 1,
             "emitter": [{"name": "boxrandom", "rate": 100, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}, {"name": "sizerandom", "min": 20, "max": 20}],
             "renderer": [{"name": "sprite"}]}
            """
        let files: [String: Data] = [
            "scene.json": Data("""
                {"general": {"orthogonalprojection": {"width": 64, "height": 64}, "clearcolor": "0 0 0",
                             "bloom": true, "bloomstrength": 1, "bloomthreshold": 0.5},
                 "objects": [{"id": 1, "particle": "particles/dot.json", "origin": "32 32 0"}]}
                """.utf8),
            "particles/dot.json": Data(particle.utf8),
            "materials/dot.json": Data(#"{"passes": [{"shader": "genericparticle", "blending": "translucent", "textures": ["white"]}]}"#.utf8),
            "materials/white.tex": tex(width: 4, height: 4, pixels: [UInt8](repeating: 255, count: 64)),
        ]
        let renderer = try SceneRenderer(device: device, package: try package(files), assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(renderer.particleSystemCount == 1)
        let image = try renderer.renderImage(width: 64, height: 64, time: 0.5)
        // 粒子是 20×20 的白方块，在正中
        #expect(pixel(image, 32, 32) == [255, 255, 255])
        // 泛光让方块外面亮起来（没有泛光时是纯黑），离得越远越暗
        #expect(pixel(image, 46, 32)[0] > 0)
        #expect(pixel(image, 2, 2)[0] < pixel(image, 46, 32)[0])
    }

    /// 兼容字体都在、都能载入，时钟要用的数字和冒号都有字形（字体文件随 App 带，测试从仓库的 App/CompatFonts 读）
    @Test func compatFontsLoadAndCoverClockGlyphs() throws {
        let fonts = CompatAssets.allPaths.filter { $0.hasPrefix("fonts/") }
        #expect(fonts.count >= 14)
        for path in fonts {
            let data = try #require(CompatAssets.contents(path), "\(path)")
            let graphicsFont = try #require(CGDataProvider(data: data as CFData).flatMap(CGFont.init), "\(path)")
            let font = CTFontCreateWithGraphicsFont(graphicsFont, 20, nil, nil)
            let characters = Array("0123456789:".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count), "\(path)")
            #expect(!glyphs.contains(0), "\(path)")
        }
    }

    /// 程序生成的贴图都能读回来；精灵图按"帧号 × 帧宽"排（粒子着色器就是这么选帧的），
    /// 帧宽除不尽时（512 / 6）也要每行正好放满，不能因为浮点误差错位
    @Test func generatedTexturesParseAndSpriteSheetsLineUp() throws {
        for path in CompatAssets.allPaths where path.hasSuffix(".tex") {
            let data = try #require(CompatAssets.contents(path), "\(path)")
            let tex = try TexFile(data: data)
            let first = try #require(tex.images.first?.mipmaps.first)
            #expect(try first.decompressedData().count == tex.pixelFormat!.byteCount(width: first.width, height: first.height))
            guard let sheet = tex.spriteSheet, let frame = sheet.frames.first else { continue }
            let width = Float(tex.textureWidth)
            for (index, current) in sheet.frames.enumerated() {
                let along = Float(index) * (frame.width / width)
                let expected = SIMD2((along - along.rounded(.down)) * width, along.rounded(.down) * frame.height)
                #expect(abs(current.x - expected.x) < 0.01 && abs(current.y - expected.y) < 0.01, "\(path) 第 \(index) 帧")
                #expect(current.y + frame.height <= Float(tex.textureHeight) + 0.01, "\(path) 第 \(index) 帧出了贴图")
            }
        }
    }
}
