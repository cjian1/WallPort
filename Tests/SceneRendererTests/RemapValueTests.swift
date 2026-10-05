import Foundation
import simd
import Testing
@testable import SceneRenderer
import WallpaperFormats

private func remapDefinition(_ json: String) throws -> ParticleDefinition {
    try ParticleDefinition(json: Data(json.utf8))
}

private let remapOrigin = [SIMD3<Float>](repeating: .zero, count: 8)

private func remapRun(_ simulation: ParticleSimulation, seconds: Float, step: Float = 1.0 / 30) {
    var elapsed: Float = 0
    while elapsed < seconds - 0.0001 {
        simulation.step(step, controlPoints: remapOrigin)
        elapsed += step
    }
}

/// 输入区间归一化到 0–1、再按输出区间插值：WE 文档里就是这么描述的
@Suite struct RemapValueMappingTests {
    private func colorRemap(clampInput: Bool = false) -> ParticleSimulation.RemapValue {
        ParticleSimulation.RemapValue(
            input: .distanceToControlPoint(1), inputRangeMin: [150], inputRangeMax: [200], output: .color,
            outputRangeMin: [1, 0, 0], outputRangeMax: [0, 0, 1], combine: .remap,
            clampInput: clampInput, clampOutput: false, transform: nil, transformScale: 1)
    }

    /// WE 自带的预览场景就是这一组数：离控制点 150 是红、200 是蓝
    @Test func mapsDistanceToColor() {
        let remap = colorRemap()
        #expect(remap.map([150]) == [1, 0, 0])
        #expect(remap.map([175]) == [0.5, 0, 0.5])
        #expect(remap.map([200]) == [0, 0, 1])
        // 不钳制时超出区间会外推
        #expect(remap.map([250]) == [-1, 0, 2])
        // 钳制输入后停在区间端点
        #expect(colorRemap(clampInput: true).map([250]) == [0, 0, 1])
    }

    @Test func clampsOutputWhenAsked() {
        let remap = ParticleSimulation.RemapValue(
            input: .lifetime, inputRangeMin: [0], inputRangeMax: [1], output: .size,
            outputRangeMin: [-5], outputRangeMax: [7], combine: .remap, clampInput: true, clampOutput: true,
            transform: nil, transformScale: 1)
        #expect(remap.map([0]) == [-5])
        #expect(remap.map([0.5]) == [1])
        #expect(remap.map([1]) == [7])
        #expect(remap.map([3]) == [7])
    }

    /// Assign / Multiply / Add / Subtract 四种组合方式
    @Test func combinesWithTheExistingValue() {
        func combined(_ operation: ParticleSimulation.RemapValue.Combine) -> Float {
            let remap = ParticleSimulation.RemapValue(
                input: .lifetime, inputRangeMin: [0], inputRangeMax: [1], output: .speed,
                outputRangeMin: [2], outputRangeMax: [2], combine: operation, clampInput: true, clampOutput: false,
                transform: nil, transformScale: 1)
            return remap.map([0.5])[0]
        }
        #expect(combined(.remap) == 2)
        #expect(combined(.multiply) == 2)
        #expect(combined(.add) == 2)
        #expect(combined(.subtract) == 2)
    }
}

@Suite struct RemapValueSimulationTests {
    /// 输出 size：按寿命把大小从 10 长到 30
    @Test func livingParticlesGrowByLifetime() throws {
        let simulation = ParticleSimulation(definition: try remapDefinition("""
        {"material": "m", "maxcount": 4,
         "emitter": [{"name": "sphererandom", "rate": 10, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 4, "max": 4},
                         {"name": "sizerandom", "min": 10, "max": 10},
                         {"name": "alpharandom", "min": 1, "max": 1}],
         "operator": [{"name": "remapvalue", "input": "lifetime", "inputrangemin": 0, "inputrangemax": 1,
                       "output": "size", "outputrangemin": 10, "outputrangemax": 30}]}
        """))
        #expect(simulation.unsupported.isEmpty)
        remapRun(simulation, seconds: 2)   // 寿命 4 秒，此时活了约一半
        let particle = try #require(simulation.particles.first)
        #expect(abs(particle.drawnSize - (10 + 20 * particle.life)) < 0.01)
        #expect(particle.drawnSize > 15 && particle.drawnSize < 25)
    }

    /// 输出 speed：改速度的模、方向不变
    @Test func speedOutputKeepsTheDirection() throws {
        let simulation = ParticleSimulation(definition: try remapDefinition("""
        {"material": "m", "maxcount": 4,
         "emitter": [{"name": "sphererandom", "rate": 10, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                         {"name": "velocityrandom", "min": "100 0 0", "max": "100 0 0"}],
         "operator": [{"name": "remapvalue", "input": "lifetime", "inputrangemin": 0, "inputrangemax": 1,
                       "output": "speed", "outputrangemin": 50, "outputrangemax": 50}]}
        """))
        remapRun(simulation, seconds: 1)
        let particle = try #require(simulation.particles.first)
        #expect(abs(simd_length(particle.velocity) - 50) < 0.01)
        #expect(particle.velocity.y == 0 && particle.velocity.z == 0)
        #expect(particle.velocity.x > 0)
    }

    /// 没写 input 时输入来自 transform function（雨滴就是这样），输出 velocity 会拿到有正有负的漂移
    @Test func transformFunctionProvidesTheInput() throws {
        let simulation = ParticleSimulation(definition: try remapDefinition("""
        {"material": "m", "maxcount": 200,
         "emitter": [{"name": "boxrandom", "rate": 200, "distancemax": "500 500 0"}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
         "operator": [{"name": "remapvalue", "operation": "remap", "output": "velocity",
                       "outputrangemin": "-200 -100 0", "outputrangemax": "200 -1000 0",
                       "transformfunction": "simplexnoise", "transforminputscale": 10}]}
        """))
        remapRun(simulation, seconds: 2)
        #expect(simulation.particles.count > 20)
        // 速度落在输出区间里：x 有正有负、y 一律向下（-100…-1000）
        let velocities = simulation.particles.map(\.velocity)
        #expect(velocities.contains { $0.x > 1 } && velocities.contains { $0.x < -1 })
        #expect(velocities.allSatisfy { $0.y <= -99.9 && $0.y >= -1000.1 })
        #expect(velocities.allSatisfy { abs($0.z) < 1.01 })
        // 噪声场是空间变化的，不是所有粒子一个值
        #expect(Set(velocities.map { Int($0.x.rounded()) }).count > 5)
    }

    /// 认不出来的输入/输出名字记进 unsupported，不静默丢掉
    @Test func unknownInputOrOutputIsReported() throws {
        let unknownInput = ParticleSimulation(definition: try remapDefinition("""
        {"material": "m", "emitter": [{"name": "sphererandom", "rate": 1}],
         "operator": [{"name": "remapvalue", "input": "somethingnew", "output": "size",
                       "outputrangemin": 1, "outputrangemax": 2}]}
        """))
        #expect(unknownInput.unsupported.contains { $0.contains("remapvalue 的输入 somethingnew") })

        let unknownOutput = ParticleSimulation(definition: try remapDefinition("""
        {"material": "m", "emitter": [{"name": "sphererandom", "rate": 1}],
         "operator": [{"name": "remapvalue", "input": "lifetime", "output": "gibberish",
                       "outputrangemin": 1, "outputrangemax": 2}]}
        """))
        #expect(unknownOutput.unsupported.contains { $0.contains("remapvalue 的输出") })
    }
}
