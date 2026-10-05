import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 按 scene.pkg 的结构把文件打成包
private func scriptedPackage(_ files: [String: Data]) throws -> ScenePackage {
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

/// 读出某一点的颜色（renderImage 的格式是 BGRX，小端）
private func scriptedPixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

/// 画布 100×50，黑底，一个 20×20 的红方块，位置由脚本给
private func scriptedScene(_ origin: String) -> Data {
    Data("""
    {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
     "objects": [{"id": 1, "image": "models/solid.json", "origin": \(origin), "size": "20 20",
                  "color": "1 0 0"}]}
    """.utf8)
}

private func scriptedFiles(scene: Data) -> [String: Data] {
    ["scene.json": scene, "models/solid.json": Data(#"{"solidlayer": true}"#.utf8)]
}

@Suite struct SceneScriptPropertyTests {
    /// 向量属性：脚本改 value 再返回
    @Test func vectorScriptReturnsTheUpdatedValue() throws {
        let source = """
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'x', value: 0.75 })
            .finish();
        export function update(value) {
            value.x = scriptProperties.x * engine.canvasSize.x;
            value.y = engine.canvasSize.y * 0.5;
            return value;
        }
        """
        let script = try #require(SceneScript(
            source: source, properties: nil, environment: .init(canvasSize: SIMD2(100, 50))))
        #expect(script.updateVector(SIMD3(50, 25, 0)) == SIMD3(75, 25, 0))
    }

    /// WE 在载入时用全部用户属性（原值）调一次 applyUserProperties；只在那里赋值的脚本（2248783434 的人物位置）
    /// 以前拿到的是 undefined，人物跑到画布左下角
    @Test func applyUserPropertiesRunsOnceWithAllPropertiesAtLoad() throws {
        let source = """
            'use strict';
            let originX;
            let originY;
            export function update(value) { return new Vec3(originX, originY, value.z); }
            export function applyUserProperties(changed) {
                if (changed.originx != undefined) originX = changed.originx;
                if (changed.originy != undefined) originY = changed.originy;
            }
            """
        let properties = Data(#"{"originx": 1280, "originy": 720, "color": "1 0 0"}"#.utf8)
        let script = try #require(SceneScript(
            source: source, properties: nil, environment: .init(userProperties: properties)))
        #expect(script.problem == nil)
        #expect(script.updateVector(SIMD3(0, 0, 3)) == SIMD3(1280, 720, 3))
    }

    /// WE 允许属性脚本返回一个数（相当于三个分量都用它，例如 scale 的 "2"）
    @Test func numberResultIsBroadcastForVectorProperties() throws {
        let source = "export function update(value) { return 1.5; }"
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        #expect(script.updateVector(SIMD3(1, 1, 1)) == SIMD3(1.5, 1.5, 1.5))
    }

    /// engine.runtime 是"壁纸已运行的秒数"
    @Test func engineRuntimeIsVisibleToScripts() throws {
        let source = "export function update(value) { value.y = Math.sin(engine.runtime); return value; }"
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        script.setRuntime(Float.pi / 2, frameTime: 1 / 30, layerOrigin: .zero, layerScale: SIMD3(1, 1, 1))
        let value = try #require(script.updateVector(SIMD3(0, 0, 0)))
        #expect(abs(value.y - 1) < 0.001)
    }

    /// 脚本拿到的"当前值"是上一次的结果（WE 的约定），所以增量式脚本能累积
    @Test func scriptsSeeThePreviousValue() throws {
        let source = "export function update(value) { value.x += 10; return value; }"
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        #expect(script.updateVector(SIMD3(0, 0, 0)) == SIMD3(10, 0, 0))
        #expect(script.updateVector(SIMD3(0, 0, 0)) == SIMD3(20, 0, 0))
    }

    /// 布尔属性：脚本返回别的类型时按"算不了"处理，调用方保持静态值
    @Test func scriptsThatCannotAnswerThePropertyReturnNil() throws {
        // 把拖拽脚本挂到 visible 上的情况：严格模式下给布尔值加属性会抛错（`~/wp` 里就有）
        let source = "'use strict';\nexport function update(value) { value.x = 1; return value; }"
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        #expect(script.updateBool(false) == nil)
        #expect(script.problem != nil)
    }

    /// 定时器：一帧只触发开始时已到点的；`setTimeout(f, 0)` 自己排自己不会卡死，而是每帧走一次
    @Test func zeroDelayTimersThatRescheduleThemselvesRunOncePerFrame() throws {
        let source = """
        let ticks = 0;
        function tick() { ticks += 1; engine.setTimeout(tick, 0); }
        engine.setTimeout(tick, 0);
        export function update(value) { value.x = ticks; return value; }
        """
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        for frame in 1...3 {
            script.setRuntime(Float(frame) / 30, frameTime: 1 / 30, layerOrigin: .zero, layerScale: SIMD3(1, 1, 1))
        }
        #expect(script.updateVector(SIMD3(0, 0, 0))?.x == 3)
        #expect(script.problem == nil, "\(script.problem ?? "")")
    }

    /// 只有引用时间/随机数的脚本才需要每帧重算
    @Test func timeDependenceIsDetectedFromTheSource() {
        #expect(ScriptedLayer.isTimeDependent("value.y = Math.sin(engine.runtime)"))
        #expect(ScriptedLayer.isTimeDependent("value.x += engine.frametime"))
        #expect(ScriptedLayer.isTimeDependent("return Math.random()"))
        #expect(ScriptedLayer.isTimeDependent("return new Date().getHours()"))
        #expect(!ScriptedLayer.isTimeDependent("value.x = scriptProperties.x * engine.canvasSize.x"))
        #expect(!ScriptedLayer.isTimeDependent("return value"))
    }
}

@Suite struct ScriptedLayerRenderTests {
    /// 位置由 scriptProperties 决定的图层：构建时就该挪到脚本算出来的位置
    @Test func scriptedOriginFromPropertiesIsAppliedAtBuild() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = """
        export var scriptProperties = createScriptProperties()
            .addSlider({ name: 'x', value: 0.75 })
            .finish();
        export function update(value) {
            value.x = scriptProperties.x * engine.canvasSize.x;
            value.y = engine.canvasSize.y * 0.5;
            return value;
        }
        """
        let origin = #"{"script": \#(jsonEscape(source)), "value": "50 25 0"}"#
        let renderer = try SceneRenderer(
            device: device, package: try scriptedPackage(scriptedFiles(scene: scriptedScene(origin))), assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        #expect(renderer.unsupported["脚本驱动的字段（按静态值处理）"] == nil)
        // 不随时间变，不需要持续渲染
        #expect(!renderer.needsAnimation)
        let image = try renderer.renderImage(width: 100, height: 50)
        #expect(scriptedPixel(image, 75, 25) == [255, 0, 0])   // 脚本把它挪到 x=75
        #expect(scriptedPixel(image, 50, 25) == [0, 0, 0])     // 静态值那里已经空了
    }

    /// 时间相关的脚本每帧重算：方块按 engine.runtime 上下浮动
    @Test func scriptedOriginFollowsEngineRuntime() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = "export function update(value) { value.y = 25 + Math.sin(engine.runtime) * 20; return value; }"
        let origin = #"{"script": \#(jsonEscape(source)), "value": "50 25 0"}"#
        let renderer = try SceneRenderer(
            device: device, package: try scriptedPackage(scriptedFiles(scene: scriptedScene(origin))), assets: nil)
        #expect(renderer.needsAnimation)
        // t = 0：sin(0) = 0 → y = 25
        let atZero = try renderer.renderImage(width: 100, height: 50, time: 0)
        #expect(scriptedPixel(atZero, 50, 25) == [255, 0, 0])
        // t = π/2：sin = 1 → y = 45，画面上移（图像第 5 行）
        let atQuarter = try renderer.renderImage(width: 100, height: 50, time: Float.pi / 2)
        #expect(scriptedPixel(atQuarter, 50, 25) == [0, 0, 0])
        #expect(scriptedPixel(atQuarter, 50, 5) == [255, 0, 0])
    }

    /// 脚本把图层关掉就不画（脚本挂在 visible 上，位置固定在画面中央）；返回 true 的对照组照常画
    @Test func scriptedVisibilityHidesTheLayer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func render(_ visibleScript: String) throws -> CGImage {
            let visible = #"{"script": \#(jsonEscape(visibleScript)), "value": true}"#
            let scene = Data("""
            {"general": {"orthogonalprojection": {"width": 100, "height": 50}, "clearcolor": "0 0 0"},
             "objects": [{"id": 1, "image": "models/solid.json", "origin": "50 25 0", "size": "20 20",
                          "color": "1 0 0", "visible": \(visible)}]}
            """.utf8)
            let renderer = try SceneRenderer(
                device: device, package: try scriptedPackage(scriptedFiles(scene: scene)), assets: nil)
            #expect(renderer.problems.isEmpty, "\(renderer.problems)")
            return try renderer.renderImage(width: 100, height: 50)
        }
        #expect(scriptedPixel(try render("export function init() { return false; }"), 50, 25) == [0, 0, 0])
        #expect(scriptedPixel(try render("export function init() { return true; }"), 50, 25) == [255, 0, 0])
    }

    /// 跑不了的脚本（这里是死循环，被执行时限终止）保持静态值并上报
    @Test func failingScriptsKeepTheStaticValue() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let framework = #"{"script": "while (true) {}", "value": "50 25 0"}"#
        let failing = try SceneRenderer(
            device: device,
            package: try scriptedPackage(scriptedFiles(scene: scriptedScene(framework))), assets: nil)
        #expect(failing.unsupported["脚本驱动的字段（按静态值处理）"] == 1)
        let kept = try failing.renderImage(width: 100, height: 50)
        #expect(scriptedPixel(kept, 50, 25) == [255, 0, 0])
    }

    /// init 的返回值是属性的初始值，update 从它开始算
    @Test func initResultBecomesTheStartingValue() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = """
        export function init(value) { value.x = 75; return value; }
        export function update(value) { value.y = 25; return value; }
        """
        let origin = #"{"script": \#(jsonEscape(source)), "value": "20 10 0"}"#
        let renderer = try SceneRenderer(
            device: device, package: try scriptedPackage(scriptedFiles(scene: scriptedScene(origin))), assets: nil)
        let image = try renderer.renderImage(width: 100, height: 50)
        #expect(scriptedPixel(image, 75, 25) == [255, 0, 0])
        #expect(scriptedPixel(image, 20, 40) == [0, 0, 0])
    }
}

/// 把脚本源码塞进 JSON 字符串
private func jsonEscape(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self)
        .dropFirst().dropLast().description
}
