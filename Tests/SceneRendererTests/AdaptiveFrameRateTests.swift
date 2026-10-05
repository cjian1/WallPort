import AppKit
import DesktopHost
import Foundation
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 真的 SceneContent：一帧一帧往前走，看自动帧率量完之后把显示链路设成几帧
@MainActor
@Suite struct AdaptiveFrameRateTests {
    /// 一个图层挂一个"整体晃动"的特效：偏移 = sin(时间 × 速度) × 0.05
    private func sceneFolder(speed: Double) throws -> URL {
        let vertex = """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
            """
        let fragment = """
            uniform sampler2D g_Texture0;
            uniform float g_Time;
            varying vec2 v_TexCoord;
            void main() {
                gl_FragColor = texSample2D(g_Texture0, v_TexCoord + vec2(sin(g_Time * \(speed)) * 0.05, 0.0));
            }
            """
        // 有纹理的图（块匹配要认得出位置）
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                pixels[i] = UInt8(128 + 100 * sin(Double(x) * 0.7) * cos(Double(y) * 0.5))
                pixels[i + 1] = UInt8((x * 4) % 256)
                pixels[i + 2] = UInt8((y * 4) % 256)
            }
        }
        let files: [String: Data] = [
            "scene.json": Data("""
                {"general": {"orthogonalprojection": {"width": 64, "height": 64}, "clearcolor": "0 0 0"},
                 "objects": [{"id": 1, "image": "models/layer.json", "origin": "32 32 0", "size": "64 64",
                              "effects": [{"file": "effects/sway/effect.json"}]}]}
                """.utf8),
            "models/layer.json": Data(#"{"material": "materials/layer.json"}"#.utf8),
            "materials/layer.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["layer"]}]}"#.utf8),
            "materials/layer.tex": Self.tex(width: 64, height: 64, pixels: pixels),
            "effects/sway/effect.json": Data(#"{"passes": [{"material": "materials/effects/sway.json"}]}"#.utf8),
            "materials/effects/sway.json": Data(#"{"passes": [{"shader": "effects/sway"}]}"#.utf8),
            "shaders/effects/sway.vert": Data(vertex.utf8),
            "shaders/effects/sway.frag": Data(fragment.utf8),
        ]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveFrameRate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.package(files).write(to: folder.appendingPathComponent("scene.pkg"))
        return folder
    }

    /// 走 `seconds` 秒（每秒 30 帧），返回最后显示链路的帧率
    private func run(speed: Double, seconds: Double) async throws -> Int? {
        let folder = try sceneFolder(speed: speed)
        defer { try? FileManager.default.removeItem(at: folder) }
        let content = SceneContent(
            projectFolder: folder, assets: nil, targetSize: CGSize(width: 480, height: 480), label: "测试",
            log: EventLog(fileURL: folder.appendingPathComponent("log.txt")), onFailure: { _ in })
        defer { content.tearDown() }
        content.view.frame = NSRect(x: 0, y: 0, width: 240, height: 240)
        for _ in 0..<500 where content.frameRateInUse == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(content.frameRateInUse == 30, "量之前按上限")
        var time = 1000.0
        var frames = 0
        // 至少走 seconds 秒；全部测试一起跑、机器忙的时候测量结果回来得晚，后面的测量会往后推，
        // 这时接着走（最多再走 20 秒），直到量满
        while frames < Int(seconds * 30)
            || (content.motionSamples < FrameRateGovernor.window && frames < Int((seconds + 20) * 30)) {
            content.advance(to: time)
            time += 1.0 / 30
            frames += 1
            // 让取帧的回调、后台测量回到主线程。平时场景时间走得比真实时间快（每 4 毫秒走一帧）；
            // 补着量的时候按真实速度走：机器忙时取帧要好几百毫秒才回来，走太快的话还没回来就被当成超时放弃了
            try await Task.sleep(for: .milliseconds(frames <= Int(seconds * 30) ? 4 : 33))
        }
        #expect(content.motionSamples == FrameRateGovernor.window, "量满了 3 次（实际 \(content.motionSamples) 次）")
        return content.frameRateInUse
    }

    /// 慢慢晃（最快约 0.05 × 1 × 480 = 24 像素/秒）：量满 3 次之后降到 20 帧
    @Test func slowSceneDropsTo20() async throws {
        #expect(try await run(speed: 1, seconds: 12) == 20)
    }

    /// 晃得快（最快约 0.05 × 12 × 480 ≈ 290 像素/秒）：保持 30 帧
    @Test func fastSceneStaysAt30() async throws {
        #expect(try await run(speed: 12, seconds: 12) == 30)
    }

    private static func package(_ files: [String: Data]) -> Data {
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
        return header + body
    }

    private static func tex(width: Int, height: Int, pixels: [UInt8]) -> Data {
        var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        u32(0); u32(2); u32(UInt32(width)); u32(UInt32(height)); u32(UInt32(width)); u32(UInt32(height)); u32(0)
        data += Data("TEXB0003".utf8) + Data([0])
        u32(1); u32(UInt32(bitPattern: -1))
        u32(1); u32(UInt32(width)); u32(UInt32(height)); u32(0); u32(UInt32(pixels.count)); u32(UInt32(pixels.count))
        return data + Data(pixels)
    }
}
