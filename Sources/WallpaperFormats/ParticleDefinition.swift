import Foundation
import simd

/// 粒子系统定义（particles/*.json）。
///
/// 结构（2026-09-28 用 ~/wp 里 24 个场景的 38 个粒子系统、以及 WE 自带的 particles/example*.json 和
/// scenes/particleelementpreviews 核对；各字段的含义对照 docs.wallpaperengine.io 的粒子组件文档）：
///
///     material        材质（着色器都是 genericparticle）
///     maxcount        同时存在的粒子上限
///     starttime       载入时先在后台模拟这么多秒，画面一出来就是"已经下了一会儿"的样子
///     animationmode   精灵图怎么选帧："sequence"（随寿命播放，默认）或 "randomframe"（出生时随机选一帧）
///     sequencemultiplier  一生里把精灵图播几遍
///     emitter[]       发射器：sphererandom / boxrandom
///     initializer[]   出生时的随机初值：寿命、大小、颜色、透明度、速度、旋转……
///     operator[]      每帧的变化：运动、淡入淡出、闪烁、湍流……
///     renderer[]      画法：sprite / spritetrail / ropetrail
///     controlpoint[]  控制点；flags 第 0 位表示跟随鼠标
///     children[]      子系统：static（独立发射）或 eventfollow（在每个父粒子上生成并跟随它）
///
/// 组件里没写的字段用默认值。编辑器保存时会省略一部分字段，但 WE 没有公开默认值，
/// 各组件的默认值写在使用处（ParticleSimulation），都是按预览场景和真实文件推断的。
public struct ParticleDefinition: Sendable {
    /// 一个组件：名字，以及数值字段（向量拆成分量）和字符串字段
    public struct Component: Sendable {
        public let name: String
        public let numbers: [String: [Float]]
        public let strings: [String: String]

        public init(name: String, numbers: [String: [Float]] = [:], strings: [String: String] = [:]) {
            self.name = name
            self.numbers = numbers
            self.strings = strings
        }

        public func has(_ key: String) -> Bool { numbers[key] != nil || strings[key] != nil }

        public func float(_ key: String, _ fallback: Float) -> Float {
            numbers[key]?.first ?? fallback
        }

        /// 向量字段；只写了一个数时三个分量都用它（sphererandom 的 distancemax 就是一个数）
        public func vector(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            guard let values = numbers[key], let first = values.first else { return fallback }
            if values.count == 1 { return SIMD3(repeating: first) }
            return SIMD3(values[0], values.count > 1 ? values[1] : 0, values.count > 2 ? values[2] : 0)
        }

        init(_ raw: [String: Any]) {
            name = raw["name"] as? String ?? ""
            var numbers: [String: [Float]] = [:]
            var strings: [String: String] = [:]
            for (key, value) in raw where key != "name" {
                let unwrapped = SceneValue.unwrap(value)
                if let text = unwrapped as? String {
                    // 数字列表可能是空格或逗号分隔（"1 0.5" / "0.0, 1.0"）
                    let parts = text.replacingOccurrences(of: ",", with: " ")
                        .split(whereSeparator: \.isWhitespace)
                    // NaN、无穷大当成没写（用默认值）
                    let floats = parts.compactMap { Float($0) }.filter(\.isFinite)
                    if !parts.isEmpty, floats.count == parts.count {
                        numbers[key] = floats
                    } else {
                        strings[key] = text
                    }
                } else {
                    let floats = SceneValue.floats(unwrapped)
                    if !floats.isEmpty { numbers[key] = floats }
                }
            }
            self.numbers = numbers
            self.strings = strings
        }
    }

    public struct ControlPoint: Sendable, Equatable {
        public let id: Int
        public let offset: SIMD3<Float>
        /// flags 第 0 位：跟随鼠标（WE 自带的 examplecursorfollow / examplecursoravoid 就是这么用的）
        public let followsPointer: Bool
    }

    public struct Child: Sendable {
        public enum Kind: String, Sendable {
            /// 独立的子系统，放在父系统原点加 origin 的位置
            case `static`
            /// 每个新出生的父粒子上生成一份，跟着父粒子移动
            case eventFollow = "eventfollow"
            /// 父粒子出生时在它的位置生成，之后不跟随
            case eventSpawn = "eventspawn"
            /// 父粒子死亡时在它的位置生成
            case eventDeath = "eventdeath"
        }

        public let kind: Kind?
        /// 原始类型名，kind 不认识时用来报告
        public let typeName: String
        public let path: String
        public let origin: SIMD3<Float>
        public let angles: SIMD3<Float>
        public let scale: SIMD3<Float>
        public let probability: Float
    }

    public let material: String
    public let maxCount: Int
    public let startTime: Float
    public let animationMode: String?
    public let sequenceMultiplier: Float
    public let flags: Int
    public let emitters: [Component]
    public let initializers: [Component]
    public let operators: [Component]
    public let renderers: [Component]
    public let controlPoints: [ControlPoint]
    public let children: [Child]

    public init(json data: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FormatError("粒子定义不是有效的 JSON")
        }
        guard let material = root["material"] as? String else { throw FormatError("粒子定义没有材质") }
        self.material = material
        maxCount = max(0, SceneValue.int(root["maxcount"]) ?? 100)
        startTime = max(0, SceneValue.float(root["starttime"]) ?? 0)
        animationMode = SceneValue.string(root["animationmode"])
        sequenceMultiplier = SceneValue.float(root["sequencemultiplier"]) ?? 1
        flags = SceneValue.int(root["flags"]) ?? 0
        func components(_ key: String) -> [Component] {
            (root[key] as? [[String: Any]] ?? []).map(Component.init)
        }
        emitters = components("emitter")
        initializers = components("initializer")
        operators = components("operator")
        renderers = components("renderer")
        controlPoints = (root["controlpoint"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = SceneValue.int(raw["id"]) else { return nil }
            let flags = SceneValue.int(raw["flags"]) ?? 0
            return ControlPoint(
                id: id, offset: SceneValue.vector3(raw["offset"]) ?? .zero, followsPointer: flags & 1 != 0)
        }
        children = (root["children"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let path = raw["name"] as? String else { return nil }
            // 没写类型的子系统（真实文件里 14 个中有 13 个）按独立子系统处理：它们都有自己持续发射的发射器
            let typeName = raw["type"] as? String ?? Child.Kind.static.rawValue
            return Child(
                kind: Child.Kind(rawValue: typeName), typeName: typeName, path: path,
                origin: SceneValue.vector3(raw["origin"]) ?? .zero,
                angles: SceneValue.vector3(raw["angles"]) ?? .zero,
                scale: SceneValue.vector3(raw["scale"]) ?? SIMD3(1, 1, 1),
                probability: SceneValue.float(raw["probability"]) ?? 1)
        }
    }
}

/// 场景里粒子对象的 instanceoverride：对粒子系统整体的倍数调整（docs.wallpaperengine.io 的 IParticleSystemInstance）
public struct ParticleOverride: Sendable, Equatable {
    /// 透明度倍数
    public var alpha: Float = 1
    /// 大小倍数
    public var size: Float = 1
    /// 发射速率倍数（字段名是 count）
    public var count: Float = 1
    /// 初速度和各种力的倍数
    public var speed: Float = 1
    /// 寿命倍数
    public var lifetime: Float = 1
    /// 模拟速度倍数（字段名是 rate）
    public var rate: Float = 1
    /// 粒子颜色的倍数：新版字段名是 colorn（0–1），老场景（2018 年前后）写的是 color（0–255）
    public var color: SIMD3<Float>?
    /// 控制点位置覆盖（controlpoint0…7），系统自己的坐标
    public var controlPoints: [Int: SIMD3<Float>] = [:]

    public init() {}

    init(_ raw: [String: Any]) {
        alpha = SceneValue.float(raw["alpha"]) ?? 1
        size = SceneValue.float(raw["size"]) ?? 1
        count = SceneValue.float(raw["count"]) ?? 1
        speed = SceneValue.float(raw["speed"]) ?? 1
        lifetime = SceneValue.float(raw["lifetime"]) ?? 1
        rate = SceneValue.float(raw["rate"]) ?? 1
        color = SceneValue.vector3(raw["colorn"]) ?? SceneValue.vector3(raw["color"]).map { $0 / 255 }
        for index in 0..<8 {
            if let point = SceneValue.vector3(raw["controlpoint\(index)"]) { controlPoints[index] = point }
        }
    }
}
