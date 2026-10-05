import Foundation
import Testing
import simd
@testable import SceneRenderer
import WallpaperFormats

/// 手写的最小场景（不含任何 WE 内容）：两个同名图层、一个带旋转的图层
private let sceneJSON = #"""
{
  "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
  "objects": [
    {"id": 1, "name": "条", "origin": "0 0 0"},
    {"id": 2, "name": "条", "origin": "10 0 0"},
    {"id": 3, "name": "转", "origin": "0 0 0", "angles": "0 0 1.5707963"}
  ]
}
"""#

/// 挂点：鞋（2）挂在腿（1）的"鞋"挂点上，鞋带（3）是鞋的子图层
private let attachedJSON = #"""
{
  "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
  "objects": [
    {"id": 1, "name": "腿", "origin": "100 100 0"},
    {"id": 2, "name": "鞋", "origin": "5 0 0", "parent": 1, "attachment": "鞋"},
    {"id": 3, "name": "鞋带", "origin": "1 1 0", "parent": 2}
  ]
}
"""#

@Suite struct SceneStateTests {
    /// 挂在父木偶挂点上的图层：父 × 挂点 × 自己；挂点跟着骨骼动时自己和子图层都要跟着挪（每帧的增量不是单位阵）
    @Test func attachedLayersFollowTheAttachmentPoint() throws {
        let scene = try SceneDescription(json: Data(attachedJSON.utf8))
        #expect(scene.objects.first { $0.id == 2 }?.attachment == "鞋")
        let state = SceneState(scene: scene)
        func translation(_ x: Float, _ y: Float) -> simd_float4x4 {
            var matrix = matrix_identity_float4x4
            matrix.columns.3 = SIMD4(x, y, 0, 1)
            return matrix
        }
        state.setAttachment(2, translation(-1160, -119), isBuild: true)
        let placed = state.world(2).columns.3
        #expect(placed.x == -1055 && placed.y == -19)
        _ = state.bakeBuildWorld(2)
        _ = state.bakeBuildWorld(3)
        #expect(!state.hasModifications)
        #expect(state.delta(3) == matrix_identity_float4x4)

        // 骨骼动了：挂点往右 30
        state.setAttachment(2, translation(-1130, -119))
        #expect(state.hasModifications)
        state.refreshWorlds()
        #expect(state.world(2).columns.3.x == 100 - 1130 + 5)
        #expect(state.delta(2).columns.3.x == 30)
        #expect(state.delta(3).columns.3.x == 30)   // 子图层没被改过，也要跟着祖先走
    }

    private func makeState() throws -> SceneState {
        try SceneState(scene: SceneDescription(json: Data(sceneJSON.utf8)))
    }

    /// 脚本看到的角度按度算（scene.json 存的是弧度）；只改角度也要算"改过"，不然旋转不生效
    @Test func anglesAreDegreesForScripts() throws {
        let state = try makeState()
        #expect(abs(state.layerAngles(3).z - 90) < 0.001)
        #expect(!state.hasModifications)
        state.setLayerAngles(1, SIMD3(0, 0, 90))
        #expect(state.hasModifications)
        state.refreshWorlds()
        let rotated = state.world(1) * SIMD4<Float>(1, 0, 0, 1)
        #expect(abs(rotated.x) < 0.001 && abs(rotated.y - 1) < 0.001)
    }

    /// 运行时建的图层按建的先后排在已有图层之后，改没改过都一样
    @Test func runtimeLayersKeepCreationOrder() throws {
        let state = try makeState()
        let first = try #require(state.createLayer(model: "models/bar.json"))
        let second = try #require(state.createLayer(model: "models/bar.json"))
        #expect(state.drawOrder() == [1, 2, 3, first, second])
        state.setLayerOrigin(second, SIMD3(5, 5, 0))
        #expect(state.drawOrder() == [1, 2, 3, first, second])
        #expect(state.layerIndex(first) == 3 && state.layerIndex(second) == 4)
        #expect(state.drainPendingLayers().map(\.id) == [first, second])
    }

    /// WE 的 alignment：对齐点落在 origin 上。底边对齐时四边形往上挪半个高度（缩放之前的单位），
    /// 脚本读到的名字和写进去的一致
    @Test func alignmentMovesTheQuadSoTheAnchorSitsOnTheOrigin() throws {
        let state = try makeState()
        #expect(state.layerAlignment(1) == "center")
        state.setQuadSize(1, SIMD2(4, 6))
        #expect(state.alignment(1) == matrix_identity_float4x4)
        state.setLayerAlignment(1, "bottom")
        #expect(state.layerAlignment(1) == "bottom")
        #expect(state.hasModifications, "只改对齐也要算改过，不然增量不生效")
        #expect(state.alignment(1).columns.3 == SIMD4(0, 3, 0, 1))
        state.setLayerAlignment(1, "TopLeft")
        #expect(state.layerAlignment(1) == "topleft")
        #expect(state.alignment(1).columns.3 == SIMD4(2, -3, 0, 1))
        // 没登记尺寸的图层（粒子）不挪
        state.setLayerAlignment(2, "bottom")
        #expect(state.alignment(2) == matrix_identity_float4x4)
    }

    /// 建绘制项时脚本已经把缩放设成 0（可视化条没声音时）：按 1 烘进顶点，之后的增量把缩放乘回去。
    /// 按 0 烘的话增量要放大上千万倍，算出来的顶点差出几十个像素
    @Test func collapsedScaleIsBakedAsOneAndRestoredByTheDelta() throws {
        let state = try makeState()
        state.setLayerOrigin(2, SIMD3(874, 56, 0))
        state.setLayerScale(2, SIMD3(5, 0, 0))
        state.setQuadSize(2, SIMD2(4, 4))
        state.setLayerAlignment(2, "bottom")
        state.refreshWorlds()
        let baked = state.bakeBuildWorld(2)
        #expect(abs(simd_length(baked.columns.1) - 1) < 1e-6, "高度为 0 的轴要按 1 烘")
        #expect(abs(baked.columns.0.x - 5) < 1e-6, "正常的轴照原样烘")
        // 之后脚本把高度改成 40：四边形顶边应该在 origin 上方 4 × 40 = 160
        state.setLayerScale(2, SIMD3(5, 40, 1))
        state.refreshWorlds()
        let topLeft = state.delta(2) * baked * SIMD4<Float>(-2, 2, 0, 1)
        let bottomLeft = state.delta(2) * baked * SIMD4<Float>(-2, -2, 0, 1)
        #expect(abs(topLeft.y - (56 + 160)) < 0.01 && abs(bottomLeft.y - 56) < 0.01, "\(topLeft) \(bottomLeft)")
        #expect(abs(topLeft.x - 864) < 0.01)
    }

    /// 同名图层按场景顺序取第一个；运行时建图层有上限
    @Test func lookupIsStableAndCreationIsBounded() throws {
        let state = try makeState()
        #expect(state.layerID(named: "条") == 1)
        #expect(state.layerID(named: "没有") == nil)
        for _ in 0..<SceneState.maximumRuntimeLayers { _ = state.createLayer(model: "m") }
        #expect(state.createLayer(model: "m") == nil)
    }
}
