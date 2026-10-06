import Foundation
import simd

/// scene.json 解析后的结构，只保留渲染需要的部分。
///
/// 约定（2026-09-28 用 ~/wp 的真实场景核对）：
/// - 正交场景的画布大小是 general.orthogonalprojection，坐标原点在左下角，y 轴向上；
/// - 对象的 origin 是图层中心在画布（或父对象）坐标系里的位置，size 是图层尺寸，scale 是缩放，
///   angles 是按弧度的旋转（2D 场景只用 z）；
/// - parent 指向分组对象的 id，子对象的变换相对于父对象；
/// - 很多字段既可以直接写值，也可以写成 {"value": …, "user": …} 或 {"script": …, "value": …}，
///   这里统一取其中的 value，并记下哪些字段由脚本驱动；
/// - 向量写成空格分隔的字符串，例如 "1920.00000 1080.00000 0.00000"。
public struct SceneDescription: Sendable {
    public struct Object: Sendable {
        public enum Kind: Sendable, Equatable {
            case image(model: String)
            case particle(String)
            case text
            case sound
            case light
            case camera
            /// 没有贴图的形状（例如给光束特效用的矩形）
            case shape
            /// 只提供变换、给子对象当父节点的分组
            case group
        }

        public let id: Int
        public let name: String
        public let parent: Int?
        public let kind: Kind
        public let origin: SIMD3<Float>
        public let scale: SIMD3<Float>
        public let angles: SIMD3<Float>
        public let size: SIMD2<Float>?
        public let isVisible: Bool
        public let alpha: Float
        public let color: SIMD3<Float>
        /// 图层亮度（`brightness`）：颜色整体乘它，默认 1
        public let brightness: Float
        /// Photoshop 式的图层混合模式，0 为普通
        public let colorBlendMode: Int
        public let effects: [Effect]
        public var effectFiles: [String] { effects.map(\.file) }
        /// 由 SceneScript 驱动的字段名。M4 只用它们的静态值
        public let scriptedFields: [String]
        /// 脚本驱动的字段：字段名（origin / scale / alpha / color / visible…）→ 脚本
        public var fieldScripts: [String: FieldScript] = [:]
        /// 粒子对象的实例覆盖；其他对象为 nil
        public var particleOverride: ParticleOverride? = nil
        /// 木偶图层播放的动画层
        public var animationLayers: [AnimationLayer] = []
        /// 文字图层的内容与排版；其他图层为 nil
        public var textContent: TextContent? = nil
        /// 声音对象的设置；其他对象为 nil
        public var sound: SoundContent? = nil
        /// 2D 摄像机；其他对象为 nil
        public var camera: Camera? = nil
        /// 图层的对齐方式（WE 的 alignment）：原点对着图像的哪个点——`center`（默认）、`top`、`bottom`、
        /// `left`、`right`、`topleft` 这类组合。`bottom` 时图像从原点往上长，缩放也以底边为基准
        public var alignment: String = "center"
        /// 挂在父木偶的哪个挂点上（`"attachment": "鞋"`，名字对应父模型 MDAT 段里的挂点）：
        /// 位置以挂点为原点，跟着那根骨骼动；nil 表示直接相对父图层
        public var attachment: String? = nil
        /// 图层的视差深度（`general.cameraparallax` 打开时用）：镜头随鼠标挪多少，这一层跟着挪
        /// depth 倍。(0, 0) 是不动，(1, 1) 跟满。WE 里默认 (1, 1)
        public var parallaxDepth: SIMD2<Float> = SIMD2(1, 1)
    }

    /// 2D 摄像机的动画（`~/wp` 里只有 Lucy 用了：开场从 3 倍拉远到 1 倍，同时平移）。
    ///
    /// `zoom` 是放大倍数（1 = 正常取景）；`origin` 是摄像机相对画布中心的位置。带 `relative` 时关键帧是
    /// **相对静态值**的偏移——Lucy 的末帧正好抵消静态值，也就是开场结束后回到正常取景，这和"它第 5 秒的
    /// 画面和预览图一致"对得上。
    public struct Camera: Sendable {
        public let zoomAnimation: PropertyAnimation?
        public let zoom: Float
        public let originAnimation: PropertyAnimation?
        public let origin: SIMD3<Float>
        public let originIsRelative: Bool

        public var isAnimated: Bool { zoomAnimation != nil || originAnimation != nil }

        /// 某一时刻的放大倍数和相对画布中心的位置
        public func state(at seconds: Float) -> (zoom: Float, origin: SIMD3<Float>) {
            var magnification = zoom
            if let zoomAnimation, let value = zoomAnimation.value(at: seconds).first { magnification = value }
            var position = origin
            if let originAnimation {
                let values = originAnimation.value(at: seconds)
                let offset = SIMD3(
                    values.count > 0 ? values[0] : 0, values.count > 1 ? values[1] : 0,
                    values.count > 2 ? values[2] : 0)
                position = originIsRelative ? position + offset : offset
            }
            return (max(magnification, 0.01), position)
        }

        init?(_ raw: [String: Any]) {
            guard raw["camera"] != nil else { return nil }
            zoomAnimation = PropertyAnimation(raw["zoom"])
            zoom = SceneValue.float(raw["zoom"]) ?? 1
            originAnimation = PropertyAnimation(raw["origin"])
            origin = SceneValue.vector3(raw["origin"]) ?? .zero
            let animation = (raw["origin"] as? [String: Any])?["animation"] as? [String: Any]
            originIsRelative = (animation?["relative"] as? NSNumber)?.boolValue ?? false
        }
    }

    /// 声音对象（2026-09-28 用 Lucy 场景里唯一的声音对象核对字段；含义按 WE 编辑器的选项名理解）
    public struct SoundContent: Sendable, Equatable {
        /// 声音文件，包内或 WE 自带素材目录里的路径
        public let files: [String]
        /// loop（循环）、random（放完一段随机等 minTime…maxTime 秒再随机放一段）、single（只放一次）
        public let playbackMode: String
        public let minTime: Float
        public let maxTime: Float
        /// random 模式开场先等一段再放
        public let startSilent: Bool
        /// 0–1
        public let volume: Float
        /// 音量的关键帧动画（Lucy 从 0.5 在 38 帧内升到 0.8）；有它时以它为准
        public let volumeAnimation: PropertyAnimation?

        public init(
            files: [String], playbackMode: String, minTime: Float, maxTime: Float, startSilent: Bool, volume: Float,
            volumeAnimation: PropertyAnimation?
        ) {
            self.files = files
            self.playbackMode = playbackMode
            self.minTime = minTime
            self.maxTime = maxTime
            self.startSilent = startSilent
            self.volume = volume
            self.volumeAnimation = volumeAnimation
        }

        /// 开始播放后 seconds 秒时的音量
        public func volume(at seconds: Float) -> Float {
            min(max(volumeAnimation?.value(at: seconds).first ?? volume, 0), 1)
        }
    }

    /// 一个"由脚本驱动"的字段：脚本源码 + 场景里的用户属性（文字字段单独走 TextContent）
    public struct FieldScript: Sendable, Equatable {
        public let source: String
        public let properties: Data?

        public init(source: String, properties: Data?) {
            self.source = source
            self.properties = properties
        }

        /// 字段脚本里的值也会写成 {"user": …, "value": …}，统一取出 value
        static func properties(_ raw: Any?) -> Data? {
            (raw as? [String: Any]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0.mapValues(SceneDescription.unwrapDeep))
            }
        }
    }

    /// 文字图层。WE 把文字写在 `text` 字段里：可以直接是字符串，也可以是"脚本 + 编辑器里的静态值"，
    /// 时钟就是这样（脚本里 new Date() 拼出字符串，静态值只是编辑器里的预览）。
    public struct TextContent: Sendable, Equatable {
        /// 字体文件路径，包内或 WE 自带素材目录里的 .ttf / .otf
        public let font: String
        /// 字号，单位和画布坐标一致
        public let pointSize: Float
        /// 文字框（画布坐标），文字在框里按对齐方式摆放
        public let boxSize: SIMD2<Float>
        public let horizontalAlign: String
        public let verticalAlign: String
        /// 编辑器里存的静态文字。脚本跑不了时显示它
        public let staticText: String
        /// 算文字内容的脚本；nil 表示文字是固定的
        public let script: String?
        /// 脚本的用户属性（场景里的覆盖值），JSON 形式
        public let scriptProperties: Data?
        /// 文字框四周给特效留的边（画布坐标）。WE 的文字图层有这一项，辉光、阴影这类特效
        /// 在"框 + 留边"里算，留边之外的会被切掉
        public let padding: Float

        public init(
            font: String, pointSize: Float, boxSize: SIMD2<Float>, horizontalAlign: String, verticalAlign: String,
            staticText: String, script: String?, scriptProperties: Data?, padding: Float = 0
        ) {
            self.font = font
            self.pointSize = pointSize
            self.boxSize = boxSize
            self.horizontalAlign = horizontalAlign
            self.verticalAlign = verticalAlign
            self.staticText = staticText
            self.script = script
            self.scriptProperties = scriptProperties
            self.padding = padding
        }
    }

    /// 木偶图层上的一层动画（animationlayers[]）。animation 是 .mdl 里动画的编号
    public struct AnimationLayer: Sendable, Equatable {
        public let animation: Int
        /// 混合权重 0–1
        public let blend: Float
        /// 播放速度倍数
        public let rate: Float
        /// true：叠加在其他层之上（相对绑定姿势的增量相加）；false：按权重覆盖
        public let additive: Bool
        public let isVisible: Bool
        /// 起始进度 0–1：这一层从动画的哪个位置开始播（`shared.offsetedStartAni`）。
        /// 0 表示从头开始；循环动画相当于把相位往后挪
        public let startProgress: Float
    }

    /// 图层上的一个特效实例，以及它对特效定义里各通道的覆盖设置
    public struct Effect: Sendable {
        public struct PassOverride: Sendable {
            /// 开关
            public let combos: [String: Int]
            /// 按槽位替换的贴图；nil 表示不替换
            public let textures: [String?]
            /// 材质参数（键是着色器注释里的 "material" 名），值统一成浮点分量
            public let constants: [String: [Float]]
        }

        public let file: String
        public let isVisible: Bool
        public let passes: [PassOverride]
    }

    /// 场景的投影方式。WE 用 `general.orthogonalprojection` 的存在形式区分（2026-09-28 对着
    /// 旗帜场景 / WE 自带的 modeleditor、particleelementpreviews 核对）：
    /// - 写了宽高 → 固定正交画布（绝大多数 2D 场景）；
    /// - 只写 `{"auto": true}` → 正交、画布按场景内容撑满（旗帜类模板把宽高留空）；
    /// - `null` 或缺省 → 用顶层 `camera` 做透视投影（真正的 3D 场景，例如 WE 的模型/粒子编辑器预览）。
    public enum Projection: Sendable, Equatable {
        case fixed(SIMD2<Float>)
        case auto
        case perspective
    }

    /// 顶层 `camera {eye, center, up}`：3D 场景的视角。2D 场景（含 auto）的 scene.json 里也可能带一个
    /// 默认相机，但 WE 渲染 2D 时不使用它
    public struct ViewCamera: Sendable, Equatable {
        public let eye: SIMD3<Float>
        public let center: SIMD3<Float>
        public let up: SIMD3<Float>

        public init(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) {
            self.eye = eye
            self.center = center
            self.up = up
        }
    }

    public let version: Int?
    /// 正交场景的画布尺寸；透视场景为 nil
    public let canvasSize: SIMD2<Float>?
    /// 投影方式（见 `Projection`）
    public let projection: Projection
    /// 顶层相机（透视场景用）；2D 场景也会解析出来，但渲染时忽略
    public let viewCamera: ViewCamera?
    /// 垂直视场角（度）。`general.perspectiveoverridefov` 优先于 `general.fov`，都没有时用 50
    /// （WE 新建 3D 场景的默认值）
    public let fov: Float
    public let nearz: Float
    public let farz: Float
    /// `.auto` 投影时内容包围盒的尺寸和中心：画布按它撑满，"铺满裁切"时就以这个中心为准
    public let contentExtent: (size: SIMD2<Float>, center: SIMD2<Float>)?
    public let clearColor: SIMD3<Float>
    public let clearEnabled: Bool
    public let objects: [Object]
    /// 场景泛光（general.bloom）；nil 表示没开，或者是 HDR 场景（见 `Bloom`）
    public let bloom: Bloom?
    /// 场景级的相机效果（general 里的 zoom / 视差 / 镜头抖动）。和"摄像机对象"（`Object.camera`）不同：
    /// 这一套作用于整个场景，是 WE 编辑器"场景设置 → 相机"那一页
    public let cameraEffects: CameraEffects
    /// 场景级的重力（general.gravitydirection × gravitystrength）：粒子默认受它影响
    public let gravity: SIMD3<Float>
    /// 场景级的风（general.windenabled 时的 winddirection × windstrength）
    public let wind: SIMD3<Float>

    /// 场景级的相机效果。字段名对应 scene.json 里 `general` 层的那几个键
    /// （2026-10-06 在本机 329 个场景里统计过：camerafade 328、parallax 16、shake 3、zoom≠1 5）。
    public struct CameraEffects: Sendable, Equatable {
        /// `general.zoom`：整个场景的放大倍数，1 是正常取景（绕画布中心缩放）
        public var zoom: Float = 1
        /// `general.cameraparallax`：镜头随鼠标的视差是否打开
        public var parallaxEnabled: Bool = false
        public var parallaxAmount: Float = 0
        /// 平滑时间（秒）：鼠标动完镜头慢慢跟过去
        public var parallaxDelay: Float = 0
        public var parallaxMouseInfluence: Float = 0
        /// `general.camerashake`：镜头是否随时间抖动
        public var shakeEnabled: Bool = false
        public var shakeAmplitude: Float = 0
        public var shakeRoughness: Float = 0
        public var shakeSpeed: Float = 0
        /// `general.camerafade`：WE 加载时把画面淡入（本渲染器不实现，只记下来给验收用）
        public var fadeEnabled: Bool = false

        public init() {}

        /// 这套效果是不是"什么都不做"
        public var isIdentity: Bool {
            abs(zoom - 1) < 1e-4 && !parallaxEnabled && !shakeEnabled
        }
    }

    /// WE 的场景泛光：整帧里亮的部分提出来、模糊、加回去（WE 自带素材 `shaders/downsample_quarter_bloom` 等）。
    /// 只认非 HDR 场景：HDR 场景（`hdr: true`）的泛光是另一套（阈值 1，亮度超过 1 的部分才泛光，多级迭代），
    /// 要浮点精度渲染才有意义；我们的画面是 8 位的，照搬会让本来就是纯白的地方（窗户、天空）都泛光
    public struct Bloom: Sendable, Equatable {
        /// 着色器默认值：强度 2、阈值 0.65、色调白
        public var strength: Float = 2
        public var threshold: Float = 0.65
        public var tint = SIMD3<Float>(1, 1, 1)
    }

    /// - Parameters:
    ///   - userProperties: 用户属性的当前值（名字 → 值，JSON 对象）。给了就先把场景里
    ///     `{"user": …, "value": …}` 的绑定换成这些值（见 `applyingUserProperties`）
    ///   - hiddenElements: 用户在设置里关掉的内容（见 `SceneElements`），标成不可见
    public init(json data: Data, userProperties: Data? = nil, hiddenElements: Set<String> = []) throws {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FormatError("scene.json 不是有效的 JSON")
        }
        if let values = userProperties.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           !values.isEmpty {
            root = Self.applyingUserProperties(values, to: root) as? [String: Any] ?? root
        }
        // 在代入属性之后：用户关掉的就是关掉，不管作者把它绑到了哪个属性上
        root = SceneElements.hiding(hiddenElements, in: root)
        let general = root["general"] as? [String: Any] ?? [:]
        version = root["version"] as? Int
        if let ortho = general["orthogonalprojection"] as? [String: Any] {
            if let width = SceneValue.float(ortho["width"]), let height = SceneValue.float(ortho["height"]),
               width > 0, height > 0 {
                projection = .fixed(SIMD2(width, height))
                canvasSize = SIMD2(width, height)
            } else if SceneValue.bool(ortho["auto"]) == true {
                projection = .auto
                canvasSize = nil
            } else {
                projection = .perspective
                canvasSize = nil
            }
        } else {
            projection = .perspective
            canvasSize = nil
        }
        let camera = root["camera"] as? [String: Any]
        if let eye = SceneValue.vector3(camera?["eye"]), let center = SceneValue.vector3(camera?["center"]) {
            viewCamera = ViewCamera(
                eye: eye, center: center, up: SceneValue.vector3(camera?["up"]) ?? SIMD3(0, 1, 0))
        } else {
            viewCamera = nil
        }
        fov = SceneValue.float(general["perspectiveoverridefov"]) ?? SceneValue.float(general["fov"]) ?? 50
        nearz = SceneValue.float(general["nearz"]) ?? 0.1
        farz = SceneValue.float(general["farz"]) ?? 10_000
        clearColor = SceneValue.vector3(general["clearcolor"]) ?? SIMD3(0, 0, 0)
        clearEnabled = SceneValue.bool(general["clearenabled"]) ?? true
        if SceneValue.bool(general["bloom"]) == true, SceneValue.bool(general["hdr"]) != true {
            var bloom = Bloom()
            if let strength = SceneValue.float(general["bloomstrength"]) { bloom.strength = strength }
            if let threshold = SceneValue.float(general["bloomthreshold"]) { bloom.threshold = threshold }
            if let tint = SceneValue.vector3(general["bloomtint"]) { bloom.tint = tint }
            self.bloom = bloom
        } else {
            bloom = nil
        }
        var effects = CameraEffects()
        // zoom 只认正的有限值：0 或负数会让整个投影退化
        if let value = SceneValue.float(general["zoom"]), value > 1e-3 { effects.zoom = value }
        effects.parallaxEnabled = SceneValue.bool(general["cameraparallax"]) ?? false
        effects.parallaxAmount = SceneValue.float(general["cameraparallaxamount"]) ?? 0
        effects.parallaxDelay = SceneValue.float(general["cameraparallaxdelay"]) ?? 0
        effects.parallaxMouseInfluence = SceneValue.float(general["cameraparallaxmouseinfluence"]) ?? 0
        effects.shakeEnabled = SceneValue.bool(general["camerashake"]) ?? false
        effects.shakeAmplitude = SceneValue.float(general["camerashakeamplitude"]) ?? 0
        effects.shakeRoughness = SceneValue.float(general["camerashakeroughness"]) ?? 0
        effects.shakeSpeed = SceneValue.float(general["camerashakespeed"]) ?? 0
        effects.fadeEnabled = SceneValue.bool(general["camerafade"]) ?? false
        cameraEffects = effects
        // 重力 / 风：方向和强度分开写，乘起来就是加速度。都没写时是 0（不受影响）
        let gravityStrength = SceneValue.float(general["gravitystrength"]) ?? 0
        gravity = gravityStrength == 0
            ? .zero : (SceneValue.vector3(general["gravitydirection"]) ?? SIMD3(0, -1, 0)) * gravityStrength
        let windEnabled = SceneValue.bool(general["windenabled"]) ?? false
        let windStrength = SceneValue.float(general["windstrength"]) ?? 0
        wind = windEnabled && windStrength != 0
            ? (SceneValue.vector3(general["winddirection"]) ?? .zero) * windStrength : .zero
        let parsedObjects = (root["objects"] as? [[String: Any]] ?? []).map(Self.object)
        objects = parsedObjects
        contentExtent = Self.contentExtent(of: parsedObjects)
    }

    /// 所有带尺寸的对象摆好以后的总包围盒：`.auto` 投影靠它算画布。忽略没有 size 的对象
    /// （粒子、声音等），都没有尺寸时返回 nil，由渲染器退回屏幕尺寸
    static func contentExtent(of objects: [Object]) -> (size: SIMD2<Float>, center: SIMD2<Float>)? {
        let byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cache: [Int: simd_float4x4] = [:]
        func world(_ id: Int, depth: Int = 0) -> simd_float4x4 {
            if let cached = cache[id] { return cached }
            guard let object = byID[id], depth < 64 else { return matrix_identity_float4x4 }
            let local = translation(object.origin) * rotationZ(object.angles.z) * scaling(object.scale)
            var matrix = local
            if let parent = object.parent, parent != id, byID[parent] != nil {
                matrix = world(parent, depth: depth + 1) * local
            }
            cache[id] = matrix
            return matrix
        }
        var lo = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = -lo
        var found = false
        for object in objects {
            guard let size = object.size, size.x > 0, size.y > 0 else { continue }
            let half = size / 2
            let matrix = world(object.id)
            for corner in [
                SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(-half.x, half.y), SIMD2(half.x, half.y),
            ] {
                let point = matrix * SIMD4(corner.x, corner.y, 0, 1)
                lo = simd_min(lo, SIMD2(point.x, point.y))
                hi = simd_max(hi, SIMD2(point.x, point.y))
                found = true
            }
        }
        guard found else { return nil }
        return (hi - lo, (hi + lo) / 2)
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
        simd_float4x4(diagonal: SIMD4(scale.x, scale.y, scale.z, 1))
    }

    private static func object(_ raw: [String: Any]) -> Object {
        let kind: Object.Kind
        if let model = SceneValue.string(raw["image"]) {
            kind = .image(model: model)
        } else if let particle = SceneValue.string(raw["particle"]) {
            kind = .particle(particle)
        } else if raw["text"] != nil {
            kind = .text
        } else if raw["sound"] != nil {
            kind = .sound
        } else if raw["light"] != nil {
            kind = .light
        } else if raw["camera"] != nil {
            kind = .camera
        } else if raw["shape"] != nil {
            kind = .shape
        } else {
            kind = .group
        }

        let scripted = raw.compactMap { key, value in
            ((value as? [String: Any])?["script"] != nil) ? key : nil
        }
        // text 由 TextContent 单独处理，这里只收属性字段
        var fieldScripts: [String: FieldScript] = [:]
        for (key, value) in raw where key != "text" {
            guard let object = value as? [String: Any], let script = object["script"] as? String else { continue }
            fieldScripts[key] = FieldScript(
                source: script, properties: FieldScript.properties(object["scriptproperties"]))
        }
        let effects = (raw["effects"] as? [[String: Any]] ?? []).compactMap(Self.effect)
        var particleOverride: ParticleOverride?
        if case .particle = kind {
            particleOverride = (raw["instanceoverride"] as? [String: Any]).map(ParticleOverride.init) ?? ParticleOverride()
        }
        let animationLayers = (raw["animationlayers"] as? [[String: Any]] ?? []).compactMap { layer -> AnimationLayer? in
            guard let animation = SceneValue.int(layer["animation"]) else { return nil }
            return AnimationLayer(
                animation: animation, blend: SceneValue.float(layer["blend"]) ?? 1, rate: SceneValue.float(layer["rate"]) ?? 1,
                additive: SceneValue.bool(layer["additive"]) ?? false, isVisible: SceneValue.bool(layer["visible"]) ?? true,
                startProgress: Self.startProgress(layer["visible"]))
        }
        var sound: SoundContent?
        if case .sound = kind {
            let files: [String]
            switch raw["sound"] {
            case let list as [Any]: files = list.compactMap { $0 as? String }
            case let single as String: files = [single]
            default: files = []
            }
            sound = SoundContent(
                files: files, playbackMode: SceneValue.string(raw["playbackmode"]) ?? "loop",
                minTime: SceneValue.float(raw["mintime"]) ?? 0, maxTime: SceneValue.float(raw["maxtime"]) ?? 0,
                startSilent: SceneValue.bool(raw["startsilent"]) ?? false, volume: SceneValue.float(raw["volume"]) ?? 1,
                volumeAnimation: PropertyAnimation(raw["volume"]))
        }
        let textContent: TextContent?
        if case .text = kind {
            textContent = Self.textContent(raw)
        } else {
            textContent = nil
        }
        return Object(
            id: raw["id"] as? Int ?? 0,
            name: raw["name"] as? String ?? "",
            parent: raw["parent"] as? Int,
            kind: kind,
            origin: SceneValue.vector3(raw["origin"]) ?? .zero,
            scale: SceneValue.vector3(raw["scale"]) ?? SIMD3(1, 1, 1),
            angles: SceneValue.vector3(raw["angles"]) ?? .zero,
            size: SceneValue.vector2(raw["size"]),
            isVisible: SceneValue.bool(raw["visible"]) ?? true,
            alpha: SceneValue.float(raw["alpha"]) ?? 1,
            color: SceneValue.vector3(raw["color"]) ?? SIMD3(1, 1, 1),
            brightness: SceneValue.float(raw["brightness"]) ?? 1,
            colorBlendMode: SceneValue.int(raw["colorBlendMode"]) ?? 0,
            effects: effects,
            scriptedFields: scripted.sorted(),
            fieldScripts: fieldScripts,
            particleOverride: particleOverride,
            animationLayers: animationLayers,
            textContent: textContent,
            sound: sound,
            camera: Self.camera(raw, kind: kind),
            alignment: SceneValue.string(raw["alignment"])?.lowercased() ?? "center",
            attachment: SceneValue.string(raw["attachment"]).flatMap { $0.isEmpty ? nil : $0 },
            parallaxDepth: SceneValue.vector2(raw["parallaxDepth"]) ?? SIMD2(1, 1))
    }

    /// 2D 摄像机：只有 `camera` 类的对象有；透视场景的摄像机靠 `fov`/`perspective` 区分，这里不处理
    static func camera(_ raw: [String: Any], kind: Object.Kind) -> Camera? {
        guard kind == .camera, raw["perspective"] as? Bool != true else { return nil }
        return Camera(raw)
    }

    /// 文字图层的字段（2026-09-28 用 ~/wp 里 13 个文字对象核对：都有 font / pointsize / size /
    /// horizontalalign / verticalalign，都是居中、单行）
    static func textContent(_ raw: [String: Any]) -> TextContent? {
        guard let text = raw["text"] else { return nil }
        let object = text as? [String: Any]
        let staticText = SceneValue.string(text)
        guard object != nil || staticText != nil else { return nil }
        // 脚本属性里的值也会写成 {"user": …, "value": …}（用户属性引用），统一取出里面的 value
        let properties = (object?["scriptproperties"] as? [String: Any]).flatMap {
            try? JSONSerialization.data(withJSONObject: $0.mapValues(Self.unwrapDeep))
        }
        return TextContent(
            font: SceneValue.string(raw["font"]) ?? "",
            pointSize: SceneValue.float(raw["pointsize"]) ?? 24,
            boxSize: SceneValue.vector2(raw["size"]) ?? SIMD2(128, 64),
            horizontalAlign: SceneValue.string(raw["horizontalalign"]) ?? "center",
            verticalAlign: SceneValue.string(raw["verticalalign"]) ?? "center",
            staticText: staticText ?? "",
            script: object?["script"] as? String,
            scriptProperties: properties,
            padding: max(0, SceneValue.float(raw["padding"]) ?? 0))
    }

    /// 把场景里绑定到用户属性的值换成属性的当前值。WE 运行时就是这么做的：场景文件里的 value 只是作者
    /// 保存时编辑器里的值（~/wp 里 102 处直接绑定有 32 处和 project.json 的默认值不同），用户看到的是属性值。
    /// - `{"user": "名字", "value": v}`：换成属性值。类型对不上（开关属性绑在数值字段上之类）时 WE 怎么换算
    ///   不清楚，保留场景里的值；数字写成字符串的（下拉选项的值常这样）按数字代入数值字段；
    /// - `{"user": {"condition": "c", "name": "名字"}, "value": v}`：换成"属性值等于 c"（幻灯片选哪一张就是这样）
    static func applyingUserProperties(_ values: [String: Any], to node: Any) -> Any {
        if let list = node as? [Any] { return list.map { applyingUserProperties(values, to: $0) } }
        guard var dictionary = node as? [String: Any] else { return node }
        for (key, value) in dictionary where key != "value" {
            dictionary[key] = applyingUserProperties(values, to: value)
        }
        guard let current = dictionary["value"], let user = dictionary["user"] else {
            if let value = dictionary["value"] { dictionary["value"] = applyingUserProperties(values, to: value) }
            return dictionary
        }
        if let name = user as? String, let property = values[name] {
            if let converted = converted(property, like: current) { dictionary["value"] = converted }
        } else if let binding = user as? [String: Any], let name = binding["name"] as? String,
                  let property = values[name], let condition = binding["condition"] {
            dictionary["value"] = conditionText(property) == conditionText(condition)
        }
        return dictionary
    }

    private static func isBool(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    /// 属性值按场景里原来那个值的类型代入；类型对不上返回 nil
    private static func converted(_ property: Any, like current: Any) -> Any? {
        switch (isBool(current), current, isBool(property), property) {
        case (true, _, true, _): return property
        case (false, is NSNumber, false, let number as NSNumber): return number
        case (false, is NSNumber, _, let text as String): return Double(text.trimmingCharacters(in: .whitespaces))
        case (false, is String, _, let text as String): return text
        default: return nil
        }
    }

    /// 条件比较用的文字：整数不带小数点，布尔是 true / false
    private static func conditionText(_ value: Any) -> String {
        if isBool(value) { return (value as! NSNumber).boolValue ? "true" : "false" }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.rounded() == double && abs(double) < 1e15 ? String(Int64(double)) : String(double)
        }
        return "\(value)"
    }

    /// 递归取出 {"user": …, "value": …} / {"script": …, "value": …} 里的 value
    static func unwrapDeep(_ value: Any) -> Any {
        let unwrapped = SceneValue.unwrap(value) ?? value
        if let dictionary = unwrapped as? [String: Any] { return dictionary.mapValues(unwrapDeep) }
        if let array = unwrapped as? [Any] { return array.map(unwrapDeep) }
        return unwrapped
    }

    /// 动画层的 visible 字段上可以挂脚本。`shared.offsetedStartAni` 不是引擎内置的，而是 Lucy 场景里
    /// 另一段内联脚本定义在 `shared` 上的函数：把这一层的当前帧设成"总帧数 × scriptproperties.percentage"
    /// （Lucy 的头发、衣角层用它把几层循环错开）。动画层脚本要靠整个场景的脚本框架，属性脚本宿主
    /// （SceneScript）不跑这一类，这里只认出这一种写法：脚本里出现 offsetedStartAni 且带了 percentage。
    /// 滑块默认值是 1，对循环动画相当于不偏移，所以这个默认值不会改变别的场景的行为
    static func startProgress(_ raw: Any?) -> Float {
        guard let object = raw as? [String: Any],
              let script = object["script"] as? String, script.contains("offsetedStartAni"),
              let properties = object["scriptproperties"] as? [String: Any],
              let percentage = SceneValue.float(properties["percentage"])
        else { return 0 }
        return min(max(percentage, 0), 1)
    }
}

extension SceneDescription {
    fileprivate static func effect(_ raw: [String: Any]) -> Effect? {
        guard let file = raw["file"] as? String else { return nil }
        let passes = (raw["passes"] as? [[String: Any]] ?? []).map { pass in
            Effect.PassOverride(
                combos: (pass["combos"] as? [String: Any] ?? [:]).compactMapValues { SceneValue.int($0) },
                textures: (pass["textures"] as? [Any] ?? []).map { $0 as? String },
                constants: (pass["constantshadervalues"] as? [String: Any] ?? [:]).mapValues(SceneValue.floats))
        }
        return Effect(file: file, isVisible: SceneValue.bool(raw["visible"]) ?? true, passes: passes)
    }
}

/// 读取 WE 场景文件里的各种值写法
public enum SceneValue {
    /// {"value": x, "user": …} 或 {"script": …, "value": x} 取出 x；其他原样返回
    public static func unwrap(_ raw: Any?) -> Any? {
        if let dictionary = raw as? [String: Any],
           dictionary["value"] != nil || dictionary["script"] != nil || dictionary["user"] != nil {
            return dictionary["value"]
        }
        return raw
    }

    public static func string(_ raw: Any?) -> String? {
        unwrap(raw) as? String
    }

    public static func bool(_ raw: Any?) -> Bool? {
        switch unwrap(raw) {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return ["true", "1"].contains(value.lowercased())
        default: return nil
        }
    }

    /// NaN、无穷大（"nan"、1e300 这种）当成没写：坏文件里的这些数一路算下去会让渲染崩掉
    public static func float(_ raw: Any?) -> Float? {
        let value: Float?
        switch unwrap(raw) {
        case let number as NSNumber: value = number.floatValue
        case let text as String: value = Float(text.trimmingCharacters(in: .whitespaces))
        default: value = nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    /// 整数（编号、开关、上限）：按 `float` 读，太大太小的截到 ±2⁵²。直接写 `Int(x)` 遇到 1e20 这种
    /// 有限但超出 Int 范围的数会让整个 App 崩掉
    public static func int(_ raw: Any?) -> Int? {
        float(raw).map { Int(min(max(Double($0), -0x1p52), 0x1p52)) }
    }

    static func components(_ raw: Any?) -> [Float]? {
        switch unwrap(raw) {
        case let text as String:
            let parts = numbers(in: text)
            return parts.isEmpty ? nil : parts
        case let number as NSNumber:
            return number.floatValue.isFinite ? [number.floatValue] : nil
        default:
            return nil
        }
    }

    /// 把一段写着数字的字符串切成数值。WE 的向量有的是空格分隔（"1 0.5"），有的是逗号分隔
    /// （"0.0, 1.0"，特效参数里很常见），两种都当分隔符。有 NaN、无穷大时整个当成没写
    static func numbers(in text: String) -> [Float] {
        let values = text.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Float($0) }
        return values.allSatisfy(\.isFinite) ? values : []
    }

    /// 只有一个分量时三个分量都用它（例如 "scale": "2"）
    public static func vector3(_ raw: Any?) -> SIMD3<Float>? {
        guard let values = components(raw) else { return nil }
        if values.count == 1 { return SIMD3(repeating: values[0]) }
        return SIMD3(values[0], values.count > 1 ? values[1] : 0, values.count > 2 ? values[2] : 0)
    }

    /// 材质参数的值：数字、布尔、"1 0.5" 这样的字符串，或者包在 {"value": …} 里
    public static func floats(_ raw: Any?) -> [Float] {
        switch unwrap(raw) {
        case let number as NSNumber: return number.floatValue.isFinite ? [number.floatValue] : []
        case let text as String: return numbers(in: text)
        case let array as [Any]: return array.flatMap(floats)
        default: return []
        }
    }

    static func vector2(_ raw: Any?) -> SIMD2<Float>? {
        guard let values = components(raw) else { return nil }
        return SIMD2(values[0], values.count > 1 ? values[1] : values[0])
    }
}
