import Foundation
import simd
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 坏文件里的数不能让 App 崩掉或卡死，以及几处为省 CPU 做的改动不改变结果
@Suite struct RobustnessAndCostTests {
    private static let origin = [SIMD3<Float>](repeating: .zero, count: 8)

    private static func simulation(_ json: String) throws -> ParticleSimulation {
        ParticleSimulation(definition: try ParticleDefinition(json: Data(json.utf8)))
    }

    /// 一次性发射个数写成负数：`0..<负数` 会直接崩；写成 1e15：要么转 Int 时崩，要么空转上万亿次卡死
    @Test(arguments: ["-5", "1e15", "1e30"])
    func absurdInstantaneousCountsNeitherCrashNorHang(_ value: String) throws {
        let simulation = try Self.simulation("""
        {"material": "m", "maxcount": 50,
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": \(value), "controlpoint": 1e20}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                         {"name": "mapsequencearoundcontrolpoint", "count": 1e20, "controlpoint": -1e20}],
         "operator": [{"name": "movement"}, {"name": "controlpointattract", "controlpoint": 1e20, "scale": 1}]}
        """)
        for _ in 0..<3 { simulation.step(1.0 / 30, controlPoints: Self.origin) }
        #expect(simulation.particles.count <= 50)
    }

    /// 噪声的格点坐标改成标量夹取后转 Int32：正常范围内和原来逐个 `Int(saturating:)` 再截断的结果逐位一致，
    /// NaN / 无穷大 / 极大的数也给有限值
    @Test func noiseMatchesTheOriginalFormulaAndSurvivesBadInput() {
        func reference(_ p: SIMD3<Float>, _ channel: UInt32) -> Float {
            let cell = p.rounded(.down)
            let f = p - cell
            let u = f * f * (SIMD3(repeating: 3) - 2 * f)
            let cx = Int32(truncatingIfNeeded: Int(saturating: cell.x))
            let cy = Int32(truncatingIfNeeded: Int(saturating: cell.y))
            let cz = Int32(truncatingIfNeeded: Int(saturating: cell.z))
            func corner(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float {
                let key = UInt32(bitPattern: cx &+ dx) &* 73_856_093 ^ UInt32(bitPattern: cy &+ dy) &* 19_349_663
                    ^ UInt32(bitPattern: cz &+ dz) &* 83_492_791
                return ParticleRandom.hash(key, channel) * 2 - 1
            }
            let x00 = corner(0, 0, 0) + (corner(1, 0, 0) - corner(0, 0, 0)) * u.x
            let x10 = corner(0, 1, 0) + (corner(1, 1, 0) - corner(0, 1, 0)) * u.x
            let x01 = corner(0, 0, 1) + (corner(1, 0, 1) - corner(0, 0, 1)) * u.x
            let x11 = corner(0, 1, 1) + (corner(1, 1, 1) - corner(0, 1, 1)) * u.x
            let y0 = x00 + (x10 - x00) * u.y
            let y1 = x01 + (x11 - x01) * u.y
            return y0 + (y1 - y0) * u.z
        }
        var random = ParticleRandom(seed: 7)
        for _ in 0..<2000 {
            let p = SIMD3(random.range(-5000, 5000), random.range(-5000, 5000), random.range(-50, 50))
            for channel in UInt32(0)..<3 {
                #expect(ParticleNoise.value(p, channel).bitPattern == reference(p, channel).bitPattern)
            }
        }
        // NaN / 无穷大进来不能崩（结果是 NaN，和原来一样）；有限但极大的数给有限值
        _ = ParticleNoise.vector(SIMD3<Float>(.nan, 0, 0))
        _ = ParticleNoise.vector(SIMD3<Float>(Float.infinity, -Float.infinity, 1))
        #expect(all(ParticleNoise.vector(SIMD3<Float>(1e30, -1e30, 3e38)) .== ParticleNoise.vector(SIMD3<Float>(1e30, -1e30, 3e38))))
    }

    /// 属性脚本每帧都抛异常（作者把引用了未定义变量的拖拽脚本挂到 visible 上）：异常在 JS 里接住，
    /// 照样每帧调用（和 WE 一样），哪天不再抛了就用它的结果；出错原因照旧记下来
    @Test func throwingScriptsKeepRunningAndCanRecover() throws {
        let source = """
        'use strict';
        let calls = 0;
        export function update(value) {
            calls += 1;
            if (calls <= 3) { return weizhi; }
            return calls % 2 === 0;
        }
        """
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        for _ in 0..<3 { #expect(script.updateBool(false) == nil) }
        #expect(script.problem?.contains("ReferenceError") == true, "\(script.problem ?? "")")
        #expect(script.updateBool(false) == true)
        #expect(script.updateBool(true) == false)
    }

    /// `throw` 的不是 Error（甚至是 undefined）也算出错，不能当成"脚本返回了 undefined"
    @Test func nonErrorThrowsAreStillReportedAsErrors() throws {
        let source = "export function update(value) { throw undefined; }"
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        #expect(script.updateNumber(1) == nil)
        #expect(script.problem != nil)
    }

    /// 文字脚本不返回值、而是自己写 thisLayer.text：返回 undefined 不是出错
    @Test func scriptsReturningUndefinedOnPurposeAreNotErrors() throws {
        let source = "export function update(value) { thisLayer.text = 'twelve'; }"
        let script = try #require(SceneScript(source: source, properties: nil, environment: .init()))
        #expect(script.updateText("x") == "twelve")
        #expect(script.problem == nil, "\(script.problem ?? "")")
    }
}
