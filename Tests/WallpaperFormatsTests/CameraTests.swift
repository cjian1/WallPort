import Foundation
import Testing
@testable import WallpaperFormats

/// 2D 摄像机的字段（按 Lucy 场景的写法手写，不含 WE 内容）：zoom 3 → 1，
/// origin 的动画是相对静态值的偏移，末帧正好抵消静态值
@Suite struct CameraTests {
    private let json = #"""
    {"general": {"orthogonalprojection": {"width": 3840, "height": 2160}}, "objects": [
      {"id": 1, "camera": "default", "fov": 50,
       "zoom": {"animation": {"c0": [{"frame": 0, "value": 3}, {"frame": 36, "value": 1}],
                              "options": {"fps": 12, "length": 60, "mode": "single"}}, "value": 3},
       "origin": {"animation": {"c0": [{"frame": 0, "value": 159.2}, {"frame": 36, "value": 244.738}],
                                "c1": [{"frame": 0, "value": 1.6}, {"frame": 36, "value": -1468.742}],
                                "options": {"fps": 12, "length": 60, "mode": "single"},
                                "relative": true},
                  "value": "-244.73788 1468.74146 500"}},
      {"id": 2, "image": "models/a.json"}
    ]}
    """#

    @Test func readsTheAnimatedCamera() throws {
        let camera = try #require(SceneDescription(json: Data(json.utf8)).objects.first?.camera)
        #expect(camera.isAnimated)
        #expect(camera.zoom == 3)
        #expect(camera.originIsRelative)
        #expect(camera.origin == SIMD3(-244.73788, 1468.74146, 500))

        // 开场：3 倍放大，摄像机位置 = 静态值 + 关键帧偏移
        let start = camera.state(at: 0)
        #expect(abs(start.zoom - 3) < 0.001)
        #expect(abs(start.origin.x - (-244.73788 + 159.2)) < 0.01)
        #expect(abs(start.origin.y - (1468.74146 + 1.6)) < 0.01)

        // 第 3 秒（关键帧末帧）起：放大倍数回到 1、偏移抵消静态值 → 正常取景
        let rest = camera.state(at: 3)
        #expect(abs(rest.zoom - 1) < 0.001)
        #expect(abs(rest.origin.x) < 0.01 && abs(rest.origin.y) < 0.01)
        // single 播完停在最后一帧
        let later = camera.state(at: 30)
        #expect(abs(later.zoom - 1) < 0.001 && abs(later.origin.x) < 0.01)
    }

    @Test func staticCameraHasNoAnimation() throws {
        let staticJSON = #"{"general": {}, "objects": [{"id": 1, "camera": "default", "zoom": 2, "origin": "0 0 0"}]}"#
        let camera = try #require(SceneDescription(json: Data(staticJSON.utf8)).objects.first?.camera)
        #expect(!camera.isAnimated)
        #expect(camera.state(at: 5).zoom == 2)
    }

    /// 透视场景的摄像机不当 2D 摄像机处理
    @Test func perspectiveCameraIsIgnored() throws {
        let perspective = #"{"general": {}, "objects": [{"id": 1, "camera": "default", "perspective": true}]}"#
        #expect(try SceneDescription(json: Data(perspective.utf8)).objects.first?.camera == nil)
    }
}
