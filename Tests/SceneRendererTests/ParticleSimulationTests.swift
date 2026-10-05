import Foundation
import simd
import Testing
@testable import SceneRenderer
import WallpaperFormats

private func definition(_ json: String) throws -> ParticleDefinition {
    try ParticleDefinition(json: Data(json.utf8))
}

private let origin = [SIMD3<Float>](repeating: .zero, count: 8)

private func run(_ simulation: ParticleSimulation, seconds: Float, step: Float = 1.0 / 30) {
    var elapsed: Float = 0
    while elapsed < seconds - 0.0001 {
        simulation.step(step, controlPoints: origin)
        elapsed += step
    }
}

@Suite struct ParticleSimulationTests {
    @Test func emitsAtTheConfiguredRateUpToMaxCount() throws {
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1000,
         "emitter": [{"name": "sphererandom", "rate": 20, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """))
        run(simulation, seconds: 2)
        #expect((39...41).contains(simulation.particles.count))

        let capped = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 10,
         "emitter": [{"name": "sphererandom", "rate": 100}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """))
        run(capped, seconds: 2)
        #expect(capped.particles.count == 10)
    }

    @Test func particlesDieAfterTheirLifetime() throws {
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1000,
         "emitter": [{"name": "sphererandom", "rate": 10}],
         "initializer": [{"name": "lifetimerandom", "min": 1, "max": 1}]}
        """))
        run(simulation, seconds: 5)
        // 稳定状态：活着的是最近 1 秒内出生的
        #expect((9...11).contains(simulation.particles.count))
        #expect(simulation.particles.allSatisfy { $0.age < 1 })
    }

    @Test func instanceOverrideScalesEmissionAndSize() throws {
        var override = ParticleOverride()
        override.count = 0.5
        override.size = 2
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1000,
         "emitter": [{"name": "sphererandom", "rate": 20}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "sizerandom", "min": 10, "max": 10}]}
        """), override: override)
        run(simulation, seconds: 2)
        #expect((19...21).contains(simulation.particles.count))
        #expect(simulation.particles.allSatisfy { $0.drawnSize == 20 })
    }

    @Test func sphereEmitterRespectsDistanceAndDirections() throws {
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1000,
         "emitter": [{"name": "sphererandom", "rate": 300, "distancemin": 100, "distancemax": 200,
                      "directions": "1 1 0", "origin": "50 0 0"}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """))
        run(simulation, seconds: 1)
        #expect(simulation.particles.count > 200)
        for particle in simulation.particles {
            #expect(particle.position.z == 0)
            #expect(simd_length(particle.position - SIMD3(50, 0, 0)) <= 200.01)
        }
    }

    @Test func boxEmitterStaysInsideTheBox() throws {
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1000,
         "emitter": [{"name": "boxrandom", "rate": 300, "distancemax": "2000 800 0", "origin": "0 1000 0"}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """))
        run(simulation, seconds: 1)
        #expect(simulation.particles.allSatisfy { abs($0.position.x) <= 2000 && abs($0.position.y - 1000) <= 800 })
        // 分布要铺开，不能都挤在中间
        #expect(simulation.particles.contains { $0.position.x > 1500 })
        #expect(simulation.particles.contains { $0.position.x < -1500 })
    }

    @Test func movementAppliesVelocityGravityAndDrag() throws {
        let falling = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 1000, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"}],
         "operator": [{"name": "movement", "gravity": "0 -100 0"}]}
        """))
        run(falling, seconds: 1)
        let particle = try #require(falling.particles.first)
        #expect(abs(particle.position.x - 10) < 0.5)
        #expect(particle.position.y < -45 && particle.position.y > -55)  // ½·g·t² ≈ 50

        // 没有 movement 算子时速度不会让粒子移动（WE 文档：速度要配合 movement 才生效）
        let still = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 1000, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"}]}
        """))
        run(still, seconds: 1)
        #expect(still.particles.first?.position == .zero)

        let dragged = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 1000, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "velocityrandom", "min": "100 0 0", "max": "100 0 0"}],
         "operator": [{"name": "movement", "drag": 5}]}
        """))
        run(dragged, seconds: 2)
        #expect((dragged.particles.first?.velocity.x ?? 100) < 1)
    }

    @Test func alphaFadeUsesFractionsOfLifetime() throws {
        // fadeintime 0.2：寿命的前 20% 淡入；fadeouttime 0.5：从寿命的 50% 开始淡出
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 1000}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
         "operator": [{"name": "alphafade", "fadeintime": 0.2, "fadeouttime": 0.5}]}
        """))
        func alpha(at seconds: Float) -> Float {
            simulation.reset()
            simulation.step(0.001, controlPoints: origin)
            run(simulation, seconds: seconds, step: 0.1)
            return simulation.particles.first?.drawnAlpha ?? -1
        }
        #expect(abs(alpha(at: 1) - 0.5) < 0.02)
        #expect(abs(alpha(at: 3) - 1) < 0.02)
        #expect(abs(alpha(at: 7.5) - 0.5) < 0.02)
    }

    @Test func sizeChangeInterpolatesBetweenTimes() throws {
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 1,
         "emitter": [{"name": "sphererandom", "rate": 1000}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}, {"name": "sizerandom", "min": 100, "max": 100}],
         "operator": [{"name": "sizechange", "starttime": 0.5, "endtime": 1, "startvalue": 1, "endvalue": 0.2}]}
        """))
        simulation.step(0.001, controlPoints: origin)
        run(simulation, seconds: 4, step: 0.1)
        #expect(abs((simulation.particles.first?.drawnSize ?? 0) - 100) < 0.5)
        run(simulation, seconds: 3.5, step: 0.1)
        #expect(abs((simulation.particles.first?.drawnSize ?? 0) - 60) < 2)
    }

    @Test func colorsAreNormalizedAndBlendedBetweenTwoColors() throws {
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 500,
         "emitter": [{"name": "sphererandom", "rate": 500}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "colorrandom", "min": "255 0 0", "max": "0 0 255"}]}
        """))
        run(simulation, seconds: 1)
        for particle in simulation.particles {
            #expect(abs(particle.color.x + particle.color.z - 1) < 0.001)
            #expect(particle.color.y == 0)
        }
    }

    @Test func sameSeedGivesSameParticles() throws {
        let json = """
        {"material": "m", "maxcount": 100,
         "emitter": [{"name": "sphererandom", "rate": 50, "distancemax": 300}],
         "initializer": [{"name": "lifetimerandom", "min": 1, "max": 3}, {"name": "sizerandom", "min": 5, "max": 50}],
         "operator": [{"name": "movement", "gravity": "0 -10 0"}, {"name": "turbulence", "speedmin": 50, "speedmax": 60}]}
        """
        let first = ParticleSimulation(definition: try definition(json), seed: 7)
        let second = ParticleSimulation(definition: try definition(json), seed: 7)
        run(first, seconds: 2)
        run(second, seconds: 2)
        #expect(first.particles.map(\.position) == second.particles.map(\.position))
        first.reset()
        run(first, seconds: 2)
        #expect(first.particles.map(\.position) == second.particles.map(\.position))
    }

    @Test func pointerControlPointRepelsParticles() throws {
        // WE 自带 examplecursoravoid 的做法：控制点 1 跟随鼠标，scale 为负就是推开
        let json = """
        {"material": "m", "maxcount": 1,
         "controlpoint": [{"id": 1, "flags": 1}],
         "emitter": [{"name": "sphererandom", "rate": 1000, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}],
         "operator": [{"name": "movement"},
                      {"name": "controlpointattract", "controlpoint": 1, "scale": -5000, "threshold": 64}]}
        """
        let simulation = ParticleSimulation(definition: try definition(json))
        #expect(simulation.controlPointFollowsPointer[1])
        var points = origin
        points[1] = SIMD3(20, 0, 0)
        for _ in 0..<10 { simulation.step(1.0 / 30, controlPoints: points) }
        #expect((simulation.particles.first?.position.x ?? 0) < -5)
    }

    @Test func followingParticlesDieWithTheirAnchor() throws {
        let child = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 10,
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 2, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}]}
        """))
        child.step(0.1, controlPoints: origin, anchors: [7: SIMD3(100, 0, 0)], newAnchors: [7])
        #expect(child.particles.count == 2)
        #expect(child.particles.allSatisfy { $0.anchor == 7 && $0.position == .zero })
        child.step(0.1, controlPoints: origin, anchors: [7: SIMD3(120, 0, 0)])
        #expect(child.particles.count == 2)
        child.step(0.1, controlPoints: origin, anchors: [:])
        #expect(child.particles.isEmpty)
    }

    @Test func unknownComponentsAreReported() throws {
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "operator": [{"name": "vortex_v2"}, {"name": "movement"}], "emitter": [{"name": "layerimage"}]}
        """))
        #expect(simulation.unsupported.sorted() == ["发射器 layerimage", "算子 vortex_v2"])
    }

    @Test func hsvConversionMatchesKnownColors() {
        let red = ParticleSimulation.hsvToRGB(0, 1, 1)
        let green = ParticleSimulation.hsvToRGB(1.0 / 3, 1, 1)
        let gray = ParticleSimulation.hsvToRGB(0.7, 0, 0.5)
        #expect(simd_length(red - SIMD3(1, 0, 0)) < 0.001)
        #expect(simd_length(green - SIMD3(0, 1, 0)) < 0.001)
        #expect(simd_length(gray - SIMD3(0.5, 0.5, 0.5)) < 0.001)
    }

    /// ropetrail 的位置历史：环形缓冲按时间递增给出采样，超出长度的丢掉，容量封顶
    @Test func trailHistoryKeepsANewestWindowInOrder() {
        var history = ParticleSimulation.TrailHistory(capacity: 4)
        for index in 0..<6 {
            history.append(.init(age: Float(index), position: SIMD3(Float(index), 0, 0), alpha: 1, size: 10))
            history.drop(olderThan: Float(index) - 2.5)
        }
        // 每次 append 之后丢掉比"当前时间 - 2.5"更早的，所以最后剩 age 3、4、5
        #expect((0..<history.count).map { history[$0].age } == [3, 4, 5], "按时间递增")
        #expect((0..<history.count).map { history[$0].position.x } == [3, 4, 5], "位置跟着采样走")
        #expect(history.capacity == 4)
    }

    /// ropetrail 画法要在模拟时记录位置历史；其他画法不记录（省的每帧白搬内存）
    @Test func onlyRopeTrailSystemsRecordPositionHistory() throws {
        let json = """
        {"material": "m", "maxcount": 10,
         "emitter": [{"name": "sphererandom", "rate": 10, "distancemax": 0, "speedmin": 100, "speedmax": 100}],
         "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}],
         "operator": [{"name": "movement"}]}
        """
        let trail = ParticleSimulation(definition: try definition(json), trailLength: 0.3)
        run(trail, seconds: 0.5)
        #expect(!trail.particles.isEmpty)
        let samples = trail.particles.map(\.trail.count)
        #expect(samples.allSatisfy { $0 >= 1 }, "每个粒子至少有一条采样，得到 \(samples)")
        // 0.3 秒 × 30 步 + 出生那一条 + 余量 → 上限 11
        #expect(samples.allSatisfy { $0 <= 11 }, "历史长度该被时长限制，得到 \(samples)")
        // 活得最久的那个粒子应该攒了整段历史；位置跟着粒子走（速度 +x）
        let oldest = trail.particles.max { $0.trail.count < $1.trail.count }!
        #expect(oldest.trail.count > 5, "最老的粒子该有整段历史，得到 \(oldest.trail.count)")
        #expect(oldest.trail[oldest.trail.count - 1].age > oldest.trail[0].age, "采样按时间递增")
        #expect(oldest.trail[oldest.trail.count - 1].position != oldest.trail[0].position, "移动算子让位置变了")

        let sprite = ParticleSimulation(definition: try definition(json))
        run(sprite, seconds: 0.5)
        #expect(sprite.particles.allSatisfy { $0.trail.isEmpty }, "不画带子就不记历史")
    }

    /// mapsequence* 的序列：repeat 绕圈、mirror 折返，结果落在 bounds 之间
    @Test func controlPointSequenceRepeatsOrMirrors() {
        let repeat5 = ParticleSimulation.ControlPointSequence(count: 5, bounds: 0...1, isMirror: false)
        #expect((0..<5).map { repeat5.value(at: $0) } == [0, 0.2, 0.4, 0.6, 0.8])
        #expect(repeat5.value(at: 5) == 0, "绕回起点")

        let mirror = ParticleSimulation.ControlPointSequence(count: 5, bounds: 0...1, isMirror: true)
        let outward = (0..<6).map { mirror.value(at: $0) }
        #expect(zip(outward, [0, 0.2, 0.4, 0.6, 0.8, 1] as [Float]).allSatisfy { abs($0 - $1) < 0.001 },
                "折返要走到另一头，得到 \(outward)")
        let back = (6..<11).map { mirror.value(at: $0) }
        #expect(zip(back, [0.8, 0.6, 0.4, 0.2, 0] as [Float]).allSatisfy { abs($0 - $1) < 0.001 },
                "再折回来，得到 \(back)")

        let bounds = ParticleSimulation.ControlPointSequence(count: 4, bounds: 0.5...1, isMirror: false)
        #expect(bounds.value(at: 0) == 0.5)
        #expect(bounds.value(at: 2) == 0.75)
    }

    /// mapsequencearoundcontrolpoint：粒子保持到控制点的距离，角度按序列摆成 count 个出生点
    @Test func mapSequenceAroundControlPointPlacesParticlesOnACircle() throws {
        func definitionWith(_ initializer: String) throws -> ParticleDefinition {
            try definition("""
            {"material": "m", "maxcount": 10,
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 4, "distancemax": 100,
                          "distancemin": 100}],
             "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100}\(initializer)],
             "operator": [{"name": "movement"}]}
            """)
        }
        let simulation = ParticleSimulation(definition: try definitionWith(
            #",{"name": "mapsequencearoundcontrolpoint", "count": 4, "bounds": "0 1", "limitbehavior": "repeat"}"#))
        // 同一条随机序列、没有这个初始化器的对照：距离该完全一样，角度才是被摆过的部分
        let plain = ParticleSimulation(definition: try definitionWith(""))
        let points = [SIMD3<Float>(50, 20, 0)] + [SIMD3<Float>](repeating: .zero, count: 7)
        simulation.step(0.1, controlPoints: points)
        plain.step(0.1, controlPoints: points)
        #expect(simulation.particles.count == 4)
        #expect(plain.particles.count == 4)
        for (index, particle) in simulation.particles.enumerated() {
            let radial = particle.position - points[0]
            let original = plain.particles[index].position - points[0]
            #expect(abs(simd_length(SIMD2(radial.x, radial.y)) - simd_length(SIMD2(original.x, original.y))) < 0.01,
                    "到控制点的距离和发射器给的一样")
            let angle = atan2(radial.y, radial.x)
            let expected = Float(index) * .pi / 2
            let difference = atan2(sin(angle - expected), cos(angle - expected))
            #expect(abs(difference) < 0.01, "第 \(index) 个粒子在 \(index)×90°")
        }
    }

    /// mapsequencebetweencontrolpoints：粒子落在两个控制点之间的序列上
    @Test func mapSequenceBetweenControlPointsSpreadsAlongTheLine() throws {
        let simulation = ParticleSimulation(definition: try definition("""
        {"material": "m", "maxcount": 10,
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 5, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 100, "max": 100},
                         {"name": "mapsequencebetweencontrolpoints", "count": 5, "limitbehavior": "mirror"}],
         "operator": [{"name": "movement"}]}
        """))
        var points = [SIMD3<Float>](repeating: .zero, count: 8)
        points[0] = SIMD3(0, 0, 0)
        points[1] = SIMD3(400, 0, 0)
        simulation.step(0.1, controlPoints: points)
        #expect(simulation.particles.count == 5)
        let xs = simulation.particles.map { $0.position.x }
        // mirror：先 0、0.2、0.4、0.6、0.8 往外铺，下一轮从 1.0 折回来
        #expect(zip(xs, [0, 80, 160, 240, 320] as [Float]).allSatisfy { abs($0 - $1) < 0.01 },
                "五个粒子均匀铺在两点之间，得到 \(xs)")
    }
}
