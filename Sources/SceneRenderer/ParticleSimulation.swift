import Foundation
import simd
import WallpaperFormats

/// 一个粒子系统在 CPU 上的模拟：发射、出生时的随机初值、每帧的算子。坐标是粒子系统自己的坐标
/// （原点在系统对象的位置，y 向上，单位是画布像素），画的时候再乘对象的变换。
///
/// 组件的含义按 docs.wallpaperengine.io 的粒子组件文档：
/// - 时间类算子（alphafade、sizechange、alphachange）的时间是寿命的比例 0–1；
///   alphafade 的 fadeouttime 是"开始淡出的时刻"，不是淡出的时长；
/// - 振荡类算子的频率是"每一生振荡几次"；
/// - 速度要有 movement 算子才会让粒子移动，角速度要有 angularmovement 才会让粒子转动。
///
/// WE 没有公开各字段的默认值；这里的默认值（见各组件的解析处）是按 WE 自带的预览场景和真实文件推断的。
/// 还没实现的组件记在 `unsupported` 里，模拟时跳过。
final class ParticleSimulation {
    struct Particle {
        var id: UInt32
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var rotation: SIMD3<Float> = .zero
        var angularVelocity: SIMD3<Float> = .zero
        var color: SIMD3<Float> = SIMD3(1, 1, 1)
        var alpha: Float = 1
        var size: Float = 20
        var lifetime: Float = 1
        var age: Float = 0
        /// 出生时的随机数，randomframe 模式用它选帧
        var frameSeed: Float = 0
        /// eventfollow 子系统：跟随的父粒子编号；位置相对于父粒子
        var anchor: UInt32?

        /// ropetrail 画法用的历史：每一步记一条（位置、大小、透明度），环形缓冲，定长
        var trail = TrailHistory()

        // 每步由算子算出的绘制值
        var drawnAlpha: Float = 1
        var drawnSize: Float = 20
        var drawnOffset: SIMD3<Float> = .zero

        /// 已经活过的寿命比例
        var life: Float { lifetime > 0 ? min(age / lifetime, 1) : 1 }
    }

    /// 一次采样的位置历史和当时的绘制值
    struct TrailSample {
        var age: Float
        var position: SIMD3<Float>
        var alpha: Float
        var size: Float
    }

    /// 定长环形缓冲：每步追加一条采样，丢掉比 `length` 更早的。
    /// 用环形而不是数组是为了避免每步搬内存（Lucy 这种几百个粒子 × 每帧几十步的场景里很明显）
    struct TrailHistory {
        private var samples: [TrailSample] = []
        /// 最旧一条所在的位置
        private var tail = 0
        private(set) var count = 0

        init() {}
        init(capacity: Int) {
            samples = Array(repeating: TrailSample(age: 0, position: .zero, alpha: 0, size: 0),
                            count: max(capacity, 2))
        }

        var capacity: Int { samples.count }
        var isEmpty: Bool { count == 0 }
        /// 下一条要写的位置
        private var head: Int { (tail + count) % max(samples.count, 1) }

        mutating func append(_ sample: TrailSample) {
            guard !samples.isEmpty else { return }
            if count == samples.count {
                samples[tail] = sample
                tail = (tail + 1) % samples.count
            } else {
                samples[head] = sample
                count += 1
            }
        }

        /// 丢掉比 cutoff 更早的采样（采样按时间递增）
        mutating func drop(olderThan cutoff: Float) {
            while count > 0, self[0].age < cutoff {
                tail = (tail + 1) % samples.count
                count -= 1
            }
        }

        /// 只留最后 keep 条
        mutating func keepNewest(_ keep: Int) {
            guard keep < count else { return }
            tail = (tail + count - keep) % samples.count
            count = keep
        }

        subscript(index: Int) -> TrailSample {
            get { samples[(tail + index) % samples.count] }
            set { samples[(tail + index) % samples.count] = newValue }
        }
    }

    enum EmitterShape { case sphere, box }

    struct Emitter {
        let shape: EmitterShape
        let rate: Float
        let origin: SIMD3<Float>
        let directions: SIMD3<Float>
        let distanceMin: SIMD3<Float>
        let distanceMax: SIMD3<Float>
        let sign: SIMD3<Float>
        let speedMin: Float
        let speedMax: Float
        let instantaneous: Int
        let duration: Float
        let delay: Float
        let controlPoint: Int
    }

    enum Initializer {
        case lifetime(min: Float, max: Float, exponent: Float)
        case size(min: Float, max: Float, exponent: Float)
        case alpha(min: Float, max: Float, exponent: Float)
        case color(min: SIMD3<Float>, max: SIMD3<Float>, exponent: Float)
        case hsvColor(hue: ClosedRange<Float>, saturation: ClosedRange<Float>, value: ClosedRange<Float>, steps: Int)
        case velocity(min: SIMD3<Float>, max: SIMD3<Float>)
        case rotation(min: SIMD3<Float>, max: SIMD3<Float>)
        case angularVelocity(min: SIMD3<Float>, max: SIMD3<Float>)
        case turbulentVelocity(scale: Float, speedMin: Float, speedMax: Float, offset: Float)
        case mapSequenceAroundControlPoint(
            sequence: ControlPointSequence, speed: (min: SIMD3<Float>, max: SIMD3<Float>)?, controlPoint: Int)
        case mapSequenceBetweenControlPoints(sequence: ControlPointSequence, start: Int, end: Int)
    }

    /// mapsequence* 两个初始化器共用的"序列"：每出生一个粒子往前走一格，
    /// 走完 count 格回到起点（repeat）或原路折回（mirror）；bounds 是圆/线段的起止比例
    /// （WE 文档："Bounds: Describes the start and end point of the circle… a full circle will go from 0.00 to 1.00"）
    struct ControlPointSequence {
        let count: Int
        let bounds: ClosedRange<Float>
        let isMirror: Bool

        /// 第 index 个粒子落在序列上的比例（0–1 → bounds 之间）
        func value(at index: Int) -> Float {
            let count = max(count, 1)
            var phase = Float(index % (isMirror ? count * 2 : count)) / Float(count)
            if isMirror, phase > 1 { phase = 2 - phase }
            let span = bounds.upperBound - bounds.lowerBound
            return bounds.lowerBound + span * phase
        }
    }

    /// remapvalue：把输入值归一化后映射到输出区间，再用 Assign / Multiply / Add / Subtract 作用到某个属性上。
    ///
    /// 输入可以是粒子属性或全局值（`speed` / `lifetime` / `time` / `size` / `alpha` / `rotation` /
    /// `distancetocontrolpoint`）。没写 `input` 时输入来自 transform function（`simplexnoise` / `fbmnoise` /
    /// `sine`，`~/wp` 里雨滴就是这样），这时输入区间也不用写——两处数据刚好互补，印证了这个理解。
    /// 归一化到 0–1、再按输出区间插值，和 WE 文档里"Input range 归一化成 0%–100%，Output range 是新值"一致；
    /// `flags` 的第 0 位是"钳制输入"、第 1 位是"钳制输出"（雨滴里 output=speed、flags=3 的那处两边都钳住）。
    struct RemapValue {
        enum Input: Equatable {
            case speed, lifetime, time, size, alpha, rotation
            case distanceToControlPoint(Int)
        }

        enum Output: String {
            case velocity, speed, color, size, alpha, rotation, position
        }

        /// WE 文档里叫 Assign / Multiply / Add / Subtract；`remap` 是"按输出区间取值后覆盖"
        enum Combine: String {
            case remap, assign, multiply, add, subtract
        }

        enum Transform: String {
            case simplexNoise = "simplexnoise"
            case fbmNoise = "fbmnoise"
            case sine
        }

        let input: Input?
        let inputRangeMin: [Float]
        let inputRangeMax: [Float]
        let output: Output
        let outputRangeMin: [Float]
        let outputRangeMax: [Float]
        let combine: Combine
        let clampInput: Bool
        let clampOutput: Bool
        let transform: Transform?
        let transformScale: Float

        /// 输入值 → 输出区间里的值（按分量）
        func map(_ value: [Float]) -> [Float] {
            let count = max(max(outputRangeMin.count, outputRangeMax.count), 1)
            return (0..<count).map { index in
                let inputLow = Self.component(inputRangeMin, index, fallback: 0)
                let inputHigh = Self.component(inputRangeMax, index, fallback: 1)
                let span = inputHigh - inputLow
                var normalized = span == 0 ? 0 : (Self.component(value, index, fallback: inputLow) - inputLow) / span
                if clampInput { normalized = min(max(normalized, 0), 1) }
                let outputLow = Self.component(outputRangeMin, index, fallback: 0)
                let outputHigh = Self.component(outputRangeMax, index, fallback: 0)
                var mapped = outputLow + (outputHigh - outputLow) * normalized
                if clampOutput { mapped = min(max(mapped, min(outputLow, outputHigh)), max(outputLow, outputHigh)) }
                return mapped
            }
        }

        /// 只有一个分量时所有分量都用它（`outputrangemin` 写一个数的情况）
        static func component(_ values: [Float], _ index: Int, fallback: Float) -> Float {
            if values.count == 1 { return values[0] }
            return index < values.count ? values[index] : fallback
        }
    }

    enum Operator {
        case movement(gravity: SIMD3<Float>, drag: Float)
        case angularMovement(force: SIMD3<Float>, drag: Float)
        case alphaFade(fadeIn: Float, fadeOut: Float)
        case alphaChange(start: Float, end: Float, startValue: Float, endValue: Float)
        case sizeChange(start: Float, end: Float, startValue: Float, endValue: Float)
        /// 颜色随寿命从 startColor 变到 endColor（WE 文档的 "Color change"）
        case colorChange(start: Float, end: Float, startColor: SIMD3<Float>, endColor: SIMD3<Float>)
        case oscillateAlpha(frequency: ClosedRange<Float>, scale: ClosedRange<Float>, phase: ClosedRange<Float>)
        /// 大小来回振荡（WE 文档的 "Oscillate size"）：每个粒子随机取频率、幅度、相位，基准 1.00
        case oscillateSize(frequency: ClosedRange<Float>, scale: ClosedRange<Float>, phase: ClosedRange<Float>)
        /// 涡旋：让粒子绕轴转（WE 文档的 "Vortex"）。半径在 inner/outer 之间按距离插值切向速度
        case vortex(
            axis: SIMD3<Float>, controlPoint: Int, origin: SIMD3<Float>,
            distanceInner: Float, distanceOuter: Float, speedInner: Float, speedOuter: Float)
        case oscillatePosition(
            frequency: ClosedRange<Float>, scale: ClosedRange<Float>, phase: ClosedRange<Float>, mask: SIMD3<Float>)
        case turbulence(
            scale: Float, timeScale: Float, speed: ClosedRange<Float>, phase: ClosedRange<Float>, mask: SIMD3<Float>)
        case controlPointAttract(controlPoint: Int, origin: SIMD3<Float>, scale: Float, threshold: Float)
        case remapValue(RemapValue)
    }

    let maxCount: Int
    let startTime: Float
    let override: ParticleOverride
    let emitters: [Emitter]
    let initializers: [Initializer]
    let operators: [Operator]
    /// 定义里控制点的偏移（系统坐标）和是否跟随鼠标
    let controlPointOffsets: [SIMD3<Float>]
    let controlPointFollowsPointer: [Bool]
    /// ropetrail 画法要记录的历史时长（秒）；0 表示不记录
    let trailLength: Float
    /// 历史按模拟步长采样，所以容量 = 时长 / 步长；上限 64 条，够画长拖尾了
    private var trailCapacity: Int {
        trailLength > 0 ? min(64, Int(saturating: (trailLength / Self.trailStep).rounded(.up)) + 2) : 0
    }
    /// 记录历史时假定的步长（和 ParticleLayer 的模拟步长一致）
    static let trailStep: Float = 1 / 30
    /// 还不支持、模拟时跳过的组件名
    let unsupported: [String]

    private(set) var particles: [Particle] = []
    /// 已模拟的时间（秒，含预模拟）
    private(set) var time: Float = 0
    /// 本步新出生的粒子编号，给 eventfollow 子系统用
    private(set) var bornThisStep: [UInt32] = []
    private var accumulators: [Float]
    private var instantaneousDone: [Bool]
    private var random: ParticleRandom
    private var nextID: UInt32 = 0
    /// 出生计数：mapsequence* 两个初始化器按它决定粒子落在序列的第几格
    private var sequenceIndex = 0
    private let seed: UInt64

    init(
        definition: ParticleDefinition, override: ParticleOverride = ParticleOverride(), seed: UInt64 = 1,
        trailLength: Float = 0
    ) {
        self.override = override
        self.seed = seed
        self.trailLength = max(0, trailLength)
        maxCount = definition.maxCount
        startTime = definition.startTime
        random = ParticleRandom(seed: seed)
        var unsupported: [String] = []

        emitters = definition.emitters.compactMap { component in
            let shape: EmitterShape
            switch component.name {
            case "sphererandom": shape = .sphere
            case "boxrandom": shape = .box
            default:
                unsupported.append("发射器 \(component.name)")
                return nil
            }
            // sphererandom 的距离是一个数（半径），boxrandom 的是向量（半边长）
            return Emitter(
                shape: shape,
                rate: component.float("rate", 5),
                origin: component.vector("origin", .zero),
                directions: component.vector("directions", SIMD3(1, 1, 0)),
                distanceMin: component.vector("distancemin", .zero),
                distanceMax: component.vector("distancemax", SIMD3(256, 256, 0)),
                sign: component.vector("sign", .zero),
                speedMin: component.float("speedmin", 0),
                speedMax: component.float("speedmax", 0),
                instantaneous: Int(component.float("instantaneous", 0)),
                duration: component.float("duration", 0),
                delay: component.float("delay", 0),
                controlPoint: Int(component.float("controlpoint", 0)))
        }

        initializers = definition.initializers.compactMap { c in
            let exponent = c.float("exponent", 1)
            switch c.name {
            case "lifetimerandom": return .lifetime(min: c.float("min", 1), max: c.float("max", 1), exponent: exponent)
            case "sizerandom": return .size(min: c.float("min", 20), max: c.float("max", 20), exponent: exponent)
            case "alpharandom": return .alpha(min: c.float("min", 0), max: c.float("max", 1), exponent: exponent)
            case "colorrandom":
                // 0–255；预览场景 colorrandom 只写 min 的都是 "255 255 255"，所以 max 缺省按白色
                return .color(
                    min: c.vector("min", SIMD3(255, 255, 255)) / 255, max: c.vector("max", SIMD3(255, 255, 255)) / 255,
                    exponent: exponent)
            case "hsvcolorrandom":
                return .hsvColor(
                    hue: Self.range(c.float("huemin", 0), c.float("huemax", 1)),
                    saturation: Self.range(c.float("saturationmin", 1), c.float("saturationmax", 1)),
                    value: Self.range(c.float("valuemin", 1), c.float("valuemax", 1)),
                    steps: Int(c.float("huesteps", 0)))
            case "velocityrandom":
                return .velocity(min: c.vector("min", SIMD3(-32, -32, 0)), max: c.vector("max", SIMD3(32, 32, 0)))
            case "rotationrandom":
                // 弧度（真实文件里出现 6.283）；编辑器加了这个组件却不写字段的很常见，缺省按随机绕 z 转一圈
                return .rotation(min: c.vector("min", .zero), max: c.vector("max", SIMD3(0, 0, 2 * .pi)))
            case "angularvelocityrandom":
                return .angularVelocity(min: c.vector("min", SIMD3(0, 0, -5)), max: c.vector("max", SIMD3(0, 0, 5)))
            case "turbulentvelocityrandom":
                return .turbulentVelocity(
                    scale: c.float("scale", 0.005), speedMin: c.float("speedmin", 100), speedMax: c.float("speedmax", 250),
                    offset: c.float("offset", 0))
            case "mapsequencearoundcontrolpoint":
                // bounds 缺省是整圈（0–1）；speedmin/speedmax 是"出生时的速度"向量，写了就盖掉发射器给的速度
                return .mapSequenceAroundControlPoint(
                    sequence: Self.sequence(c),
                    speed: c.has("speedmin") || c.has("speedmax")
                        ? (min: c.vector("speedmin", .zero), max: c.vector("speedmax", .zero))
                        : nil,
                    controlPoint: Int(c.float("controlpoint", 0)))
            case "mapsequencebetweencontrolpoints":
                return .mapSequenceBetweenControlPoints(
                    sequence: Self.sequence(c),
                    start: Int(c.float("controlpointstart", 0)), end: Int(c.float("controlpointend", 1)))
            default:
                unsupported.append("初始化 \(c.name)")
                return nil
            }
        }

        /// remapvalue 组件 → 算子；认不出来的输出/输入名字记进 unsupported
        func makeRemapValue(_ c: ParticleDefinition.Component) -> RemapValue? {
            guard let name = c.strings["output"]?.lowercased(), let output = RemapValue.Output(rawValue: name) else {
                unsupported.append("remapvalue 的输出 \(c.strings["output"] ?? "?")")
                return nil
            }
            var input: RemapValue.Input?
            if let raw = c.strings["input"]?.lowercased() {
                switch raw {
                case "speed": input = .speed
                case "lifetime", "age": input = .lifetime
                case "time", "runtime": input = .time
                case "size": input = .size
                case "alpha": input = .alpha
                case "rotation": input = .rotation
                case "distancetocontrolpoint":
                    // 控制点编号写在 inputcontrolpoint0 / 1 … 里
                    let slot = (0..<8).first { c.has("inputcontrolpoint\($0)") } ?? 0
                    input = .distanceToControlPoint(Int(c.float("inputcontrolpoint\(slot)", 0)))
                default:
                    unsupported.append("remapvalue 的输入 \(raw)")
                    return nil
                }
            }
            let transform = c.strings["transformfunction"].flatMap { RemapValue.Transform(rawValue: $0.lowercased()) }
            if input != nil, transform != nil {
                // 两处真实数据都是二选一，同时写时按 input 处理
                unsupported.append("remapvalue 同时写了 input 和 transformfunction（按 input 处理）")
            }
            let flags = Int(c.float("flags", 0))
            return RemapValue(
                input: input,
                inputRangeMin: c.numbers["inputrangemin"] ?? [0],
                inputRangeMax: c.numbers["inputrangemax"] ?? [1],
                output: output,
                outputRangeMin: c.numbers["outputrangemin"] ?? [0],
                outputRangeMax: c.numbers["outputrangemax"] ?? [0],
                combine: RemapValue.Combine(rawValue: (c.strings["operation"] ?? "remap").lowercased()) ?? .remap,
                clampInput: flags & 1 != 0,
                clampOutput: flags & 2 != 0,
                transform: transform,
                transformScale: c.float("transforminputscale", 1))
        }

        operators = definition.operators.compactMap { c in
            switch c.name {
            case "movement":
                return .movement(gravity: c.vector("gravity", .zero), drag: c.float("drag", 0))
            case "angularmovement":
                return .angularMovement(force: c.vector("force", .zero), drag: c.float("drag", 0))
            case "alphafade":
                return .alphaFade(fadeIn: c.float("fadeintime", 0.5), fadeOut: c.float("fadeouttime", 0.5))
            case "alphachange":
                return .alphaChange(
                    start: c.float("starttime", 0), end: c.float("endtime", 1),
                    startValue: c.float("startvalue", 1), endValue: c.float("endvalue", 0))
            case "sizechange":
                return .sizeChange(
                    start: c.float("starttime", 0), end: c.float("endtime", 1),
                    startValue: c.float("startvalue", 1), endValue: c.float("endvalue", 0))
            case "colorchange":
                // 字段名和 alpha/size change 一样，只是 start/endvalue 是颜色
                return .colorChange(
                    start: c.float("starttime", 0), end: c.float("endtime", 1),
                    startColor: c.vector("startvalue", SIMD3(1, 1, 1)),
                    endColor: c.vector("endvalue", SIMD3(1, 1, 1)))
            case "oscillatealpha":
                return .oscillateAlpha(
                    frequency: Self.range(c.float("frequencymin", 0), c.float("frequencymax", 5)),
                    scale: Self.range(c.float("scalemin", 0), c.float("scalemax", 1)),
                    phase: Self.range(c.float("phasemin", 0), c.float("phasemax", 2 * .pi)))
            case "oscillatesize":
                // 和 oscillatealpha 同样的参数，只是作用在大小上（基准 1.00 = 不改变）
                return .oscillateSize(
                    frequency: Self.range(c.float("frequencymin", 0), c.float("frequencymax", 5)),
                    scale: Self.range(c.float("scalemin", 1), c.float("scalemax", 1)),
                    phase: Self.range(c.float("phasemin", 0), c.float("phasemax", 2 * .pi)))
            case "vortex":
                return .vortex(
                    axis: c.vector("axis", SIMD3(0, 0, 1)),
                    controlPoint: Int(c.float("controlpoint", 0)),
                    origin: c.vector("origin", .zero),
                    distanceInner: c.float("distanceinner", 0),
                    distanceOuter: c.float("distanceouter", 100),
                    speedInner: c.float("speedinner", 0),
                    speedOuter: c.float("speedouter", 100))
            case "oscillateposition":
                return .oscillatePosition(
                    frequency: Self.range(c.float("frequencymin", 0), c.float("frequencymax", 5)),
                    scale: Self.range(c.float("scalemin", 0), c.float("scalemax", 1)),
                    phase: Self.range(c.float("phasemin", 0), c.float("phasemax", 2 * .pi)),
                    mask: c.vector("mask", SIMD3(1, 1, 0)))
            case "turbulence":
                return .turbulence(
                    scale: c.float("scale", 0.005), timeScale: c.float("timescale", 1),
                    speed: Self.range(c.float("speedmin", 100), c.float("speedmax", 250)),
                    phase: Self.range(c.float("phasemin", 0), c.float("phasemax", 0.1)),
                    mask: c.vector("mask", SIMD3(1, 1, 0)))
            case "controlpointattract":
                return .controlPointAttract(
                    controlPoint: Int(c.float("controlpoint", 0)), origin: c.vector("origin", .zero),
                    scale: c.float("scale", 100), threshold: c.float("threshold", 100))
            case "remapvalue":
                guard let remap = makeRemapValue(c) else { return nil }
                return .remapValue(remap)
            default:
                unsupported.append("算子 \(c.name)")
                return nil
            }
        }

        var offsets = [SIMD3<Float>](repeating: .zero, count: 8)
        var follows = [Bool](repeating: false, count: 8)
        for point in definition.controlPoints where (0..<8).contains(point.id) {
            offsets[point.id] = point.offset
            follows[point.id] = point.followsPointer
        }
        controlPointOffsets = offsets
        controlPointFollowsPointer = follows
        self.unsupported = unsupported
        accumulators = Array(repeating: 0, count: emitters.count)
        instantaneousDone = Array(repeating: false, count: emitters.count)
    }

    private static func range(_ a: Float, _ b: Float) -> ClosedRange<Float> { min(a, b)...max(a, b) }

    /// mapsequence* 的公共字段：count（几个出生点）、bounds（起点和终点，整圈是 0–1）、
    /// limitbehavior（repeat 绕圈 / mirror 折返）
    private static func sequence(_ c: ParticleDefinition.Component) -> ControlPointSequence {
        let bounds = c.vector("bounds", SIMD3(0, 1, 0))
        return ControlPointSequence(
            count: Int(c.float("count", 1)), bounds: range(bounds.x, bounds.y),
            isMirror: (c.strings["limitbehavior"] ?? "").lowercased() == "mirror")
    }

    /// 回到初始状态（时间倒退时用）
    func reset() {
        particles.removeAll(keepingCapacity: true)
        time = 0
        nextID = 0
        sequenceIndex = 0
        random = ParticleRandom(seed: seed)
        accumulators = Array(repeating: 0, count: emitters.count)
        instantaneousDone = Array(repeating: false, count: emitters.count)
        bornThisStep = []
    }

    /// 前进一步。
    /// - Parameters:
    ///   - controlPoints: 8 个控制点在系统坐标里的当前位置
    ///   - anchors: eventfollow 子系统才有：父粒子编号 → 父粒子位置；新出生的父粒子在 `newAnchors` 里
    ///   - emitsContinuously: eventfollow 子系统只在父粒子出生时发射，不按发射率持续发射
    func step(
        _ dt: Float, controlPoints: [SIMD3<Float>], anchors: [UInt32: SIMD3<Float>]? = nil, newAnchors: [UInt32] = []
    ) {
        guard dt > 0 else { return }
        bornThisStep.removeAll(keepingCapacity: true)
        let speedFactor = override.speed

        // 1. 更新已有粒子。数组先挪到局部变量里再改：类的属性每访问一次元素都要做一次运行时的独占检查
        //（5 万个粒子时占了模拟时间的一成多），局部变量没有。挪走以后原来的属性不再引用它，改的时候不会复制
        var alive = particles
        particles = []
        var index = 0
        while index < alive.count {
            alive[index].age += dt
            let dead = alive[index].age >= alive[index].lifetime
                || (alive[index].anchor.map { anchors?[$0] == nil } ?? false)
            if dead {
                alive.swapAt(index, alive.count - 1)
                alive.removeLast()
                continue
            }
            apply(to: &alive[index], dt: dt, speedFactor: speedFactor, controlPoints: controlPoints, anchors: anchors)
            recordTrail(&alive[index], anchors: anchors)
            index += 1
        }
        particles = alive

        // 2. 发射
        if let anchors {
            for anchor in newAnchors {
                guard let base = anchors[anchor] else { continue }
                for (emitterIndex, emitter) in emitters.enumerated() where emitter.instantaneous > 0 {
                    for _ in 0..<emitter.instantaneous {
                        spawn(emitterIndex, around: base, anchor: anchor, controlPoints: controlPoints)
                    }
                }
            }
        } else {
            for (emitterIndex, emitter) in emitters.enumerated() {
                let active = time + dt >= emitter.delay && (emitter.duration <= 0 || time < emitter.delay + emitter.duration)
                guard active else { continue }
                let center = controlPoints[min(max(emitter.controlPoint, 0), 7)]
                if !instantaneousDone[emitterIndex] {
                    instantaneousDone[emitterIndex] = true
                    for _ in 0..<emitter.instantaneous {
                        spawn(emitterIndex, around: center, anchor: nil, controlPoints: controlPoints)
                    }
                }
                accumulators[emitterIndex] += emitter.rate * override.count * dt
                while accumulators[emitterIndex] >= 1 {
                    accumulators[emitterIndex] -= 1
                    guard particles.count < maxCount else {
                        accumulators[emitterIndex] = min(accumulators[emitterIndex], 1)
                        break
                    }
                    spawn(emitterIndex, around: center, anchor: nil, controlPoints: controlPoints)
                }
            }
        }
        time += dt
    }

    private func spawn(
        _ emitterIndex: Int, around center: SIMD3<Float>, anchor: UInt32?, controlPoints: [SIMD3<Float>]
    ) {
        guard particles.count < maxCount else { return }
        let emitter = emitters[emitterIndex]
        var offset: SIMD3<Float>
        var direction: SIMD3<Float>
        switch emitter.shape {
        case .sphere:
            direction = random.direction() * emitter.directions
            let distance = random.range(emitter.distanceMin.x, emitter.distanceMax.x)
            offset = direction * distance
        case .box:
            let unit = SIMD3(random.range(-1, 1), random.range(-1, 1), random.range(-1, 1))
            offset = unit * emitter.distanceMax * emitter.directions.replacing(with: 1, where: emitter.directions .== 0)
            direction = simd_length(unit) > 0 ? simd_normalize(unit) : .zero
        }
        for axis in 0..<3 where emitter.sign[axis] != 0 {
            offset[axis] = abs(offset[axis]) * (emitter.sign[axis] > 0 ? 1 : -1)
            direction[axis] = abs(direction[axis]) * (emitter.sign[axis] > 0 ? 1 : -1)
        }
        let speed = random.range(emitter.speedMin, emitter.speedMax)
        let heading = simd_length(direction) > 0 ? simd_normalize(direction) : .zero

        // eventfollow 子系统的粒子位置相对于父粒子
        let base = anchor == nil ? center : .zero
        var particle = Particle(
            id: nextID, position: base + emitter.origin + offset, velocity: heading * speed * override.speed)
        nextID &+= 1
        particle.anchor = anchor
        particle.frameSeed = random.unit()
        let spawnIndex = sequenceIndex
        sequenceIndex += 1
        for initializer in initializers {
            initialize(
                &particle, initializer, absolute: center + emitter.origin + offset, index: spawnIndex,
                controlPoints: controlPoints)
        }
        particle.lifetime *= override.lifetime
        particle.size *= override.size
        particle.alpha *= override.alpha
        if let tint = override.color { particle.color *= tint }
        particle.drawnAlpha = particle.alpha
        particle.drawnSize = particle.size
        if trailLength > 0 {
            particle.trail = TrailHistory(capacity: trailCapacity)
            particle.trail.append(
                TrailSample(
                    age: 0, position: particle.position + particle.drawnOffset, alpha: particle.alpha,
                    size: particle.size))
        }
        particles.append(particle)
        bornThisStep.append(particle.id)
    }

    /// 记录 ropetrail 画法要用的历史：位置取"最终画出来的系统坐标"（含算子的偏移和跟随的父粒子）
    private func recordTrail(_ particle: inout Particle, anchors: [UInt32: SIMD3<Float>]?) {
        guard trailLength > 0 else { return }
        guard !particle.trail.isEmpty else {
            particle.trail = TrailHistory(capacity: trailCapacity)
            return
        }
        var position = particle.position + particle.drawnOffset
        if let anchor = particle.anchor, let base = anchors?[anchor] { position += base }
        particle.trail.append(
            TrailSample(age: particle.age, position: position, alpha: particle.drawnAlpha, size: particle.drawnSize))
        particle.trail.drop(olderThan: particle.age - trailLength)
    }

    private func initialize(
        _ particle: inout Particle, _ initializer: Initializer, absolute: SIMD3<Float>, index: Int,
        controlPoints: [SIMD3<Float>]
    ) {
        switch initializer {
        case .lifetime(let min, let max, let exponent):
            particle.lifetime = random.range(min, max, exponent: exponent)
        case .size(let min, let max, let exponent):
            particle.size = random.range(min, max, exponent: exponent)
        case .alpha(let min, let max, let exponent):
            particle.alpha = random.range(min, max, exponent: exponent)
        case .color(let min, let max, let exponent):
            // 在两个颜色之间取一点（同一个比例），而不是三个通道各自随机
            particle.color = simd_mix(min, max, SIMD3(repeating: random.range(0, 1, exponent: exponent)))
        case .hsvColor(let hue, let saturation, let value, let steps):
            var h = random.range(hue.lowerBound, hue.upperBound)
            if steps > 1 {
                let step = (random.range(0, Float(steps)) ).rounded(.down)
                h = hue.lowerBound + (hue.upperBound - hue.lowerBound) * min(step, Float(steps - 1)) / Float(steps - 1)
            }
            particle.color = Self.hsvToRGB(
                h, random.range(saturation.lowerBound, saturation.upperBound),
                random.range(value.lowerBound, value.upperBound))
        case .velocity(let min, let max):
            particle.velocity += random.vector(min, max) * override.speed
        case .rotation(let min, let max):
            particle.rotation = random.vector(min, max)
        case .angularVelocity(let min, let max):
            particle.angularVelocity = random.vector(min, max)
        case .turbulentVelocity(let scale, let speedMin, let speedMax, let offset):
            let field = ParticleNoise.vector(absolute * scale + SIMD3(repeating: offset))
            var planar = SIMD3(field.x, field.y, 0)
            if simd_length(planar) < 1e-4 { planar = SIMD3(1, 0, 0) }
            particle.velocity += simd_normalize(planar) * random.range(speedMin, speedMax) * override.speed
        case .mapSequenceAroundControlPoint(let sequence, let speed, let controlPoint):
            // "Will generate the particles in a circle around a control point"：到控制点的距离保留
            // （半径还是发射器给的），只把角度摆到序列的第 index 格上
            let point = controlPoints[min(max(controlPoint, 0), controlPoints.count - 1)]
            let radial = particle.position - point
            let radius = simd_length(SIMD2(radial.x, radial.y))
            let angle = sequence.value(at: index) * 2 * Float.pi
            particle.position = point + SIMD3(cos(angle) * radius, sin(angle) * radius, radial.z)
            if let speed {
                particle.velocity = speed.min + (speed.max - speed.min) * SIMD3(
                    random.unit(), random.unit(), random.unit()) * override.speed
            }
        case .mapSequenceBetweenControlPoints(let sequence, let start, let end):
            // "Will generate the particles between two control points"：位置插值到两点之间的序列上
            let first = controlPoints[min(max(start, 0), controlPoints.count - 1)]
            let last = controlPoints[min(max(end, 0), controlPoints.count - 1)]
            particle.position = first + (last - first) * sequence.value(at: index)
        }
    }

    private func apply(
        to particle: inout Particle, dt: Float, speedFactor: Float, controlPoints: [SIMD3<Float>],
        anchors: [UInt32: SIMD3<Float>]?
    ) {
        let life = particle.life
        var alpha = particle.alpha
        var size = particle.size
        var offset = SIMD3<Float>.zero
        for (index, op) in operators.enumerated() {
            let salt = UInt32(index) &* 16
            switch op {
            case .movement(let gravity, let drag):
                particle.velocity += gravity * speedFactor * dt
                if drag != 0 { particle.velocity *= exp(-drag * dt) }
                particle.position += particle.velocity * dt
            case .angularMovement(let force, let drag):
                particle.angularVelocity += force * speedFactor * dt
                if drag != 0 { particle.angularVelocity *= exp(-drag * dt) }
                particle.rotation += particle.angularVelocity * dt
            case .alphaFade(let fadeIn, let fadeOut):
                if fadeIn > 0, life < fadeIn { alpha *= life / fadeIn }
                if life > fadeOut { alpha *= fadeOut < 1 ? max(0, (1 - life) / (1 - fadeOut)) : 0 }
            case .alphaChange(let start, let end, let startValue, let endValue):
                alpha *= Self.change(life, start, end, startValue, endValue)
            case .sizeChange(let start, let end, let startValue, let endValue):
                size *= Self.change(life, start, end, startValue, endValue)
            case .colorChange(let start, let end, let startColor, let endColor):
                let mix = Self.change(life, start, end, 0, 1)
                particle.color = startColor + (endColor - startColor) * mix
            case .oscillateAlpha(let frequency, let scale, let phase):
                let f = Self.pick(frequency, particle.id, salt)
                let p = Self.pick(phase, particle.id, salt + 1)
                let wave = 0.5 + 0.5 * sin(2 * .pi * f * life + p)
                alpha *= scale.lowerBound + (scale.upperBound - scale.lowerBound) * wave
            case .oscillateSize(let frequency, let scale, let phase):
                let f = Self.pick(frequency, particle.id, salt)
                let p = Self.pick(phase, particle.id, salt + 1)
                let wave = 0.5 + 0.5 * sin(2 * .pi * f * life + p)
                size *= scale.lowerBound + (scale.upperBound - scale.lowerBound) * wave
            case .vortex(let axis, let controlPoint, let origin, let inner, let outer, let speedInner, let speedOuter):
                let target = controlPoints[min(max(controlPoint, 0), 7)] + origin
                var position = particle.position
                if let anchor = particle.anchor, let base = anchors?[anchor] { position += base }
                let offset = position - target
                let along = simd_dot(offset, axis)
                let radial = offset - axis * along
                let distance = simd_length(radial)
                guard distance > 1e-3 else { break }
                let speed: Float
                if distance <= inner {
                    speed = speedInner
                } else if distance >= outer {
                    speed = speedOuter
                } else {
                    let ratio = (distance - inner) / max(outer - inner, 1e-3)
                    speed = speedInner + (speedOuter - speedInner) * ratio
                }
                // 切向 = 轴 × 半径方向；速度沿切向加，配合 movement 的阻力就转起来了
                particle.velocity += simd_normalize(simd_cross(axis, radial)) * speed * speedFactor * dt
            case .oscillatePosition(let frequency, let scale, let phase, let mask):
                // 各轴相位不同，避免只沿对角线来回
                let f = Self.pick(frequency, particle.id, salt)
                let amplitude = Self.pick(scale, particle.id, salt + 1)
                let px = Self.pick(phase, particle.id, salt + 2)
                let py = Self.pick(phase, particle.id, salt + 3) + .pi / 2
                let angle = 2 * .pi * f * life
                offset += mask * amplitude * SIMD3(sin(angle + px), sin(angle + py), sin(angle + px + py))
            case .turbulence(let scale, let timeScale, let speed, let phase, let mask):
                let p = Self.pick(phase, particle.id, salt)
                let sample = particle.position * scale + SIMD3(repeating: time * timeScale * 0.1 + p)
                let force = ParticleNoise.vector(sample) * mask * Self.pick(speed, particle.id, salt + 1)
                particle.velocity += force * speedFactor * dt
            case .controlPointAttract(let controlPoint, let origin, let scale, let threshold):
                let target = controlPoints[min(max(controlPoint, 0), 7)] + origin
                var position = particle.position
                if let anchor = particle.anchor, let base = anchors?[anchor] { position += base }
                let delta = target - position
                let distance = simd_length(delta)
                if distance > 1e-3, distance < threshold {
                    particle.velocity += delta / distance * scale * speedFactor * dt
                }
            case .remapValue(let remap):
                applyRemap(
                    remap, to: &particle, size: &size, alpha: &alpha, offset: offset,
                    controlPoints: controlPoints, anchors: anchors)
            }
        }
        particle.drawnAlpha = max(0, alpha)
        particle.drawnSize = max(0, size)
        particle.drawnOffset = offset
    }

    // MARK: - remapvalue

    /// 一个粒子的 remapvalue：取输入值 → 归一化 → 映射到输出区间 → 作用到输出属性
    private func applyRemap(
        _ remap: RemapValue, to particle: inout Particle, size: inout Float, alpha: inout Float,
        offset: SIMD3<Float>,
        controlPoints: [SIMD3<Float>], anchors: [UInt32: SIMD3<Float>]?
    ) {
        guard let input = remapInput(
            remap, particle: particle, size: size, alpha: alpha, offset: offset, controlPoints: controlPoints,
            anchors: anchors)
        else { return }
        let mapped = remap.map(input)
        let vector = SIMD3(
            RemapValue.component(mapped, 0, fallback: 0), RemapValue.component(mapped, 1, fallback: 0),
            RemapValue.component(mapped, 2, fallback: 0))
        switch remap.output {
        case .velocity:
            particle.velocity = Self.combine(remap.combine, particle.velocity, vector)
        case .speed:
            // speed 是速度的模：改它的时候方向不变
            let speed = simd_length(particle.velocity)
            let updated = max(Self.combine(remap.combine, speed, mapped[0]), 0)
            if speed > 1e-4 { particle.velocity *= updated / speed }
        case .color:
            particle.color = Self.combine(remap.combine, particle.color, vector)
        case .size:
            // 和其它算子一样改本帧的绘制值，下一帧起才是粒子自己的属性
            size = max(Self.combine(remap.combine, size, mapped[0]), 0)
        case .alpha:
            alpha = min(max(Self.combine(remap.combine, alpha, mapped[0]), 0), 1)
        case .rotation:
            particle.rotation.z = Self.combine(remap.combine, particle.rotation.z, mapped[0])
        case .position:
            particle.position = Self.combine(remap.combine, particle.position, vector)
        }
    }

    /// 输入值（标量只给一个分量）。没写 input 时由 transform function 生成 0–1 的噪声/波形
    private func remapInput(
        _ remap: RemapValue, particle: Particle, size: Float, alpha: Float, offset: SIMD3<Float>,
        controlPoints: [SIMD3<Float>], anchors: [UInt32: SIMD3<Float>]?
    ) -> [Float]? {
        if let input = remap.input {
            switch input {
            case .speed: return [simd_length(particle.velocity)]
            case .lifetime: return [particle.life]
            case .time: return [time]
            case .size: return [size]
            case .alpha: return [alpha]
            case .rotation: return [particle.rotation.z]
            case .distanceToControlPoint(let index):
                var position = particle.position + offset
                if let anchor = particle.anchor, let base = anchors?[anchor] { position += base }
                let target = controlPoints[min(max(index, 0), 7)]
                return [simd_length(target - position)]
            }
        }
        guard let transform = remap.transform else { return nil }
        // 噪声场按粒子的位置取样（`transforminputscale` 越大越细），再加一点时间让场缓慢变化
        let sample = particle.position * max(remap.transformScale, 0.0001) + SIMD3(repeating: time * 0.1)
        let value: Float
        switch transform {
        case .sine:
            value = 0.5 + 0.5 * sin(sample.x + sample.y)
        case .simplexNoise:
            value = 0.5 + 0.5 * ParticleNoise.value(sample, 0)
        case .fbmNoise:
            var sum: Float = 0
            var amplitude: Float = 0.5
            var frequency: Float = 1
            for octave in 0..<3 {
                sum += amplitude * ParticleNoise.value(sample * frequency, UInt32(octave))
                frequency *= 2
                amplitude *= 0.5
            }
            value = 0.5 + 0.5 * sum
        }
        return [min(max(value, 0), 1)]
    }

    private static func combine(_ operation: RemapValue.Combine, _ current: Float, _ mapped: Float) -> Float {
        switch operation {
        case .remap, .assign: return mapped
        case .multiply: return current * mapped
        case .add: return current + mapped
        case .subtract: return current - mapped
        }
    }

    private static func combine(
        _ operation: RemapValue.Combine, _ current: SIMD3<Float>, _ mapped: SIMD3<Float>
    ) -> SIMD3<Float> {
        switch operation {
        case .remap, .assign: return mapped
        case .multiply: return current * mapped
        case .add: return current + mapped
        case .subtract: return current - mapped
        }
    }

    /// 在 start 之前是 startValue，end 时到 endValue，中间线性过渡
    private static func change(_ life: Float, _ start: Float, _ end: Float, _ startValue: Float, _ endValue: Float) -> Float {
        if life <= start { return startValue }
        if life >= end || end <= start { return endValue }
        return startValue + (endValue - startValue) * (life - start) / (end - start)
    }

    /// 每个粒子固定的随机值：由编号和组件决定，不用存在粒子里
    private static func pick(_ range: ClosedRange<Float>, _ id: UInt32, _ salt: UInt32) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * ParticleRandom.hash(id, salt)
    }

    static func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let hue = (h - h.rounded(.down)) * 6
        let k = SIMD3<Float>(5, 3, 1) + SIMD3(repeating: hue)
        let wrapped = SIMD3(k.x.truncatingRemainder(dividingBy: 6), k.y.truncatingRemainder(dividingBy: 6),
                            k.z.truncatingRemainder(dividingBy: 6))
        let t = simd_clamp(simd_min(wrapped, SIMD3(repeating: 4) - wrapped), SIMD3(repeating: 0), SIMD3(repeating: 1))
        return SIMD3(repeating: v) - v * s * t
    }
}

/// 可复现的随机数（SplitMix64）。同一个种子得到同样的粒子，方便测试和对比截图
struct ParticleRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.mix(state)
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }

    /// exponent 大于 1 时偏向 min，小于 1 时偏向 max（WE 文档对 exponent 的说明）
    mutating func range(_ a: Float, _ b: Float, exponent: Float = 1) -> Float {
        let u = exponent == 1 ? unit() : pow(unit(), max(exponent, 0.0001))
        return a + (b - a) * u
    }

    mutating func vector(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(range(a.x, b.x), range(a.y, b.y), range(a.z, b.z))
    }

    /// 单位球面上均匀分布的方向
    mutating func direction() -> SIMD3<Float> {
        let z = range(-1, 1)
        let angle = range(0, 2 * .pi)
        let r = (1 - z * z).squareRoot()
        return SIMD3(r * cos(angle), r * sin(angle), z)
    }

    /// 由两个整数决定的 [0, 1) 随机值
    static func hash(_ id: UInt32, _ salt: UInt32) -> Float {
        Float(mix(UInt64(id) << 32 | UInt64(salt)) >> 40) / Float(1 << 24)
    }
}

/// 平滑的三维噪声（值噪声，三线性插值），湍流用。输出每个分量在 -1…1
enum ParticleNoise {
    static func vector(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(value(p, 0), value(p + SIMD3(31.4, 17.9, 5.3), 1), value(p + SIMD3(-11.7, 43.1, 23.9), 2))
    }

    static func value(_ p: SIMD3<Float>, _ channel: UInt32) -> Float {
        let cell = p.rounded(.down)
        let f = p - cell
        let u = f * f * (SIMD3(repeating: 3) - 2 * f)
        // 坏的粒子参数（NaN、极大的重力）会让位置变成 NaN / 无穷大，这里不能崩
        let cx = Int32(truncatingIfNeeded: Int(saturating: cell.x))
        let cy = Int32(truncatingIfNeeded: Int(saturating: cell.y))
        let cz = Int32(truncatingIfNeeded: Int(saturating: cell.z))
        func corner(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float {
            let x = UInt32(bitPattern: cx &+ dx)
            let y = UInt32(bitPattern: cy &+ dy)
            let z = UInt32(bitPattern: cz &+ dz)
            let key = x &* 73_856_093 ^ y &* 19_349_663 ^ z &* 83_492_791
            return ParticleRandom.hash(key, channel) * 2 - 1
        }
        // 8 个角各算一次（原来 (0,0,0) 这类角每个算两遍，一共 12 次哈希）
        let c000 = corner(0, 0, 0), c100 = corner(1, 0, 0), c010 = corner(0, 1, 0), c110 = corner(1, 1, 0)
        let c001 = corner(0, 0, 1), c101 = corner(1, 0, 1), c011 = corner(0, 1, 1), c111 = corner(1, 1, 1)
        let x00 = c000 + (c100 - c000) * u.x
        let x10 = c010 + (c110 - c010) * u.x
        let x01 = c001 + (c101 - c001) * u.x
        let x11 = c011 + (c111 - c011) * u.x
        let y0 = x00 + (x10 - x00) * u.y
        let y1 = x01 + (x11 - x01) * u.y
        return y0 + (y1 - y0) * u.z
    }
}
