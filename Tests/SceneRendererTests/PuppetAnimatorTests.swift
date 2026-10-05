import Foundation
import Metal
import simd
import Testing
@testable import SceneRenderer
@testable import WallpaperFormats

private func pose(_ x: Float, _ y: Float, angle: Float = 0, scale: Float = 1) -> PuppetMesh.Pose {
    PuppetMesh.Pose(translation: SIMD3(x, y, 0), rotation: SIMD3(0, 0, angle), scale: SIMD3(scale, scale, 1))
}

private func bone(_ parent: Int?, _ local: PuppetMesh.Pose) -> PuppetMesh.Bone {
    PuppetMesh.Bone(parent: parent, bindLocal: local.matrix)
}

private func vertex(_ x: Float, _ y: Float, bone: UInt32) -> PuppetMesh.Vertex {
    PuppetMesh.Vertex(position: SIMD3(x, y, 0), uv: .zero, boneIndices: SIMD4(bone, 0, 0, 0), boneWeights: SIMD4(1, 0, 0, 0))
}

/// 两根骨骼：根在 (100, 0)，子骨骼在根右边 50（世界坐标 (150, 0)）。顶点 0 绑根，顶点 1 绑子骨骼
private let bones = [bone(nil, pose(100, 0)), bone(0, pose(50, 0))]
private let vertices = [vertex(100, 10, bone: 0), vertex(160, 0, bone: 1)]

private func animation(
    id: Int, mode: String = "loop", fps: Float = 10, root: [PuppetMesh.Pose], child: [PuppetMesh.Pose],
    drivesBone: [Bool] = []
) -> PuppetMesh.Animation {
    PuppetMesh.Animation(
        id: id, name: "", mode: mode, fps: fps, frameCount: root.count - 1, tracks: [root, child],
        drivesBone: drivesBone)
}

private func animator(_ layers: [PuppetAnimator.Layer]) throws -> PuppetAnimator {
    let mesh = PuppetMesh(vertices: vertices, indices: [0, 1, 0], bones: bones, animations: layers.map(\.animation))
    return PuppetAnimator(
        mesh: mesh, layers: layers, world: matrix_identity_float4x4, uvScale: SIMD2(1, 1),
        device: try #require(MTLCreateSystemDefaultDevice()))
}

private func positions(_ animator: PuppetAnimator, at time: Float) throws -> [SIMD2<Float>] {
    let buffer = try #require(animator.vertexBuffer(at: time))
    let values = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: vertices.count)
    return (0..<vertices.count).map { SIMD2(values[$0].x, values[$0].y) }
}

private func close(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ tolerance: Float = 0.01) -> Bool {
    simd_length(a - b) < tolerance
}

@Suite struct PuppetAnimatorTests {
    /// 非叠加的"局部"层（Xiami 的 Rightarm / Leftarm）：只动它驱动的骨骼。不驱动的骨骼里存的是编辑器
    /// 留下的值（可能离绑定姿势很远），照搬会把别的部位甩开——这里根骨骼的残留值在 x = 900
    @Test func layersOnlyMoveTheBonesTheyDrive() throws {
        let base = animation(id: 1, root: [pose(100, 0), pose(100, 0)], child: [pose(50, 0), pose(50, 0)])
        let arm = animation(
            id: 2, root: [pose(900, 300), pose(900, 300)], child: [pose(50, 40), pose(50, 40)],
            drivesBone: [false, true])
        let puppet = try animator([
            .init(animation: base, blend: 1, rate: 1, additive: false),
            .init(animation: arm, blend: 1, rate: 1, additive: false),
        ])
        let result = try positions(puppet, at: 0)
        #expect(close(result[0], SIMD2(100, 10)))   // 根骨骼不归 arm 层管：留在原处
        #expect(close(result[1], SIMD2(160, 40)))   // 子骨骼归它管：往上挪 40
    }

    /// mirror：正着播到最后一帧，再倒着播回来
    @Test func mirrorModePlaysBackAndForth() throws {
        let track = animation(
            id: 1, mode: "mirror", fps: 1, root: [pose(100, 0), pose(200, 0), pose(300, 0)],
            child: [pose(50, 0), pose(50, 0), pose(50, 0)])
        #expect(PuppetAnimator.framePosition(track, time: 1) == 1)
        #expect(PuppetAnimator.framePosition(track, time: 2) == 2)
        #expect(PuppetAnimator.framePosition(track, time: 3) == 1)
        #expect(PuppetAnimator.framePosition(track, time: 4) == 0)
        #expect(PuppetAnimator.framePosition(track, time: 5) == 1)
    }

    @Test func bindPoseLeavesVerticesInPlace() throws {
        let still = animation(id: 1, root: [pose(100, 0), pose(100, 0)], child: [pose(50, 0), pose(50, 0)])
        let result = try positions(animator([.init(animation: still, blend: 1, rate: 1, additive: true)]), at: 0.3)
        #expect(close(result[0], SIMD2(100, 10)))
        #expect(close(result[1], SIMD2(160, 0)))
    }

    @Test func movingTheRootMovesEverythingRigidly() throws {
        // Lucy 的入场动画就是这样：只有根骨骼在动
        let slide = animation(
            id: 1, mode: "single", fps: 1, root: [pose(400, -100), pose(100, 0)], child: [pose(50, 0), pose(50, 0)])
        let puppet = try animator([.init(animation: slide, blend: 1, rate: 1, additive: true)])
        let start = try positions(puppet, at: 0)
        #expect(close(start[0], SIMD2(400, -90)))
        #expect(close(start[1], SIMD2(460, -100)))
        let middle = try positions(puppet, at: 0.5)
        #expect(close(middle[0], SIMD2(250, -40)))
        // single 播完后停在最后一帧
        let after = try positions(puppet, at: 5)
        #expect(close(after[0], SIMD2(100, 10)))
    }

    /// 起始进度：WE 的 shared.offsetedStartAni(animation, percentage) 把这一层往后挪
    /// percentage × 时长；循环动画相当于换个相位，所以要和不带偏移、往后播同样时间的姿势一致
    @Test func startOffsetShiftsThePhaseOfALoopingAnimation() throws {
        // 3 帧、2 fps 的循环（时长 1 秒）：根骨骼从 x=100 走到 300
        let track = animation(
            id: 1, fps: 2, root: [pose(100, 0), pose(200, 0), pose(300, 0)],
            child: [pose(50, 0), pose(50, 0), pose(50, 0)])

        let shifted = try positions(
            animator([.init(animation: track, blend: 1, rate: 1, additive: true, startOffset: 0.4)]), at: 0)
        #expect(close(shifted[0], SIMD2(180, 10)))  // 0.4 秒 = 第 0.8 帧

        let plain = try positions(animator([.init(animation: track, blend: 1, rate: 1, additive: true)]), at: 0.4)
        #expect(close(shifted[0], plain[0]))
        #expect(close(shifted[1], plain[1]))

        // 多挪一整圈（1 秒）相位不变
        let wrapped = try positions(
            animator([.init(animation: track, blend: 1, rate: 1, additive: true, startOffset: 1.4)]), at: 0)
        #expect(close(wrapped[0], shifted[0], 0.02))
    }

    @Test func childRotationPivotsAroundTheChildBone() throws {
        let turn = animation(
            id: 1, root: [pose(100, 0), pose(100, 0)], child: [pose(50, 0, angle: .pi / 2), pose(50, 0, angle: .pi / 2)])
        let result = try positions(animator([.init(animation: turn, blend: 1, rate: 1, additive: true)]), at: 0)
        // 子骨骼在 (150, 0)，顶点在它右边 10，转 90° 后到它上面 10
        #expect(close(result[1], SIMD2(150, 10)))
        #expect(close(result[0], SIMD2(100, 10)))
    }

    @Test func loopsInterpolateBetweenFramesAndWrap() throws {
        let bob = animation(
            id: 1, fps: 10, root: [pose(100, 0), pose(100, 10), pose(100, 0)], child: [pose(50, 0), pose(50, 0), pose(50, 0)])
        let puppet = try animator([.init(animation: bob, blend: 1, rate: 1, additive: true)])
        #expect(close(try positions(puppet, at: 0.05)[0], SIMD2(100, 15)))  // 第 0.5 帧：y + 5
        #expect(close(try positions(puppet, at: 0.1)[0], SIMD2(100, 20)))   // 第 1 帧：y + 10
        #expect(close(try positions(puppet, at: 0.25)[0], SIMD2(100, 15)))  // 2 帧一圈，第 2.5 帧 = 第 0.5 帧
        // rate 加倍，同一时刻走到两倍的位置
        let fast = try animator([.init(animation: bob, blend: 1, rate: 2, additive: true)])
        #expect(close(try positions(fast, at: 0.05)[0], SIMD2(100, 20)))
    }

    @Test func additiveLayersSumTheirOffsets() throws {
        let right = animation(id: 1, root: [pose(110, 0), pose(110, 0)], child: [pose(50, 0), pose(50, 0)])
        let up = animation(id: 2, root: [pose(100, 20), pose(100, 20)], child: [pose(50, 0), pose(50, 0)])
        let both = try positions(animator([
            .init(animation: right, blend: 1, rate: 1, additive: true),
            .init(animation: up, blend: 0.5, rate: 1, additive: true),
        ]), at: 0)
        #expect(close(both[0], SIMD2(110, 20)))

        // 非 additive 的层按权重覆盖前面的结果
        let override = try positions(animator([
            .init(animation: right, blend: 1, rate: 1, additive: true),
            .init(animation: up, blend: 1, rate: 1, additive: false),
        ]), at: 0)
        #expect(close(override[0], SIMD2(100, 30)))
    }

    @Test func scaleAnimatesAroundTheBone() throws {
        let grow = animation(
            id: 1, mode: "single", fps: 1, root: [pose(100, 0, scale: 0.8), pose(100, 0)], child: [pose(50, 0), pose(50, 0)])
        let result = try positions(animator([.init(animation: grow, blend: 1, rate: 1, additive: true)]), at: 0)
        #expect(close(result[0], SIMD2(100, 8)))
        #expect(close(result[1], SIMD2(148, 0)))
    }

    @Test func angleDifferenceTakesTheShortWay() {
        let difference = PuppetAnimator.angleDifference(SIMD3(0, 0, 3.1), SIMD3(0, 0, -3.1))
        #expect(abs(difference.z - (6.2 - 2 * .pi)) < 1e-4)
    }
}
