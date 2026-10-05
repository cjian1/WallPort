import Foundation
import simd

/// 木偶变形模型（.mdl）里的网格。
///
/// 结构（2026-09-28 用 Lucy 场景的 `Lucy_puppet.mdl`（MDLV0023）逐字节核对，目前只有这一个样本）：
///
///     "MDLV0023" NUL  [标志][1][1]  [材质路径] NUL  若干个 0 字节
///     [顶点格式 0x0180000F][顶点区字节数]  顶点 × N，每个 80 字节：
///         位置 3f、法线 3f、切线 4f、骨骼编号 4×u32、骨骼权重 4f、纹理坐标 2f
///     [索引区字节数]  u16 索引（三个一组）
///     可选：部件在图集上的摊开位置（3f × N，编辑器用），以及其他块
///     "MDLS0004" NUL  [段结束的绝对偏移][骨骼数]  骨骼 × N：
///         [名字] NUL [标志][父骨骼编号，根为 -1][矩阵字节数 64][局部矩阵 16f，列主序] [编辑器用的 JSON] NUL
///         之后到段结束还有一段每骨骼的附加数据（编辑器用，未解析）
///     "MDLA0006" NUL  [段结束的绝对偏移][动画数]  动画 × N：
///         [编号][未知 4 字节][名字] NUL [播放方式 loop/single] NUL [帧率 f32][帧数][未知 4 字节][骨骼数]
///         骨骼 × 骨骼数：[标记][字节数]  帧 × (帧数 + 1)：平移 3f、欧拉角 3f（弧度）、缩放 3f
///         标记 0 = 这一层驱动这根骨骼；1 = 这一层不管它（存的是编辑器留下的值，不能用。
///         2026-09-29 对着 Xiami 场景核对：`Rightarm` 层只有右臂那条骨骼链是 0，其余是 1 且有的离绑定姿势
///         几百像素——整层照搬就会把身体其它部位甩开）
///         动画结尾 35 个 0 字节（含义未知）
///     "MDAT0001" NUL  [段结束的绝对偏移][挂点数 u16]  挂点 × N：
///         [骨骼编号 u16][名字] NUL [相对这根骨骼的矩阵 16f，列主序]
///         场景里的子图层写 `"attachment": "名字"` 就挂在这里：跟着这根骨骼动（高跟鞋挂在"鞋"上、眼睛挂在"眼睛"上）
///     "MDLE…"
///
/// 骨骼的局部矩阵是相对父骨骼的绑定姿势；动画帧是骨骼的完整局部姿势（不是增量），
/// 第 0 帧和绑定姿势一致。顶点位置就在绑定姿势的模型坐标里，所以蒙皮是
/// Σ 权重 × 当前世界矩阵 × 绑定世界矩阵的逆 × 顶点。
///
/// 顶点位置是拼装好的姿势，坐标系以图层原点为中心、y 向上、单位是画布像素，
/// 不局限在图层的矩形之内（Lucy 的网格整个在图层原点的左边）。
/// 纹理坐标按图像（不含补齐边距）的 0–1 计，指向身体部件图集。
public struct PuppetMesh: Sendable {
    public struct Vertex: Sendable, Equatable {
        public let position: SIMD3<Float>
        public let uv: SIMD2<Float>
        public let boneIndices: SIMD4<UInt32>
        public let boneWeights: SIMD4<Float>
    }

    public struct Bone: Sendable {
        /// 父骨骼编号；根骨骼为 nil
        public let parent: Int?
        /// 相对父骨骼的绑定姿势
        public let bindLocal: simd_float4x4
    }

    /// 骨骼的一个局部姿势
    public struct Pose: Sendable, Equatable {
        public var translation: SIMD3<Float>
        /// 欧拉角（弧度）；2D 木偶只用 z
        public var rotation: SIMD3<Float>
        public var scale: SIMD3<Float>

        public init(translation: SIMD3<Float>, rotation: SIMD3<Float>, scale: SIMD3<Float>) {
            self.translation = translation
            self.rotation = rotation
            self.scale = scale
        }

        /// 平移 × 旋转（z·y·x）× 缩放
        public var matrix: simd_float4x4 {
            let rz = simd_float4x4(simd_quatf(angle: rotation.z, axis: SIMD3(0, 0, 1)))
            let ry = simd_float4x4(simd_quatf(angle: rotation.y, axis: SIMD3(0, 1, 0)))
            let rx = simd_float4x4(simd_quatf(angle: rotation.x, axis: SIMD3(1, 0, 0)))
            var translation = matrix_identity_float4x4
            translation.columns.3 = SIMD4(self.translation, 1)
            return translation * rz * ry * rx * simd_float4x4(diagonal: SIMD4(scale, 1))
        }

        /// 从只含平移、绕 z 旋转和缩放的矩阵还原（绑定姿势就是这种）
        public init(matrix: simd_float4x4) {
            let x = SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
            let y = SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
            let z = SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
            translation = SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
            rotation = SIMD3(0, 0, atan2(x.y, x.x))
            scale = SIMD3(simd_length(x), simd_length(y), simd_length(z))
        }
    }

    /// 挂点：场景里子图层的 `attachment` 按名字找它，子图层的位置以它为原点、跟着它的骨骼动
    public struct Attachment: Sendable, Equatable {
        public let name: String
        public let bone: Int
        /// 相对骨骼的变换
        public let matrix: simd_float4x4

        public init(name: String, bone: Int, matrix: simd_float4x4) {
            self.name = name
            self.bone = bone
            self.matrix = matrix
        }
    }

    public struct Animation: Sendable {
        public let id: Int
        public let name: String
        /// 播放方式：loop（循环）、mirror（正着播完倒着播回来）、single（播一遍停在最后一帧）；其他按 loop 处理
        public let mode: String
        public let fps: Float
        /// 动画长度（帧）；每根骨骼存了 frameCount + 1 帧，最后一帧是结尾的姿势
        public let frameCount: Int
        /// 每根骨骼的逐帧局部姿势
        public let tracks: [[Pose]]
        /// 每根骨骼是不是由这一层驱动（骨骼动画的标记为 0）。不驱动的骨骼这一层不能碰，
        /// 由别的层（或绑定姿势）决定；为空表示全部驱动
        public let drivesBone: [Bool]

        public init(
            id: Int, name: String, mode: String, fps: Float, frameCount: Int, tracks: [[Pose]],
            drivesBone: [Bool] = []
        ) {
            self.id = id
            self.name = name
            self.mode = mode
            self.fps = fps
            self.frameCount = frameCount
            self.tracks = tracks
            self.drivesBone = drivesBone
        }

        /// 这一层管不管第 `bone` 根骨骼
        public func drives(_ bone: Int) -> Bool {
            bone < tracks.count && (bone >= drivesBone.count || drivesBone[bone])
        }

        public var duration: Float { fps > 0 ? Float(frameCount) / fps : 0 }
    }

    public let version: String
    public let material: String
    public let vertices: [Vertex]
    public let indices: [UInt16]
    /// 骨骼；没有骨骼段时为空
    public let bones: [Bone]
    public let animations: [Animation]
    /// 挂点（MDAT 段）；没有时为空
    public let attachments: [Attachment]
    /// 骨骼或动画段读不懂时的原因。网格仍然可用，按静态姿势画
    public let skeletonProblem: String?

    /// 顶点布局。开关位决定有哪些属性（2026-09-28 用真实文件核对过三种）：
    /// - `0x0180000F`：位置 + 法线 + 切线 + 骨骼 4×u32 + 权重 4f + uv = 80 字节（Lucy）；
    /// - `0x01800009`：没有法线和切线 = 位置 + 骨骼 4×u32 + 权重 4f + uv = 52 字节（MDLV0016）；
    /// - `MDLV0013` / `MDLV0014`（老版本没有格式字段）：和 `0x01800009` 一样，位置 + 骨骼 4×u32 + 权重 4f + uv = 52 字节。
    enum VertexLayout {
        case positionBonesWeightsUV
        case full

        var stride: Int {
            switch self {
            case .positionBonesWeightsUV: 52
            case .full: 80
            }
        }
    }

    /// 顶点格式开关 → 布局
    static let vertexLayouts: [UInt32: VertexLayout] = [
        0x0180_000F: .full,
        0x0180_0009: .positionBonesWeightsUV,
    ]

    /// 老版本（MDLV0013 / MDLV0014）：材质路径之后**没有**单独的顶点格式字段，直接是顶点区字节数；
    /// 顶点 52 字节：位置 3f、**骨骼编号 4×u32**、权重 4f、纹理坐标 2f。
    ///
    /// 2026-09-28 最初按"一个骨骼编号 + 法线 3f"读（初音那几个文件的权重几乎都在第一个槽位，看不出错）；
    /// 2026-09-29 用 Xiami 核对纠正：后三个"法线"其实是骨骼编号（小整数按 float 读出来全是 0），
    /// 3238 个顶点里 912 个的权重只在第 2–4 个槽位上，按旧读法全被错挂到 0 号骨骼，一动就把网格撕开
    static let legacyVersions = ["MDLV0013", "MDLV0014"]

    /// 直接给出各部分（测试用）
    init(
        vertices: [Vertex], indices: [UInt16], bones: [Bone], animations: [Animation], attachments: [Attachment] = []
    ) {
        version = "MDLV0023"
        material = ""
        self.vertices = vertices
        self.indices = indices
        self.bones = bones
        self.animations = animations
        self.attachments = attachments
        skeletonProblem = nil
    }

    /// 绑定姿势下每根骨骼在模型坐标里的变换
    public var bindWorlds: [simd_float4x4] {
        var worlds: [simd_float4x4] = []
        for bone in bones {
            worlds.append(bone.parent.flatMap { $0 < worlds.count ? worlds[$0] : nil }.map { $0 * bone.bindLocal } ?? bone.bindLocal)
        }
        return worlds
    }

    public func attachment(named name: String) -> Attachment? {
        attachments.first { $0.name == name }
    }

    public init(data: Data) throws {
        var reader = ByteReader(data)
        version = try reader.cString(limit: 16)
        guard version.hasPrefix("MDLV") else { throw FormatError("不是木偶模型：开头是 \(version)") }
        _ = try reader.uint32()
        _ = try reader.uint32()
        _ = try reader.uint32()
        material = try reader.cString(limit: 1024)

        let layout: VertexLayout
        if Self.legacyVersions.contains(where: version.hasPrefix) {
            layout = .positionBonesWeightsUV
            // 老版本：材质路径后面是一段 0 填充，第一个非 0 的 u32 才是顶点区字节数
            while reader.remaining > 0, reader.data[reader.data.startIndex + reader.offset] == 0 {
                _ = try reader.bytes(1)
            }
        } else {
            var chosen: VertexLayout?
            // 材质路径之后是 0 填充；有的版本（MDLV0016 的部分文件）还多一个 u32 的小字段（值是 4）。
            // 往下找第一个认识的顶点格式字段
            var firstUnknown: UInt32?
            for _ in 0..<64 {
                guard reader.remaining >= 8 else { break }
                let candidate = try reader.uint32()
                if let known = Self.vertexLayouts[candidate] {
                    // 后面紧跟着的"顶点区字节数"必须能被这个布局整除，才算真的格式字段：
                    // 有的文件里会出现别的同名值，光看数值会把格式认错
                    let valueOffset = reader.offset
                    let bytes = try reader.uint32()
                    try reader.seek(to: valueOffset)
                    if bytes > 0, bytes <= 1 << 24, Int(bytes) % known.stride == 0 {
                        chosen = known
                        break
                    }
                }
                if candidate != 0, firstUnknown == nil { firstUnknown = candidate }
            }
            guard let chosen else {
                let value = firstUnknown ?? 0
                throw FormatError(String(format: "还不认识的木偶顶点格式 0x%08X", value))
            }
            layout = chosen
        }
        let stride = layout.stride
        let vertexBytes = try reader.count(limit: reader.remaining, what: "顶点区字节数")
        guard vertexBytes % stride == 0 else { throw FormatError("顶点区字节数 \(vertexBytes) 不是 \(stride) 的倍数") }

        var vertices: [Vertex] = []
        vertices.reserveCapacity(vertexBytes / stride)
        for _ in 0..<(vertexBytes / stride) {
            var vertex = ByteReader(try reader.bytes(stride))
            let position = SIMD3(try vertex.float32(), try vertex.float32(), try vertex.float32())
            let bones: SIMD4<UInt32>
            let weights: SIMD4<Float>
            switch layout {
            case .full:
                for _ in 0..<7 { _ = try vertex.uint32() }  // 法线 3f、切线 4f
                bones = SIMD4(try vertex.uint32(), try vertex.uint32(), try vertex.uint32(), try vertex.uint32())
                weights = SIMD4(
                    try vertex.float32(), try vertex.float32(), try vertex.float32(), try vertex.float32())
            case .positionBonesWeightsUV:
                // 没有法线和切线，位置后面直接是骨骼编号和权重（老版本也是这样）
                bones = SIMD4(try vertex.uint32(), try vertex.uint32(), try vertex.uint32(), try vertex.uint32())
                weights = SIMD4(
                    try vertex.float32(), try vertex.float32(), try vertex.float32(), try vertex.float32())
            }
            let uv = SIMD2(try vertex.float32(), try vertex.float32())
            vertices.append(Vertex(position: position, uv: uv, boneIndices: bones, boneWeights: weights))
        }

        let indexBytes = try reader.count(limit: reader.remaining, what: "索引区字节数")
        guard indexBytes % 6 == 0 else { throw FormatError("索引区字节数 \(indexBytes) 不是整数个三角形") }
        let raw = try reader.bytes(indexBytes)
        let indices = raw.withUnsafeBytes { buffer in
            (0..<(indexBytes / 2)).map { UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
        guard let largest = indices.max(), Int(largest) < vertices.count else {
            throw FormatError("索引超出顶点范围")
        }
        self.vertices = vertices
        self.indices = indices

        // 中间还有摊开位置等块，直接找骨骼段的标记
        var bones: [Bone] = []
        var animations: [Animation] = []
        var attachments: [Attachment] = []
        var problem: String?
        if let start = reader.find(Data("MDLS".utf8)) {
            do {
                try reader.seek(to: start)
                bones = try Self.readBones(&reader)
                let afterBones = reader.offset
                let animationStart = reader.find(Data("MDLA".utf8))
                if let attachmentStart = reader.find(Data("MDAT".utf8)),
                   animationStart.map({ attachmentStart < $0 }) ?? true {
                    try reader.seek(to: attachmentStart)
                    // 挂点读不懂不影响网格和动画（只是子图层挂不上去）
                    attachments = (try? Self.readAttachments(&reader, boneCount: bones.count)) ?? []
                }
                try reader.seek(to: afterBones)
                if let animationStart {
                    try reader.seek(to: animationStart)
                    animations = try Self.readAnimations(
                        &reader, boneCount: bones.count,
                        tailBytes: Self.legacyVersions.contains(where: version.hasPrefix) ? 4 : 35)
                }
                let maxBone = vertices.map { $0.boneIndices.max() }.max() ?? 0
                if !bones.isEmpty, Int(maxBone) >= bones.count {
                    throw FormatError("顶点引用了第 \(maxBone) 根骨骼，只有 \(bones.count) 根")
                }
            } catch {
                bones = []
                animations = []
                problem = error.localizedDescription
            }
        }
        self.bones = bones
        self.animations = animations
        self.attachments = attachments
        skeletonProblem = problem
    }

    /// MDAT 段：`[段结束][挂点数 u16]`，每个挂点 `[骨骼编号 u16][名字 NUL][矩阵 16f]`。
    /// 2026-09-29 对着 3681810302 的三个模型核对：腿上"脚掌""鞋"挂在 4 号骨骼、主体上"前发""眼睛""眉毛"
    /// 挂在 8 号骨骼；场景里名叫"鞋"的粒子正好摆在"鞋"挂点算出来的位置（-1160.1, -119.3）
    private static func readAttachments(_ reader: inout ByteReader, boneCount: Int) throws -> [Attachment] {
        let tag = try reader.cString(limit: 16)
        guard tag.hasPrefix("MDAT") else { throw FormatError("挂点段标记不对：\(tag)") }
        _ = try reader.uint32()
        let count = Int(try reader.uint16())
        var attachments: [Attachment] = []
        for _ in 0..<count {
            let bone = Int(try reader.uint16())
            let name = try reader.cString(limit: 1024)
            var columns: [SIMD4<Float>] = []
            for _ in 0..<4 {
                columns.append(SIMD4(try reader.float32(), try reader.float32(), try reader.float32(), try reader.float32()))
            }
            guard bone < boneCount else { throw FormatError("挂点 \(name) 指向第 \(bone) 根骨骼，只有 \(boneCount) 根") }
            attachments.append(Attachment(
                name: name, bone: bone, matrix: simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))))
        }
        return attachments
    }

    private static func readBones(_ reader: inout ByteReader) throws -> [Bone] {
        let tag = try reader.cString(limit: 16)
        guard tag.hasPrefix("MDLS") else { throw FormatError("骨骼段标记不对：\(tag)") }
        let end = try reader.count(limit: reader.data.count, what: "骨骼段结束位置")
        let count = try reader.count(limit: 4096, what: "骨骼数")
        var bones: [Bone] = []
        for index in 0..<count {
            _ = try reader.cString(limit: 1024)
            _ = try reader.uint32()
            let parent = Int(try reader.int32())
            let matrixBytes = try reader.count(limit: 1024, what: "骨骼矩阵字节数")
            guard matrixBytes == 64 else { throw FormatError("骨骼矩阵是 \(matrixBytes) 字节，应为 64") }
            var columns: [SIMD4<Float>] = []
            for _ in 0..<4 {
                columns.append(SIMD4(try reader.float32(), try reader.float32(), try reader.float32(), try reader.float32()))
            }
            _ = try reader.cString(limit: 1 << 16)
            guard parent < index else { throw FormatError("第 \(index) 根骨骼的父骨骼是 \(parent)，不在它前面") }
            bones.append(Bone(
                parent: parent >= 0 ? parent : nil,
                bindLocal: simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))))
        }
        try reader.seek(to: end)
        return bones
    }

    private static func readAnimations(
        _ reader: inout ByteReader, boneCount: Int, tailBytes: Int
    ) throws -> [Animation] {
        let tag = try reader.cString(limit: 16)
        guard tag.hasPrefix("MDLA") else { throw FormatError("动画段标记不对：\(tag)") }
        let end = try reader.count(limit: reader.data.count, what: "动画段结束位置")
        let count = try reader.count(limit: 1024, what: "动画数")
        var animations: [Animation] = []
        for index in 0..<count {
            let id = Int(try reader.uint32())
            _ = try reader.uint32()
            let name = try reader.cString(limit: 1024)
            let mode = try reader.cString(limit: 64)
            let fps = try reader.float32()
            let frameCount = try reader.count(limit: 1 << 20, what: "动画帧数")
            _ = try reader.uint32()
            let bones = try reader.count(limit: 4096, what: "动画的骨骼数")
            guard fps > 0, fps < 1000, bones == boneCount else {
                throw FormatError("第 \(index + 1) 个动画的头部不对（帧率 \(fps)，骨骼 \(bones)/\(boneCount)）")
            }
            var tracks: [[Pose]] = []
            var drivesBone: [Bool] = []
            for _ in 0..<bones {
                drivesBone.append(try reader.uint32() & 1 == 0)
                let bytes = try reader.count(limit: reader.remaining, what: "骨骼动画字节数")
                guard bytes % 36 == 0, bytes / 36 >= 1 else { throw FormatError("骨骼动画字节数 \(bytes) 不是整数帧") }
                var frames: [Pose] = []
                frames.reserveCapacity(bytes / 36)
                for _ in 0..<(bytes / 36) {
                    var values: [Float] = []
                    for _ in 0..<9 { values.append(try reader.float32()) }
                    frames.append(Pose(
                        translation: SIMD3(values[0], values[1], values[2]),
                        rotation: SIMD3(values[3], values[4], values[5]),
                        scale: SIMD3(values[6], values[7], values[8])))
                }
                tracks.append(frames)
            }
            // 结尾的填充块长度各版本不同（MDLV0023 是 35、MDLV0013/0014 是 4、有的只剩 10），
            // 只要不越过这一段的结束位置，就按实际长度跳过去；最后统一对齐到段尾
            if reader.offset + tailBytes <= end { _ = try reader.bytes(tailBytes) }
            animations.append(Animation(
                id: id, name: name, mode: mode, fps: fps, frameCount: frameCount, tracks: tracks,
                drivesBone: drivesBone))
        }
        guard reader.offset <= end else {
            throw FormatError("动画段读到偏移 \(reader.offset)，应在 \(end) 结束")
        }
        try reader.seek(to: end)
        return animations
    }
}
