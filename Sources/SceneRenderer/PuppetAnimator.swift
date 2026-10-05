import Foundation
import Metal
import simd
import WallpaperFormats

/// 木偶骨骼动画：每帧按动画层算出每根骨骼的局部姿势，求世界矩阵，在 CPU 上蒙皮，写进顶点缓冲。
///
/// 动画层的混合（场景里 animationlayers[] 的顺序）：从绑定姿势出发，
/// - additive 层：把"动画姿势 − 绑定姿势"乘权重加上去（缩放按比例乘）；
/// - 非 additive 层：按权重从当前结果插值到动画姿势。
/// 每一层只碰它驱动的骨骼（`Animation.drives`）：比如"右臂"层只动右臂，身体其余部分留给别的层。
/// 播放方式 loop 循环；mirror 来回播；single 播一遍后停在最后一帧（Lucy 的入场动画就是这样）。
///
/// Lucy 有 2589 个顶点、61 根骨骼，蒙皮一次的计算量很小，放在 CPU 上比写专门的着色器简单。
final class PuppetAnimator {
    struct Layer {
        let animation: PuppetMesh.Animation
        let blend: Float
        let rate: Float
        let additive: Bool
        /// 这一层从动画的哪个时间点开始播（秒）。WE 的 `shared.offsetedStartAni` 用它把几层循环错开
        var startOffset: Float = 0
    }

    let layers: [Layer]
    private let mesh: PuppetMesh
    private let bindPoses: [PuppetMesh.Pose]
    private let inverseBindWorld: [simd_float4x4]
    /// 模型坐标 → 画布坐标（图层的世界变换）
    private let world: simd_float4x4
    private let uvScale: SIMD2<Float>
    private let device: any MTLDevice
    private var buffers: [(any MTLBuffer)?] = [nil, nil, nil]
    private var frameIndex = 0
    private let lock = NSLock()

    init(mesh: PuppetMesh, layers: [Layer], world: simd_float4x4, uvScale: SIMD2<Float>, device: any MTLDevice) {
        self.mesh = mesh
        self.layers = layers
        self.world = world
        self.uvScale = uvScale
        self.device = device
        bindPoses = mesh.bones.map { PuppetMesh.Pose(matrix: $0.bindLocal) }
        var bindWorld: [simd_float4x4] = []
        for bone in mesh.bones {
            bindWorld.append(bone.parent.map { bindWorld[$0] * bone.bindLocal } ?? bone.bindLocal)
        }
        inverseBindWorld = bindWorld.map(\.inverse)
    }

    /// 某一时刻每根骨骼的局部姿势
    func localPoses(at time: Float) -> [PuppetMesh.Pose] {
        var poses = bindPoses
        for layer in layers {
            let animation = layer.animation
            let position = Self.framePosition(animation, time: time * layer.rate + layer.startOffset)
            for bone in poses.indices where animation.drives(bone) {
                let target = Self.sample(animation.tracks[bone], at: position)
                let bind = bindPoses[bone]
                if layer.additive {
                    poses[bone].translation += (target.translation - bind.translation) * layer.blend
                    poses[bone].rotation += Self.angleDifference(target.rotation, bind.rotation) * layer.blend
                    let ratio = target.scale / simd_max(bind.scale, SIMD3(repeating: 1e-6))
                    poses[bone].scale *= SIMD3(repeating: 1) + (ratio - SIMD3(repeating: 1)) * layer.blend
                } else {
                    poses[bone].translation += (target.translation - poses[bone].translation) * layer.blend
                    poses[bone].rotation += Self.angleDifference(target.rotation, poses[bone].rotation) * layer.blend
                    poses[bone].scale += (target.scale - poses[bone].scale) * layer.blend
                }
            }
        }
        return poses
    }

    /// 这一时刻每根骨骼在模型坐标里的变换（子图层挂在骨骼挂点上时要用）
    func boneWorlds(at time: Float) -> [simd_float4x4] {
        var worldMatrices: [simd_float4x4] = []
        worldMatrices.reserveCapacity(mesh.bones.count)
        for (index, pose) in localPoses(at: time).enumerated() {
            let local = pose.matrix
            worldMatrices.append(mesh.bones[index].parent.map { worldMatrices[$0] * local } ?? local)
        }
        return worldMatrices
    }

    /// 蒙皮矩阵：当前世界矩阵 × 绑定世界矩阵的逆
    func skinMatrices(at time: Float) -> [simd_float4x4] {
        zip(boneWorlds(at: time), inverseBindWorld).map { $0 * $1 }
    }

    /// 动画里的帧位置（可以带小数）。loop 取模；mirror 正着播完再倒着播回来；single 播到最后一帧为止
    static func framePosition(_ animation: PuppetMesh.Animation, time: Float) -> Float {
        let frames = Float(max(animation.frameCount, 1))
        let position = max(0, time) * animation.fps
        switch animation.mode {
        case "single":
            return min(position, frames)
        case "mirror":
            let cycle = position.truncatingRemainder(dividingBy: 2 * frames)
            return cycle <= frames ? cycle : 2 * frames - cycle
        default:
            return position.truncatingRemainder(dividingBy: frames)
        }
    }

    static func sample(_ track: [PuppetMesh.Pose], at position: Float) -> PuppetMesh.Pose {
        guard let last = track.indices.last else { return PuppetMesh.Pose(translation: .zero, rotation: .zero, scale: SIMD3(1, 1, 1)) }
        let clamped = min(max(position, 0), Float(last))
        let index = min(max(Int(saturating: clamped.rounded(.down)), 0), last)
        let next = min(index + 1, last)
        let t = clamped - Float(index)
        let a = track[index]
        let b = track[next]
        return PuppetMesh.Pose(
            translation: a.translation + (b.translation - a.translation) * t,
            rotation: a.rotation + angleDifference(b.rotation, a.rotation) * t,
            scale: a.scale + (b.scale - a.scale) * t)
    }

    /// b − a，每个分量取最短的方向（−π…π）
    static func angleDifference(_ b: SIMD3<Float>, _ a: SIMD3<Float>) -> SIMD3<Float> {
        var difference = b - a
        for axis in 0..<3 {
            difference[axis] = remainder(difference[axis], 2 * .pi)
        }
        return difference
    }

    /// 这一帧的顶点缓冲：画布坐标 xy + 纹理坐标 uv，和图层着色器的顶点格式一致
    func vertexBuffer(at time: Float) -> (any MTLBuffer)? {
        lock.lock()
        defer { lock.unlock() }
        frameIndex = (frameIndex + 1) % buffers.count
        let length = mesh.vertices.count * MemoryLayout<SIMD4<Float>>.stride
        if buffers[frameIndex] == nil {
            buffers[frameIndex] = device.makeBuffer(length: length, options: .storageModeShared)
        }
        guard let buffer = buffers[frameIndex] else { return nil }
        let skins = skinMatrices(at: time).map { world * $0 }
        let output = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: mesh.vertices.count)
        for (index, vertex) in mesh.vertices.enumerated() {
            let position = SIMD4(vertex.position, 1)
            var skinned = SIMD4<Float>.zero
            var total: Float = 0
            for slot in 0..<4 {
                let weight = vertex.boneWeights[slot]
                guard weight > 0 else { continue }
                let bone = Int(vertex.boneIndices[slot])
                guard bone < skins.count else { continue }
                skinned += skins[bone] * position * weight
                total += weight
            }
            // 没有绑骨骼的顶点保持原位
            skinned = total > 0 ? skinned / total : world * position
            output[index] = SIMD4(skinned.x, skinned.y, vertex.uv.x * uvScale.x, vertex.uv.y * uvScale.y)
        }
        return buffer
    }
}
