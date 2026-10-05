import Foundation
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 音乐可视化相关的两个坑（2026-09-29 修）：
/// 1. 只用音频频谱、不提时间/随机数的脚本会被当成"静态脚本"只跑一次，柱子高度永远停在 0；
/// 2. 脚本把 scale 设成带 0 分量的向量（模板里的 `new Vec3(barWidth)` 就是这样，y、z 都是 0）时，
///    世界矩阵做不了逆变换，`delta` 全是 NaN，图层直接消失。
@Suite struct AudioVisualizationTests {
    private func scene(_ fieldScript: String, field: String = "origin") throws -> SceneDescription {
        // 把脚本包成 JSON 字符串：编码成单元素数组再去掉方括号
        let encoded = try JSONSerialization.data(withJSONObject: [fieldScript])
        let quoted = String(decoding: encoded.dropFirst().dropLast(), as: UTF8.self)
        let json = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}, "clearcolor": "0 0 0"},
         "objects": [{"id": 1, "image": "models/bar.json", "size": "10 10",
                      "\(field)": {"script": \(quoted), "value": \(field == "origin" ? "\"50 50 0\"" : "1")}}]}
        """
        return try SceneDescription(json: Data(json.utf8))
    }

    /// 只注册音频频谱、不提时间的脚本也要被当成"每帧重算"
    @Test func scriptsThatRegisterAudioAreDynamic() throws {
        let description = try scene("""
        export var scriptProperties = createScriptProperties().addSlider({ name: 'h', value: 50 }).finish();
        let audioData = engine.registerAudioBuffers(16);
        export function update() { return thisLayer.origin; }
        """)
        let state = SceneState(scene: description)
        let object = try #require(description.objects.first)
        let layer = try #require(ScriptedLayer(object: object, canvasSize: SIMD2(100, 100), state: state))
        #expect(layer.isDynamic, "注册了 AudioBuffers 的脚本必须每帧重算")
        #expect(layer.usesAudio)
    }

    /// 不提任何时间/随机的普通属性脚本仍然是静态的（不白跑）
    @Test func plainScriptsStayStatic() throws {
        let description = try scene("export function update(value) { return value; }")
        let state = SceneState(scene: description)
        let object = try #require(description.objects.first)
        let layer = try #require(ScriptedLayer(object: object, canvasSize: SIMD2(100, 100), state: state))
        #expect(!layer.isDynamic)
    }

    /// 缩放里有 0 分量时世界矩阵仍然可逆：delta 必须是有限值
    @Test func zeroScaleKeepsDeltaFinite() throws {
        let description = try scene("export function update(value) { return value; }")
        let state = SceneState(scene: description)
        let id = try #require(description.objects.first?.id)
        state.setBuildWorld(id, state.world(id))
        // 可视化条脚本会把 scale 设成 new Vec3(barWidth)：y、z 都是 0
        state.setLayerScale(id, SIMD3(5, 0, 0))
        let delta = state.delta(id)
        for column in [delta.columns.0, delta.columns.1, delta.columns.2, delta.columns.3] {
            #expect(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite,
                    "delta 里出现了 NaN：\(column)")
        }
    }
}
