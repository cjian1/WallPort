import Foundation
import simd
import Testing
@testable import WallpaperFormats

/// 按 PuppetMesh 注释里观察到的结构拼一个最小的模型，测试用。skeleton 为 nil 时只在结尾放一个不完整的骨骼段标记
private func makeModel(
    format: UInt32 = 0x0180_000F, vertices: [(SIMD3<Float>, SIMD2<Float>)], indices: [UInt16],
    skeleton: ((inout Data) -> Void)? = nil
) -> Data {
    var data = Data("MDLV0023".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func f32(_ value: Float) { u32(value.bitPattern) }
    u32(0x0180_0009)
    u32(1)
    u32(1)
    data += Data("materials/人物.json".utf8) + Data([0])
    data += Data(repeating: 0, count: 28)
    u32(format)
    u32(UInt32(vertices.count * 80))
    for (position, uv) in vertices {
        f32(position.x); f32(position.y); f32(position.z)
        f32(0); f32(0); f32(1)
        f32(1); f32(0); f32(0); f32(1)
        u32(3); u32(0); u32(0); u32(0)
        f32(1); f32(0); f32(0); f32(0)
        f32(uv.x); f32(uv.y)
    }
    u32(UInt32(indices.count * 2))
    for index in indices { withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) } }
    // 真实文件在索引区和骨骼段之间还有摊开位置等块
    data += Data(repeating: 0x11, count: 24)
    guard let skeleton else { return data + Data("MDLS0004".utf8) }
    skeleton(&data)
    return data + Data("MDLE0001".utf8) + Data([0])
}

/// 骨骼段 + 动画段。骨骼：(父, 平移, 绕 z 转角)；动画：(编号, 播放方式, 帧率, 帧数, 每根骨骼的帧 [平移xy, 转角z, 缩放])
private func appendSkeleton(
    _ data: inout Data, bones: [(Int32, SIMD2<Float>, Float)],
    animations: [(UInt32, String, Float, UInt32, [[(SIMD2<Float>, Float, Float)]])],
    trackFlags: [UInt32] = [],
    attachments: [(UInt16, String, SIMD2<Float>)] = []
) {
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func f32(_ value: Float) { u32(value.bitPattern) }
    func cString(_ text: String) { data += Data(text.utf8) + Data([0]) }
    func patch(_ at: Int, _ value: Int) {
        withUnsafeBytes(of: UInt32(value).littleEndian) { data.replaceSubrange(at..<(at + 4), with: $0) }
    }
    cString("MDLS0004")
    let bonesEnd = data.count
    u32(0)
    u32(UInt32(bones.count))
    for (parent, translation, angle) in bones {
        cString("")
        u32(1)
        u32(UInt32(bitPattern: parent))
        u32(64)
        for value: Float in [cos(angle), sin(angle), 0, 0, -sin(angle), cos(angle), 0, 0, 0, 0, 1, 0,
                             translation.x, translation.y, 0, 1] { f32(value) }
        cString("{\"tm\":100.0}")
    }
    data += Data(repeating: 0, count: 17)  // 每骨骼的附加数据（编辑器用）
    patch(bonesEnd, data.count)

    if !attachments.isEmpty {
        // MDAT：[段结束][挂点数 u16]，每个 [骨骼 u16][名字][矩阵 16f]
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        cString("MDAT0001")
        let attachmentsEnd = data.count
        u32(0)
        u16(UInt16(attachments.count))
        for (bone, name, offset) in attachments {
            u16(bone)
            cString(name)
            for value: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, offset.x, offset.y, 0, 1] { f32(value) }
        }
        patch(attachmentsEnd, data.count)
    }
    cString("MDLA0006")
    let animationsEnd = data.count
    u32(0)
    u32(UInt32(animations.count))
    for (id, mode, fps, frames, tracks) in animations {
        u32(id)
        u32(0)
        cString("动画 \(id)")
        cString(mode)
        f32(fps)
        u32(frames)
        u32(0)
        u32(UInt32(tracks.count))
        for (bone, track) in tracks.enumerated() {
            u32(bone < trackFlags.count ? trackFlags[bone] : 0)
            u32(UInt32(track.count * 36))
            for (translation, angle, scale) in track {
                for value in [translation.x, translation.y, 0, 0, 0, angle, scale, scale, 1] { f32(value) }
            }
        }
        data += Data(repeating: 0, count: 35)
    }
    patch(animationsEnd, data.count)
}

@Suite struct PuppetMeshTests {
    /// 老版本（MDLV0013）：没有顶点格式字段；顶点是位置 3f + **骨骼编号 4×u32** + 权重 4f + uv 2f。
    /// 权重可以只在后面的槽位上（Xiami 有 912 个这样的顶点），骨骼编号必须按槽位对上
    @Test func legacyVerticesCarryFourBoneIndices() throws {
        var data = Data("MDLV0013".utf8) + Data([0])
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func f32(_ value: Float) { u32(value.bitPattern) }
        u32(0x8000_0009); u32(1); u32(1)
        data += Data("materials/char parts.json".utf8) + Data([0])
        data += Data(repeating: 0, count: 7)
        let vertices: [(SIMD4<UInt32>, SIMD4<Float>)] = [
            (SIMD4(9, 8, 0, 0), SIMD4(0, 1, 0, 0)),
            (SIMD4(11, 7, 0, 0), SIMD4(0.75, 0.25, 0, 0)),
            (SIMD4(2, 0, 0, 0), SIMD4(1, 0, 0, 0)),
        ]
        u32(UInt32(vertices.count * 52))
        for (index, (bones, weights)) in vertices.enumerated() {
            f32(Float(index)); f32(-Float(index)); f32(0)
            for slot in 0..<4 { u32(bones[slot]) }
            for slot in 0..<4 { f32(weights[slot]) }
            f32(0.5); f32(0.25)
        }
        u32(6)
        for index: UInt16 in [0, 1, 2] { withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) } }
        let mesh = try PuppetMesh(data: data)
        #expect(mesh.vertices.map(\.boneIndices) == vertices.map(\.0))
        #expect(mesh.vertices.map(\.boneWeights) == vertices.map(\.1))
        #expect(mesh.vertices[1].position == SIMD3(1, -1, 0))
        #expect(mesh.vertices[2].uv == SIMD2(0.5, 0.25))
    }

    /// 挂点（MDAT 段）：名字、骨骼、相对骨骼的偏移；挂点在模型里的位置 = 骨骼绑定世界 × 偏移
    @Test func readsAttachments() throws {
        let data = makeModel(vertices: [(SIMD3(0, 0, 0), SIMD2(0, 0))], indices: [0, 0, 0]) { data in
            let still = [(SIMD2<Float>(0, 0), Float(0), Float(1))]
            appendSkeleton(
                &data, bones: [(-1, SIMD2(726, -410), 0), (0, SIMD2(-429, 956), 0), (1, SIMD2(10, 0), 0), (2, SIMD2(10, 0), 0)],
                animations: [(7, "loop", 30, 0, [still, still, still, still])],
                attachments: [(3, "脚掌", SIMD2(-71.5, 66.8)), (3, "鞋", SIMD2(-323.2, 164.7))])
        }
        let mesh = try PuppetMesh(data: data)
        #expect(mesh.skeletonProblem == nil)
        #expect(mesh.attachments.map(\.name) == ["脚掌", "鞋"])
        let shoe = try #require(mesh.attachment(named: "鞋"))
        #expect(shoe.bone == 3)
        let placement: simd_float4x4 = mesh.bindWorlds[shoe.bone] * shoe.matrix
        let point = placement.columns.3
        let expectedX: Float = 726 - 429 + 10 + 10 - 323.2
        let expectedY: Float = -410 + 956 + 164.7
        #expect(abs(point.x - expectedX) < 0.01)
        #expect(abs(point.y - expectedY) < 0.01)
        #expect(mesh.animations.count == 1)   // 挂点段不影响后面动画段的读取
    }

    /// 动画里每根骨骼轨道前的标记：0 = 这一层驱动它，1 = 不管它
    @Test func animationTracksSayWhichBonesTheyDrive() throws {
        let data = makeModel(vertices: [(SIMD3(0, 0, 0), SIMD2(0, 0))], indices: [0, 0, 0]) { data in
            // 测试模型的顶点挂在 3 号骨骼上，所以给 4 根
            let still = [(SIMD2<Float>(0, 0), Float(0), Float(1)), (SIMD2<Float>(0, 0), Float(0), Float(1))]
            let leftover = [(SIMD2<Float>(900, 0), Float(0), Float(1)), (SIMD2<Float>(900, 0), Float(0), Float(1))]
            appendSkeleton(
                &data, bones: [(-1, SIMD2(0, 0), 0), (0, SIMD2(10, 0), 0), (1, SIMD2(10, 0), 0), (2, SIMD2(10, 0), 0)],
                animations: [(7, "loop", 30, 1, [still, leftover, still, leftover])],
                trackFlags: [0, 1, 0, 1])
        }
        let mesh = try PuppetMesh(data: data)
        #expect(mesh.skeletonProblem == nil)
        let animation = try #require(mesh.animations.first)
        #expect(animation.drivesBone == [true, false, true, false])
        #expect(animation.drives(0))
        #expect(!animation.drives(1))
        #expect(!animation.drives(4))   // 超出轨道数的骨骼当然不管
    }

    @Test func readsVerticesAndIndices() throws {
        let mesh = try PuppetMesh(data: makeModel(
            vertices: [(SIMD3(-654.3, 661, 0), SIMD2(0.6, 0.05)), (SIMD3(-648, 666, 0), SIMD2(0.61, 0.04)), (SIMD3(-650, 600, 0), SIMD2(0.6, 0.1))],
            indices: [0, 1, 2]))
        #expect(mesh.version == "MDLV0023")
        #expect(mesh.material == "materials/人物.json")
        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[0].position == SIMD3(-654.3, 661, 0))
        #expect(mesh.vertices[0].uv == SIMD2(0.6, 0.05))
        #expect(mesh.vertices[0].boneIndices == SIMD4(3, 0, 0, 0))
        #expect(mesh.vertices[0].boneWeights == SIMD4(1, 0, 0, 0))
        #expect(mesh.indices == [0, 1, 2])
    }

    @Test func unknownVertexFormatIsReported() {
        #expect(throws: FormatError.self) {
            try PuppetMesh(data: makeModel(format: 0x0180_0007, vertices: [(.zero, .zero)], indices: []))
        }
    }

    @Test func indicesOutOfRangeAreRejected() {
        #expect(throws: FormatError.self) {
            try PuppetMesh(data: makeModel(vertices: [(.zero, .zero), (.zero, .zero), (.zero, .zero)], indices: [0, 1, 7]))
        }
    }

    @Test func otherFilesAreRejected() {
        #expect(throws: FormatError.self) { try PuppetMesh(data: Data("TEXV0005".utf8) + Data([0])) }
    }

    private let triangle: [(SIMD3<Float>, SIMD2<Float>)] = [(.zero, .zero), (SIMD3(1, 0, 0), .zero), (SIMD3(0, 1, 0), .zero)]

    @Test func readsSkeletonAndAnimations() throws {
        let rest: [(SIMD2<Float>, Float, Float)] = [(SIMD2(10, 20), 0, 1), (SIMD2(10, 20), 0, 1), (SIMD2(10, 20), 0, 1)]
        let arm: [(SIMD2<Float>, Float, Float)] = [(SIMD2(5, 0), 0.5, 1), (SIMD2(5, 3), 0.7, 1), (SIMD2(5, 0), 0.5, 1)]
        let pad = [(SIMD2<Float>, Float, Float)](repeating: (.zero, 0, 1), count: 3)
        let mesh = try PuppetMesh(data: makeModel(vertices: triangle, indices: [0, 1, 2]) { data in
            appendSkeleton(
                &data,
                bones: [(-1, SIMD2(10, 20), 0), (0, SIMD2(5, 0), 0.5), (1, SIMD2(1, 1), 0), (1, SIMD2(2, 2), 0)],
                animations: [(403, "loop", 24, 2, [rest, arm, pad, pad]), (829, "single", 12, 2, [rest, arm, pad, pad])])
        })
        #expect(mesh.skeletonProblem == nil)
        #expect(mesh.bones.map(\.parent) == [nil, 0, 1, 1])
        #expect(mesh.bones[0].bindLocal.columns.3 == SIMD4(10, 20, 0, 1))
        let bind = PuppetMesh.Pose(matrix: mesh.bones[1].bindLocal)
        #expect(abs(bind.rotation.z - 0.5) < 1e-5)
        #expect(mesh.animations.map(\.id) == [403, 829])
        #expect(mesh.animations[1].mode == "single")
        #expect(mesh.animations[0].fps == 24)
        #expect(mesh.animations[0].frameCount == 2)
        #expect(mesh.animations[0].tracks.count == 4)
        #expect(mesh.animations[0].tracks[1][1].translation == SIMD3(5, 3, 0))
        #expect(abs(mesh.animations[0].tracks[1][1].rotation.z - 0.7) < 1e-6)
    }

    @Test func brokenSkeletonKeepsTheMesh() throws {
        // 结尾只有不完整的骨骼段标记：网格照常可用，骨骼为空并记下原因
        let mesh = try PuppetMesh(data: makeModel(vertices: triangle, indices: [0, 1, 2]))
        #expect(mesh.vertices.count == 3)
        #expect(mesh.bones.isEmpty)
        #expect(mesh.skeletonProblem != nil)
    }

    @Test func animationWithWrongBoneCountIsReported() throws {
        let mesh = try PuppetMesh(data: makeModel(vertices: triangle, indices: [0, 1, 2]) { data in
            appendSkeleton(
                &data, bones: [(-1, .zero, 0), (0, .zero, 0), (1, .zero, 0), (1, .zero, 0)],
                animations: [(1, "loop", 24, 0, [[(.zero, 0, 1)]])])
        })
        #expect(mesh.bones.isEmpty)
        #expect(mesh.skeletonProblem?.contains("骨骼") == true)
    }
}
