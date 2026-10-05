import Foundation
import simd
import WallpaperFormats

/// 脚本能看到的场景对象接口（`thisObject` / `thisScene`）。渲染器把它实现成运行时图层状态；
/// 测试里也可以给一个假的。
protocol SceneGraphScriptAPI: AnyObject {
    func layerName(_ id: Int) -> String?
    func layerAlpha(_ id: Int) -> Double
    func setLayerAlpha(_ id: Int, _ value: Double)
    func layerVisible(_ id: Int) -> Bool
    func setLayerVisible(_ id: Int, _ value: Bool)
    func layerOrigin(_ id: Int) -> SIMD3<Float>
    func setLayerOrigin(_ id: Int, _ value: SIMD3<Float>)
    func layerScale(_ id: Int) -> SIMD3<Float>
    func setLayerScale(_ id: Int, _ value: SIMD3<Float>)
    /// 图层框的宽高（`thisLayer.size`，像素）；脚本用它算"碰到屏幕边界"这类判断
    func layerSize(_ id: Int) -> SIMD2<Float>
    /// 图层的朝向（**度**，和 WE 脚本一致：可视化条脚本写 `new Vec3(0, 0, barAngle)`，barAngle 按度算）；
    /// scene.json 里存的是弧度，换算在这里做
    func layerAngles(_ id: Int) -> SIMD3<Float>
    func setLayerAngles(_ id: Int, _ value: SIMD3<Float>)
    /// 运行时建图层（`thisScene.createLayer`）：登记一个空图层，返回它的编号
    func createLayer(model: String) -> Int?
    func layerChildren(_ id: Int) -> [Int]
    func layerIndex(_ id: Int) -> Int
    func layerID(named name: String) -> Int?
    /// 把图层挪到某个绘制序号（`thisScene.sortLayer`）
    func sortLayer(_ id: Int, index: Int)
    /// 图层的对齐方式（`thisLayer.alignment`，"center" / "bottom" / "topleft"…）
    func layerAlignment(_ id: Int) -> String
    func setLayerAlignment(_ id: Int, _ value: String)
}

/// 运行时的图层状态：图层自己的属性脚本、以及场景对象接口改的都是这里。绘制时按它算
/// 位置、缩放、透明度和显隐——所以脚本可以让父图层带着子图层一起动，也能让幻灯片换图。
///
/// 没被脚本碰过的图层不会走"每帧重算"这条路：`hasModifications` 为 false 时绘制直接用构建时的值。
final class SceneState {
    final class Layer {
        let id: Int
        let name: String
        let parent: Int?
        /// 绕 z 的旋转（弧度，和 scene.json 一致）
        var anglesZ: Float
        let buildAnglesZ: Float
        var children: [Int] = []
        /// 场景里的原始序号（`sortLayer` 没碰过时按它排）
        let sceneIndex: Int

        // 构建时的值（算增量、判断有没有被改过）
        let buildOrigin: SIMD3<Float>
        let buildScale: SIMD3<Float>
        let buildAlpha: Float
        let buildColor: SIMD3<Float>
        let buildVisible: Bool
        var buildWorld = matrix_identity_float4x4
        /// 烘进顶点的世界变换换掉了缩放（见 `bakeBuildWorld`）：这种图层就算没被改过，也要每帧乘增量把缩放乘回去
        var buildScaleReplaced = false

        // 当前值（脚本可改）
        var origin: SIMD3<Float>
        var scale: SIMD3<Float>
        var alpha: Float
        var color: SIMD3<Float>
        var visible: Bool
        /// `sortLayer` 指定的绘制序号；nil 表示按场景里的原始顺序
        var order: Int?

        /// 这一帧的世界变换
        var world = matrix_identity_float4x4
        var worldIsCurrent = false
        /// 图层框的宽高（像素），`thisLayer.size`
        var size = SIMD2<Float>(1, 1)
        /// 对齐点（WE 的 alignment，见 `SceneState.anchor`）：脚本可以改（可视化条把柱子改成底边对齐）
        var anchor = SIMD2<Float>(0, 0)
        var buildAnchor = SIMD2<Float>(0, 0)
        /// 四边形（或以框中心为原点的木偶网格）在图层自身坐标里的宽高，对齐按它挪；nil 的图层（粒子）不挪
        var quadSize: SIMD2<Float>?
        /// 挂在父木偶挂点上（scene.json 的 `attachment`）：挂点在父模型坐标里的当前变换（骨骼当前姿势 × 挂点偏移）。
        /// 构建时按绑定姿势登记，之后每帧由渲染器按父木偶的动画更新
        var attachment: simd_float4x4?
        var buildAttachment: simd_float4x4?

        /// 脚本运行时建的图层：还没有绘制项，先按默认值登记（origin 0、scale 1、可见）
        init(id: Int, name: String, sceneIndex: Int) {
            self.id = id
            self.name = name
            parent = nil
            anglesZ = 0
            buildAnglesZ = 0
            self.sceneIndex = sceneIndex
            buildOrigin = .zero
            buildScale = SIMD3(1, 1, 1)
            buildAlpha = 1
            buildColor = SIMD3(1, 1, 1)
            buildVisible = true
            origin = .zero
            scale = SIMD3(1, 1, 1)
            alpha = 1
            color = SIMD3(1, 1, 1)
            visible = true
        }

        init(object: SceneDescription.Object, sceneIndex: Int) {
            id = object.id
            name = object.name
            parent = object.parent
            anglesZ = object.angles.z
            buildAnglesZ = object.angles.z
            self.sceneIndex = sceneIndex
            buildOrigin = object.origin
            buildScale = object.scale
            buildAlpha = object.alpha
            buildColor = object.color
            buildVisible = object.isVisible
            size = object.size ?? SIMD2(1, 1)
            anchor = SceneState.anchor(object.alignment)
            buildAnchor = anchor
            origin = object.origin
            scale = object.scale
            alpha = object.alpha
            color = object.color
            visible = object.isVisible
        }

        var isModified: Bool {
            order != nil || origin != buildOrigin || scale != buildScale || anglesZ != buildAnglesZ
                || alpha != buildAlpha || color != buildColor || visible != buildVisible || anchor != buildAnchor
                || attachment != buildAttachment
        }
    }

    private(set) var layers: [Int: Layer] = [:]
    /// 场景里的原始顺序
    private(set) var sceneOrder: [Int] = []
    private var worldCache: [Int: simd_float4x4] = [:]
    /// 脚本运行时建的图层：渲染器下一帧把它们建成绘制项
    private var pendingLayers: [(id: Int, model: String)] = []
    private var nextRuntimeLayerID = 900_000
    /// 运行时建图层的上限：脚本每帧都建的话不能无限涨（可视化条一般 64–128 个）
    static let maximumRuntimeLayers = 4096

    init(scene: SceneDescription) {
        for (index, object) in scene.objects.enumerated() {
            layers[object.id] = Layer(object: object, sceneIndex: index)
            sceneOrder.append(object.id)
        }
        for object in scene.objects {
            if let parent = object.parent, layers[parent] != nil, object.id != parent {
                layers[parent]?.children.append(object.id)
            }
        }
    }

    /// 有图层被脚本改过（没改过就不需要每帧排序和算增量）
    var hasModifications: Bool { layers.values.contains(where: \.isModified) }

    /// 重新算这一帧的世界变换（脚本可能改了父图层）
    func refreshWorlds() {
        guard hasModifications else { return }
        worldCache.removeAll(keepingCapacity: true)
        for id in sceneOrder { _ = world(id) }
    }

    /// 当前的世界变换：父图层 × 平移(origin) × 绕 z 旋转 × 缩放(scale)。
    /// 挂在父木偶挂点上的图层：父图层 × 父的对齐（木偶网格的模型坐标） × 挂点当前变换 × 自己
    func world(_ id: Int, depth: Int = 0) -> simd_float4x4 {
        if let cached = worldCache[id] { return cached }
        guard let layer = layers[id], depth < 64 else { return matrix_identity_float4x4 }
        let local = Self.translation(layer.origin) * Self.rotationZ(layer.anglesZ) * Self.scaling(layer.scale)
        let matrix: simd_float4x4
        if let parent = layer.parent, parent != id, layers[parent] != nil {
            var parentWorld = world(parent, depth: depth + 1)
            if let attachment = layer.attachment { parentWorld = parentWorld * alignment(parent) * attachment }
            matrix = parentWorld * local
        } else {
            matrix = local
        }
        worldCache[id] = matrix
        return matrix
    }

    /// 登记 / 更新图层的挂点变换（`isBuild` 时同时记成构建时的值：之后每帧和它比，决定要不要乘增量）
    func setAttachment(_ id: Int, _ matrix: simd_float4x4, isBuild: Bool = false) {
        guard let layer = layers[id] else { return }
        layer.attachment = matrix
        if isBuild {
            layer.buildAttachment = matrix
            worldCache.removeAll(keepingCapacity: true)
        }
    }

    /// 有祖先被改过（脚本挪了父图层、父图层挂在正在动的骨骼上）：自己没改也要跟着动
    private func ancestorMoved(_ id: Int) -> Bool {
        var current = layers[id]?.parent
        var depth = 0
        while let parentID = current, parentID != id, let parent = layers[parentID], depth < 64 {
            if parent.isModified { return true }
            current = parent.parent
            depth += 1
        }
        return false
    }

    /// 从构建时的四边形推到当前四边形要乘的增量。构建时记下的是"对齐后"的世界变换（见 `alignment`），
    /// 所以这里也按当前的对齐算——脚本改了对齐（或者缩放，对齐点不动）当帧就生效
    func delta(_ id: Int) -> simd_float4x4 {
        guard let layer = layers[id], layer.isModified || layer.buildScaleReplaced || ancestorMoved(id) else {
            return matrix_identity_float4x4
        }
        return world(id) * alignment(id) * layer.buildWorld.inverse
    }

    /// 建绘制项时烘进顶点的世界变换（世界 × 对齐），同时记成构建时的世界，之后每帧的 `delta` 以它为起点。
    ///
    /// 缩放几乎为 0 的轴按 1 烘：脚本常在 init 或第一帧就把缩放设成 0（可视化条没声音时柱子高度是 0，
    /// 它自己那一层是场景里的图层，建绘制项时脚本已经跑过）。按 0 烘的话四边形被压成一条线，
    /// 之后每帧的增量要放大上千万倍，Float 精度全丢——那根柱子画到错的地方或干脆看不见。
    /// `keepsScale` 为 false 时整个缩放都不烘（脚本运行时建的图层，缩放全交给增量）
    @discardableResult
    func bakeBuildWorld(_ id: Int, keepsScale: Bool = true) -> simd_float4x4 {
        let world = world(id)
        let usable = Self.withoutScale(world, collapsedAxesOnly: keepsScale)
        let baked = usable * alignment(id)
        layers[id]?.buildWorld = baked
        layers[id]?.buildScaleReplaced = usable != world
        return baked
    }

    /// 把世界变换 x、y 两列的缩放换成 1（`collapsedAxesOnly` 时只换几乎为 0 的那一列），平移和旋转不变
    static func withoutScale(_ matrix: simd_float4x4, collapsedAxesOnly: Bool) -> simd_float4x4 {
        func direction(_ column: SIMD4<Float>) -> SIMD4<Float>? {
            let length = simd_length(SIMD3(column.x, column.y, column.z))
            guard length > (collapsedAxesOnly ? 1e-3 : 1e-6) else { return nil }
            return SIMD4(column.x / length, column.y / length, column.z / length, 0)
        }
        let x = direction(matrix.columns.0)
        let y = direction(matrix.columns.1)
        // 缩放为 0 时那一列整个是 0，直接拿单位向量顶上会让两列重合、矩阵又变奇异，
        // 所以缺的一列用另一列在 xy 平面内转 90° 补（x 轴 = y 轴顺时针转 90°）
        let unitX = x ?? y.map { SIMD4($0.y, -$0.x, 0, 0) } ?? SIMD4(1, 0, 0, 0)
        let unitY = y ?? x.map { SIMD4(-$0.y, $0.x, 0, 0) } ?? SIMD4(0, 1, 0, 0)
        if !collapsedAxesOnly {
            return simd_float4x4(columns: (unitX, unitY, SIMD4(0, 0, 1, 0), matrix.columns.3))
        }
        return simd_float4x4(columns: (
            x == nil ? unitX : matrix.columns.0, y == nil ? unitY : matrix.columns.1,
            matrix.columns.2, matrix.columns.3))
    }

    /// WE 的 alignment → 对齐点：x −1 左、+1 右；y +1 上、−1 下；(0, 0) 居中。认不出来的按居中
    static func anchor(_ alignment: String) -> SIMD2<Float> {
        let name = alignment.lowercased()
        var anchor = SIMD2<Float>(0, 0)
        if name.contains("left") { anchor.x = -1 }
        if name.contains("right") { anchor.x = 1 }
        if name.contains("top") { anchor.y = 1 }
        if name.contains("bottom") { anchor.y = -1 }
        return anchor
    }

    /// 四边形要挪多少才让对齐点落在原点上（图层自身坐标，缩放之前）：底边对齐时往上挪半个高度，
    /// 之后缩放就以底边为基准。没登记尺寸的图层（粒子）不挪
    func alignment(_ id: Int) -> simd_float4x4 {
        guard let layer = layers[id], let size = layer.quadSize, layer.anchor != .zero else {
            return matrix_identity_float4x4
        }
        return Self.translation(SIMD3(-layer.anchor.x * size.x / 2, -layer.anchor.y * size.y / 2, 0))
    }

    /// 登记四边形的尺寸（建绘制项时调用），之后 `alignment` 才会按对齐挪它
    func setQuadSize(_ id: Int, _ size: SIMD2<Float>) { layers[id]?.quadSize = size }

    func color(_ id: Int) -> SIMD4<Float> {
        guard let layer = layers[id] else { return SIMD4(1, 1, 1, 1) }
        return SIMD4(layer.color, layer.alpha)
    }

    func isVisible(_ id: Int) -> Bool { layers[id]?.visible ?? true }

    func layerColor(_ id: Int) -> SIMD3<Float> { layers[id]?.color ?? SIMD3(1, 1, 1) }

    func setLayerColor(_ id: Int, _ value: SIMD3<Float>) { layers[id]?.color = value }

    func setBuildWorld(_ id: Int, _ matrix: simd_float4x4) {
        layers[id]?.buildWorld = matrix
    }

    /// 绘制顺序：有 `sortLayer` 的按它排，其余保持场景顺序
    func drawOrder() -> [Int] {
        guard hasModifications else { return sceneOrder }
        return sceneOrder.sorted { lhs, rhs in
            let left = layers[lhs]?.order ?? layers[lhs]?.sceneIndex ?? 0
            let right = layers[rhs]?.order ?? layers[rhs]?.sceneIndex ?? 0
            if left != right { return left < right }
            return (layers[lhs]?.sceneIndex ?? 0) < (layers[rhs]?.sceneIndex ?? 0)
        }
    }

    private static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset.x, offset.y, offset.z, 1)
        return matrix
    }

    private static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }

    private static func scaling(_ scale: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(Self.safeScale(scale.x), Self.safeScale(scale.y), Self.safeScale(scale.z), 1))
    }

    /// 缩放分量取一个安全下限。两个原因：
    /// - 2D 场景里 `scale.z` 经常是 0（语料里的 "4.5 1 0" 就是这样），但世界矩阵要拿来做**逆变换**
    ///   （`delta()` = 当前世界 × 构建时世界的逆），分量是 0 的话矩阵不可逆、逆矩阵全是 NaN，
    ///   图层直接画不出来——脚本把 `scale` 设成 `new Vec3(5)`（y、z 都是 0）时就是这个下场；
    /// - 缩放正好为 0 的图层本来就看不见，用极小值代替既不会画出东西，又保证矩阵可逆。
    /// 负的缩放是有意义的（镜像），所以只处理绝对值太小的分量、保留符号。
    static func safeScale(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude < 1e-6 else { return value }
        return value < 0 ? -1e-6 : 1e-6
    }
}

extension SceneState: SceneGraphScriptAPI {
    func layerName(_ id: Int) -> String? { layers[id]?.name }

    func layerAlpha(_ id: Int) -> Double { Double(layers[id]?.alpha ?? 1) }

    func setLayerAlpha(_ id: Int, _ value: Double) {
        layers[id]?.alpha = min(max(Float(value), 0), 1)
    }

    func layerVisible(_ id: Int) -> Bool { layers[id]?.visible ?? true }

    func setLayerVisible(_ id: Int, _ value: Bool) { layers[id]?.visible = value }

    func layerOrigin(_ id: Int) -> SIMD3<Float> { layers[id]?.origin ?? .zero }

    func setLayerOrigin(_ id: Int, _ value: SIMD3<Float>) { layers[id]?.origin = value }

    func layerScale(_ id: Int) -> SIMD3<Float> { layers[id]?.scale ?? SIMD3(1, 1, 1) }

    func setLayerScale(_ id: Int, _ value: SIMD3<Float>) { layers[id]?.scale = value }

    func layerSize(_ id: Int) -> SIMD2<Float> { layers[id]?.size ?? SIMD2(1, 1) }

    func layerAngles(_ id: Int) -> SIMD3<Float> { SIMD3(0, 0, (layers[id]?.anglesZ ?? 0) * 180 / .pi) }

    func setLayerAngles(_ id: Int, _ value: SIMD3<Float>) {
        guard let layer = layers[id] else { return }
        layer.anglesZ = value.z * .pi / 180
        layer.worldIsCurrent = false
        worldCache.removeValue(forKey: id)
    }

    /// 运行时建图层：编号从 900000 起（和场景里的编号不会撞），排在已有图层之后（按建的先后），
    /// 渲染器下一帧把它建成绘制项
    func createLayer(model: String) -> Int? {
        guard nextRuntimeLayerID - 900_000 < Self.maximumRuntimeLayers else { return nil }
        let id = nextRuntimeLayerID
        nextRuntimeLayerID += 1
        layers[id] = Layer(id: id, name: model, sceneIndex: sceneOrder.count)
        sceneOrder.append(id)
        pendingLayers.append((id, model))
        return id
    }

    /// 取走"还没建的图层"（渲染器每帧开头调用）
    func drainPendingLayers() -> [(id: Int, model: String)] {
        let requests = pendingLayers
        pendingLayers.removeAll(keepingCapacity: true)
        return requests
    }

    func layerChildren(_ id: Int) -> [Int] { layers[id]?.children ?? [] }

    func layerIndex(_ id: Int) -> Int { layers[id]?.sceneIndex ?? -1 }

    /// 同名图层很常见，按场景顺序取第一个（字典的遍历顺序每次运行都可能不同）
    func layerID(named name: String) -> Int? { sceneOrder.first { layers[$0]?.name == name } }

    func sortLayer(_ id: Int, index: Int) { layers[id]?.order = index }

    func layerAlignment(_ id: Int) -> String {
        guard let anchor = layers[id]?.anchor else { return "center" }
        let vertical = anchor.y > 0 ? "top" : anchor.y < 0 ? "bottom" : ""
        let horizontal = anchor.x < 0 ? "left" : anchor.x > 0 ? "right" : ""
        let name = vertical + horizontal
        return name.isEmpty ? "center" : name
    }

    func setLayerAlignment(_ id: Int, _ value: String) { layers[id]?.anchor = Self.anchor(value) }
}
