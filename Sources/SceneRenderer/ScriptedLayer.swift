import Foundation
import simd
import WallpaperFormats

/// 图层上"由脚本驱动"的字段（origin / scale / alpha / color / visible…）。
///
/// 构建时先算一遍，把结果当静态值用；脚本里出现时间或随机数（engine.runtime、engine.frametime、
/// Math.random、Date）时还要每帧重算——`~/wp` 里吊瓶的上下浮动就是这种。每次求值都把当前的
/// origin / scale 和已运行秒数喂回脚本，和 WE 一样。
///
/// 跑不了的脚本（框架类、超时、抛异常）保持静态值，并记进 problems。还没处理的组合：
/// 脚本移动的父图层带不动子图层（`~/wp` 里没有这种）；粒子系统和合成层不跟着脚本动。
final class ScriptedLayer {
    private let state: SceneState
    private let objectID: Int

    /// 当前值都在运行时状态里（`SceneState`）——场景对象接口改的也是同一份
    var world: simd_float4x4 { state.world(objectID) }
    var drawColor: SIMD4<Float> { state.color(objectID) }
    var isVisible: Bool { state.isVisible(objectID) }

    private let originScript: SceneScript?
    private let scaleScript: SceneScript?
    private let alphaScript: SceneScript?
    private let colorScript: SceneScript?
    private let visibleScript: SceneScript?
    /// 有脚本要每帧重算
    let isDynamic: Bool
    /// 脚本注册了鼠标回调（拖动、悬浮缩放这类）
    let handlesPointer: Bool
    private var pointerInside = false
    private var lastPointer: SIMD2<Float>?
    /// 跑不了的字段 → 原因
    private(set) var problems: [String] = []
    private var reported = Set<String>()

    init?(
        object: SceneDescription.Object, canvasSize: SIMD2<Float>, state: SceneState, userProperties: Data? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        guard !object.fieldScripts.isEmpty else { return nil }
        self.state = state
        objectID = object.id
        let environment = SceneScript.Environment(
            canvasSize: canvasSize, layerOrigin: object.origin, layerScale: object.scale,
            layerSize: object.size ?? SIMD2(1, 1), layerName: object.name, userProperties: userProperties,
            graph: state, ownerID: object.id)
        var refused: [String] = []
        func make(_ field: String) -> SceneScript? {
            guard let script = object.fieldScripts[field] else { return nil }
            guard let made = SceneScript(
                source: script.source, properties: script.properties, environment: environment, now: now)
            else {
                refused.append("\(field) 上的脚本没有运行（宿主不可用），按静态值处理")
                return nil
            }
            // 宿主能建起来、但脚本本身载入不了（用了没提供的接口、或者被安全检查拦下）：
            // 原因带上，行为还是按静态值处理
            if let problem = made.problem {
                refused.append("\(field) 上的脚本按静态值处理：\(problem)")
                return nil
            }
            return made
        }
        originScript = make("origin")
        scaleScript = make("scale")
        alphaScript = make("alpha")
        colorScript = make("color")
        visibleScript = make("visible")
        problems = refused.sorted()

        // 时间相关的字段每帧重算；其它只在构建时算一次（没有输入事件时结果不会变）。
        // 例外：**注册了音频频谱**（`engine.registerAudioBuffers`）的脚本必须每帧重算——音频本身就是
        // 每帧变化的输入，而脚本自己不一定提到时间。可视化条的脚本就是这样：只用 `audioData.average[i]`
        // 算柱子的高度，一个字的时间/随机都没有；以前被当成静态脚本只跑一次，柱子高度就永远停在 0，
        // 画面上根本看不到音乐可视化
        let audioDriven = [originScript, scaleScript, alphaScript, colorScript, visibleScript]
            .compactMap { $0 }.contains { $0.wantsAudio }
        let fields = ["origin", "scale", "alpha", "color", "visible"]
        isDynamic = audioDriven || fields.contains { field in
            guard let script = object.fieldScripts[field] else { return false }
            return Self.isTimeDependent(script.source)
        }
        let handlers = [
            "cursorEnter", "cursorLeave", "cursorMove", "cursorDown", "cursorUp", "cursorClick", "cursorDrag",
        ]
        handlesPointer = [originScript, scaleScript, alphaScript, colorScript, visibleScript]
            .compactMap { $0 }
            .contains { script in handlers.contains { script.hasHandler($0) } }
        apply(runtime: 0, frameTime: 1 / 30)
    }

    private var scripts: [SceneScript] {
        [originScript, scaleScript, alphaScript, colorScript, visibleScript].compactMap { $0 }
    }

    /// 鼠标在画布坐标里动了：进出图层时补上 cursorEnter / cursorLeave，在里面时给 cursorMove。
    /// 桌面窗口本来就忽略鼠标事件，所以这里用的是全局鼠标位置（SceneContent 每帧更新）。
    func pointerMoved(inside: Bool, position: SIMD2<Float>) {
        guard handlesPointer else { return }
        if inside != pointerInside {
            pointerInside = inside
            for script in scripts {
                script.callHandler(inside ? "cursorEnter" : "cursorLeave", worldPosition: position)
            }
        }
        guard inside, lastPointer != position else { return }
        lastPointer = position
        for script in scripts { script.callHandler("cursorMove", worldPosition: position) }
    }

    /// 点击/拖动事件（画布坐标）：直接送到图层上的脚本
    func pointerEvent(_ handler: String, position: SIMD2<Float>) {
        guard handlesPointer else { return }
        // 记下位置，免得紧接着的悬停更新再发一次 cursorMove
        lastPointer = position
        for script in scripts { script.callHandler(handler, worldPosition: position) }
        for script in scripts {
            guard let problem = script.problem, reported.insert(problem).inserted else { continue }
            problems.append(problem)
        }
    }

    /// 有脚本注册了音频频谱（`engine.registerAudioBuffers`）
    var usesAudio: Bool { scripts.contains { $0.wantsAudio } }

    /// 把系统音频的频谱推给图层上注册过 AudioBuffers 的脚本（每帧一次）
    func refreshAudio(_ bands: (left: [Float], right: [Float])) {
        for script in scripts { script.refreshAudio(bands) }
    }

    /// 每帧重算一次（只有时间相关的脚本会重算）
    func evaluate(at runtime: Float, frameTime: Float) {
        guard isDynamic else { return }
        apply(runtime: runtime, frameTime: frameTime)
    }

    private func apply(runtime: Float, frameTime: Float) {
        func refresh(_ script: SceneScript) {
            script.setRuntime(
                runtime, frameTime: frameTime, layerOrigin: state.layerOrigin(objectID),
                layerScale: state.layerScale(objectID))
        }
        // 脚本没给这个属性返回值时保持原值——对 WE 来说是正常写法（幻灯片控制器只改别的图层），
        // 所以不算"算不出"；真正跑不了的（拒绝、抛异常）在下面的 problems 里记
        if let script = originScript {
            refresh(script)
            if let value = script.updateVector(state.layerOrigin(objectID)) {
                state.setLayerOrigin(objectID, value)
            }
        }
        if let script = scaleScript {
            refresh(script)
            if let value = script.updateVector(state.layerScale(objectID)) {
                state.setLayerScale(objectID, value)
            }
        }
        if let script = alphaScript {
            refresh(script)
            if let value = script.updateNumber(Float(state.layerAlpha(objectID))) {
                state.setLayerAlpha(objectID, Double(value))
            }
        }
        if let script = colorScript {
            refresh(script)
            if let value = script.updateVector(state.layerColor(objectID)) {
                state.setLayerColor(objectID, value)
            }
        }
        if let script = visibleScript {
            refresh(script)
            if let value = script.updateBool(state.layerVisible(objectID)) {
                state.setLayerVisible(objectID, value)
            }
        }
        for script in [originScript, scaleScript, alphaScript, colorScript, visibleScript].compactMap({ $0 }) {
            guard let problem = script.problem, reported.insert(problem).inserted else { continue }
            problems.append(problem)
        }
    }

    /// 脚本自己会随时间或随机数变化：这类才需要每帧重算
    static func isTimeDependent(_ source: String) -> Bool {
        source.range(
            of: #"engine\s*\.\s*(runtime|frametime)|\bMath\s*\.\s*random\b|\bDate\b"#,
            options: .regularExpression) != nil
    }

}
