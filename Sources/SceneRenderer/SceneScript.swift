import Foundation
import JavaScriptCore
import simd
import WallpaperFormats

/// 属性脚本 / 文字脚本的最小 SceneScript 宿主。
///
/// WE 的每个属性都可以挂脚本：文字层用它算时钟，图层用它算位置（吊瓶上下浮动）、按下悬浮时的缩放，
/// 场景里还有用它控制显隐的。`~/wp` 里这些脚本用到的运行环境只有 `createScriptProperties`、
/// `new Date()`、`engine`（canvasSize / runtime / frametime / userProperties）、`thisLayer`
/// （origin / scale / size / text）和向量运算，所以这里用 JavaScriptCore 给一个刚好够用的宿主。
///
/// 脚本来自下载来的壁纸，是不可信代码：
/// - JavaScriptCore 的 `JSContext` 本身不提供文件、网络、进程这类接口，脚本只能做纯计算；
/// - 卡死靠执行时限防：所有脚本共用一个虚拟机，给它设了每次调用 50 毫秒的上限
///   （`JSContextGroupSetExecutionTimeLimit`），超时的调用被 JavaScriptCore 终止，这个脚本从此停用。
///   单靠静态检查挡不住死循环——`(()=>{}).constructor("wh" + "ile(1){}")()`、灾难性回溯的正则、
///   `"a".repeat(1e9)` 都能绕过去；
/// - 取不到时限接口时（它不在公开头文件里，按符号名动态查找），才退回原来的静态检查：
///   出现循环、eval、动态导入、定时器、网络请求就整段不跑。
final class SceneScript {
    /// 脚本能看到的图层与场景运行环境
    struct Environment {
        var canvasSize = SIMD2<Float>(1920, 1080)
        var layerOrigin = SIMD3<Float>()
        var layerScale = SIMD3<Float>(1, 1, 1)
        var layerSize = SIMD2<Float>()
        var layerName = ""
        var layerText = ""
        /// 用户属性的当前值（名字 → 值的 JSON 对象），给 engine.userProperties
        var userProperties: Data? = nil
        /// 场景对象接口（`thisObject` / `thisScene`）；nil 时给空替身
        var graph: SceneGraphScriptAPI? = nil
        /// 脚本挂在哪个图层上（`thisObject` 就是它）
        var ownerID: Int = 0
    }

    /// 所有脚本共用的虚拟机：各自的 JSContext 全局变量互不相通，只是共用一个堆，
    /// 不用每个脚本都起一个带独立堆的虚拟机。JavaScriptCore 用 API 锁串行化对同一个虚拟机的访问，
    /// 场景在后台线程构建、在主线程绘制都可以用它
    nonisolated(unsafe) private static let runtime: (machine: JSVirtualMachine, hasTimeLimit: Bool)? = {
        guard let machine = JSVirtualMachine(), let probe = JSContext(virtualMachine: machine) else { return nil }
        return (machine, installTimeLimit(on: JSContextGetGroup(probe.jsGlobalContextRef)))
    }()

    /// 每次调用（载入、init、update）的时间上限，秒
    static let timeLimit: Double = 0.05

    /// 执行时限是否生效；为 false 时只能靠静态检查挡住死循环
    static var hasTimeLimit: Bool { runtime?.hasTimeLimit ?? false }

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetExecutionTimeLimit = @convention(c) (
        JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?
    ) -> Void

    /// JSContextGroupSetExecutionTimeLimit 在 JavaScriptCore 的私有头文件 JSContextRefPrivate.h 里，
    /// 框架导出了这个符号，按名字找到后调用；超时回调一律返回 true（终止）
    private static func installTimeLimit(on group: JSContextGroupRef?) -> Bool {
        guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
              let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit")
        else { return false }
        let setLimit = unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
        setLimit(group, timeLimit, { _, _ in true }, nil)
        return true
    }

    private let context: JSContext
    /// 脚本载入后才取得到（定时器要在载入前装好，这几个就不能是 let）
    private var updateFunction: JSValue?
    private var initFunction: JSValue?
    /// `thisLayer`：有场景状态时是活图层代理（写 origin / alpha 会真的改变渲染），否则是个副本
    private var thisLayer: JSValue
    private let engine: JSValue
    private var vec3: JSValue?
    private var hasRunInit = false
    /// init 的返回值：没有 update 的脚本（例如只挂拖拽回调的）就用它
    private var initResult: JSValue?
    /// 上一次求值的结果：WE 的属性脚本拿到的是"当前值"，脚本输出会喂回下一次
    private var lastValue: Any?
    /// `engine.setTimeout` / `setInterval` 排的定时器（按脚本自己的 runtime 计时）
    private var timers: [(id: Int, callback: JSValue, due: Double, interval: Double?)] = []
    private static let maximumTimers = 1024
    private var nextTimerID = 1
    private var runtimeSeconds: Double = 0

    /// 脚本没跑成或抛了异常时的原因（诊断用）
    private(set) var problem: String?
    /// 有一次调用超时被终止后就停用，免得每帧都白等一个时限
    private var isDisabled = false

    /// - Parameter now: 取"当前时间"，测试里可以固定住
    init?(source: String, properties: Data?, environment: Environment, now: @escaping () -> Date = { Date() }) {
        guard let runtime = Self.runtime, let context = JSContext(virtualMachine: runtime.machine) else { return nil }
        // 脚本太大、或者拿不到执行时限接口又不通过静态检查时，建一个"什么都不做"的实例：
        // 留着 `problem` 说明原因，调用方把它报出来（以前直接返回 nil，原因就丢了）
        if source.utf8.count >= 200_000 {
            problem = "脚本太大（\(source.utf8.count) 字节）"
        } else if !runtime.hasTimeLimit, !Self.isSafe(source) {
            problem = "脚本里有循环或动态代码，取不到执行时限接口时不能安全运行"
        } else {
            problem = nil
        }
        self.context = context

        guard let thisLayer = JSValue(newObjectIn: context),
              let engine = JSValue(newObjectIn: context)
        else { return nil }
        self.thisLayer = thisLayer
        self.engine = engine

        thisLayer.setObject(environment.layerText, forKeyedSubscript: "text" as NSString)
        thisLayer.setObject(environment.layerName, forKeyedSubscript: "name" as NSString)
        thisLayer.setObject(Self.vector3(in: context, environment.layerOrigin), forKeyedSubscript: "origin" as NSString)
        thisLayer.setObject(Self.vector3(in: context, environment.layerScale), forKeyedSubscript: "scale" as NSString)
        thisLayer.setObject(Self.vector3(in: context, environment.layerOrigin), forKeyedSubscript: "originalOrigin" as NSString)
        thisLayer.setObject(
            Self.vector2(in: context, environment.layerSize),
            forKeyedSubscript: "size" as NSString)
        engine.setObject(Self.vector2(in: context, environment.canvasSize), forKeyedSubscript: "canvasSize" as NSString)
        engine.setObject(0, forKeyedSubscript: "runtime" as NSString)
        engine.setObject(1.0 / 30, forKeyedSubscript: "frametime" as NSString)
        // engine 上的这些是**函数**（WE 的 IEngine 文档），以前写成布尔属性会让
        // `engine.isRunningInEditor()` 直接抛异常（Lucy 的 NSL 脚本就是这么挂掉的）
        Self.installEngineAPI(engine, in: context, canvasSize: environment.canvasSize)
        let userProperties = environment.userProperties
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        engine.setObject(userProperties, forKeyedSubscript: "userProperties" as NSString)
        engine.setObject(0, forKeyedSubscript: "timeOfDay" as NSString)

        let millis: @convention(block) () -> Double = { now().timeIntervalSince1970 * 1000 }
        context.setObject(millis, forKeyedSubscript: "__nowMillis" as NSString)
        context.setObject(thisLayer, forKeyedSubscript: "thisLayer" as NSString)
        context.setObject(engine, forKeyedSubscript: "engine" as NSString)
        Self.installAudio(in: context)
        // 定时器同样要在载入前装好：脚本顶层就可能 `engine.setTimeout(...)`
        installTimers()
        Self.installSceneGraph(environment.graph, owner: environment.ownerID, in: context)
        context.evaluateScript(Self.prelude)
        if let graph = environment.graph {
            // 有场景对象接口时，thisLayer / thisObject / thisScene 都换成活的图层对象：
            // `thisLayer.origin = …` 这种写法要真的能移动图层
            _ = graph
            context.evaluateScript(
                "globalThis.thisLayer = __layerByID(__scriptOwner);"
                    + "globalThis.thisObject = globalThis.thisLayer;"
                    + "globalThis.thisScene = __makeScene(__scriptOwner);")
            if let live = context.objectForKeyedSubscript("thisLayer") { self.thisLayer = live }
        } else {
            context.setObject(
                Self.thisObject(in: context, name: environment.layerName),
                forKeyedSubscript: "thisObject" as NSString)
            context.setObject(Self.thisScene(in: context), forKeyedSubscript: "thisScene" as NSString)
        }

        // 被拒的脚本不载入：实例留着，`problem` 说明原因，调用方按静态值处理并把它报出来
        if problem == nil {
            context.evaluateScript(Self.withoutModuleSyntax(source))
            if let exception = context.exception {
                // 载入时就抛异常（多半是用了宿主没提供的接口，例如 engine.registerAudioBuffers），
                // 这种脚本的 update 也跑不起来
                problem = "脚本载入失败：\(exception.toString() ?? "")"
                context.exception = nil
            }
        }
        // 场景里的用户属性覆盖脚本声明的默认值
        if problem == nil, let properties,
           let object = (try? JSONSerialization.jsonObject(with: properties)) as? [String: Any],
           let scriptProperties = context.objectForKeyedSubscript("scriptProperties"), scriptProperties.isObject {
            for (key, value) in object {
                scriptProperties.setObject(value, forKeyedSubscript: key as NSString)
            }
        }
        vec3 = context.objectForKeyedSubscript("Vec3")
        updateFunction = Self.function(named: "update", in: context)
        initFunction = Self.function(named: "init", in: context)
        // WE 在壁纸载入时用全部用户属性（原值，不是 {value: …}）调一次 applyUserProperties，之后属性改了只传改了的；
        // 我们改属性会重建场景，所以只有载入时这一次。以前从没调过：只在这里给变量赋值的脚本拿到的全是 undefined——
        // 2248783434 的人物位置就是这样，`new Vec3(undefined, undefined, z)` 让人物跑到了画布左下角。
        // 这里抛了异常不算脚本坏了（update 可能照样能跑），清掉接着用
        if problem == nil, let apply = Self.function(named: "applyUserProperties", in: context) {
            _ = timed { apply.call(withArguments: [userProperties]) }
            context.exception = nil
        }
    }


    /// 音频频谱的接口（WE 的 `engine.registerAudioBuffers`）：注册过的 AudioBuffers 挂在 JS 的表里，
    /// 每帧由 `refreshAudio` 用系统音频的频谱刷新。必须在载入脚本**之前**装好——脚本在顶层就会调它
    private static func installAudio(in context: JSContext) {
        context.evaluateScript(
            """
            // 音频频谱：注册过的 AudioBuffers 挂在表里，每帧由宿主用系统音频的频谱刷新
            globalThis.__audioBufferList = [];
            engine.registerAudioBuffers = function (resolution) {
                const bands = Math.max(1, resolution | 0);
                const buffers = {
                    average: new Array(bands).fill(0),
                    left: new Array(bands).fill(0),
                    right: new Array(bands).fill(0),
                };
                __audioBufferList.push({ resolution: bands, buffers: buffers });
                return buffers;
            };
            globalThis.__applyAudioBands = function (left, right) {
                for (const entry of __audioBufferList) {
                    const n = entry.resolution, b = entry.buffers;
                    for (let i = 0; i < n; i++) {
                        const start = Math.floor(i * left.length / n);
                        const end = Math.max(start + 1, Math.floor((i + 1) * left.length / n));
                        let l = 0, r = 0, count = 0;
                        for (let j = start; j < end && j < left.length; j++) { l += left[j]; r += right[j]; count++; }
                        l /= count; r /= count;
                        b.left[i] = l; b.right[i] = r; b.average[i] = (l + r) / 2;
                    }
                }
            };
            """)
    }

    /// `engine.setTimeout` / `setInterval`：按脚本自己的 runtime 计时，返回值是取消函数
    /// （WE 的 IEngine 文档里这两个函数的返回值就是 `Function`）
    private func installTimers() {
        let schedule: @convention(block) (JSValue, Double, Bool) -> Int = { [unowned self] callback, delay, repeating in
            let seconds = max(0, delay) / 1000
            let id = nextTimerID
            nextTimerID += 1
            // 每帧都 setInterval 又不取消的脚本会让定时器越积越多，到上限就不再接
            guard timers.count < Self.maximumTimers else { return id }
            timers.append(
                (id: id, callback: callback, due: runtimeSeconds + seconds,
                 interval: repeating ? max(seconds, 1.0 / 240) : nil))
            return id
        }
        let cancel: @convention(block) (Int) -> Void = { [unowned self] id in
            timers.removeAll { $0.id == id }
        }
        engine.setObject(schedule, forKeyedSubscript: "__scheduleTimer" as NSString)
        engine.setObject(cancel, forKeyedSubscript: "__cancelTimer" as NSString)
        context.evaluateScript(
            """
            engine.setTimeout = function (callback, delay) {
                const id = engine.__scheduleTimer(callback, delay === undefined ? 0 : delay, false);
                return function () { engine.__cancelTimer(id); };
            };
            engine.setInterval = function (callback, delay) {
                const id = engine.__scheduleTimer(callback, delay === undefined ? 0 : delay, true);
                return function () { engine.__cancelTimer(id); };
            };
            """)
    }

    /// 每次求值前把运行时信息刷新给脚本
    func setRuntime(_ runtime: Float, frameTime: Float, layerOrigin: SIMD3<Float>, layerScale: SIMD3<Float>) {
        engine.setObject(Double(runtime), forKeyedSubscript: "runtime" as NSString)
        engine.setObject(Double(frameTime), forKeyedSubscript: "frametime" as NSString)
        runtimeSeconds = Double(runtime)
        fireDueTimers()
        // 有场景状态时 thisLayer 是活图层代理，写 origin / scale 会真的改渲染，这里就不覆盖了
        guard thisLayer.objectForKeyedSubscript("__id")?.isUndefined ?? true else { return }
        thisLayer.setObject(Self.vector3(in: context, layerOrigin), forKeyedSubscript: "origin" as NSString)
        thisLayer.setObject(Self.vector3(in: context, layerScale), forKeyedSubscript: "scale" as NSString)
    }

    /// 到点的定时器（`engine.setTimeout` / `setInterval`）：一次性的删掉，周期性的排下一轮。
    /// 只触发这一帧开始时已经到点的：回调里新排的（哪怕延时 0）等下一帧，否则 `setTimeout(f, 0)`
    /// 自己排自己时会在一帧里转个不停；回调里取消的别的定时器也不再触发
    private func fireDueTimers() {
        guard !timers.isEmpty else { return }
        let due = timers.filter { $0.due <= runtimeSeconds }.map(\.id)
        for id in due {
            guard let index = timers.firstIndex(where: { $0.id == id }) else { continue }
            let timer = timers[index]
            if let interval = timer.interval {
                timers[index].due = runtimeSeconds + interval
            } else {
                timers.remove(at: index)
            }
            _ = timed { timer.callback.call(withArguments: []) }
            if let exception = context.exception {
                problem = "定时器出错：\(exception.toString() ?? "")"
                context.exception = nil
            }
            if isDisabled { return }
        }
    }

    // MARK: - 求值

    /// 文字内容：`update(value)` 返回新字符串，或者直接写 `thisLayer.text`
    func updateText(_ value: String) -> String? {
        let argument = (lastValue as? String) ?? value
        guard let result = call(initial: argument) else { return nil }
        if let string = result.toString(), !result.isUndefined, !result.isNull, result.isString {
            lastValue = string
            return string
        }
        // 有的脚本不返回值，而是自己写 thisLayer.text（3535216365 的 Clock 就是这样）
        if let text = thisLayer.objectForKeyedSubscript("text")?.toString(), !text.isEmpty {
            lastValue = text
            return text
        }
        lastValue = argument
        return argument
    }

    /// 向量属性（origin / scale / angles / color）。脚本返回一个数时按分量广播（WE 允许"scale: 2"这种写法）
    func updateVector(_ value: SIMD3<Float>) -> SIMD3<Float>? {
        let argument = (lastValue as? SIMD3<Float>) ?? value
        guard let object = vec3?.construct(withArguments: [argument.x, argument.y, argument.z])
                ?? Self.vector3(in: context, argument),
              let result = call(initial: object), let vector = Self.value(of: result)
        else { return nil }
        lastValue = vector
        return vector
    }

    func updateNumber(_ value: Float) -> Float? {
        let argument = (lastValue as? Float) ?? value
        guard let result = call(initial: argument) else { return nil }
        guard result.isNumber else { return nil }
        let number = Float(result.toDouble())
        lastValue = number
        return number
    }

    func updateBool(_ value: Bool) -> Bool? {
        let argument = (lastValue as? Bool) ?? value
        guard let result = call(initial: argument) else { return nil }
        guard result.isBoolean else { return nil }
        let flag = result.toBool()
        lastValue = flag
        return flag
    }

    /// 跑一次 init（开机时一次）+ update。WE 的约定：init(value) 的返回值就是属性的初始值，
    /// 没有返回值时保持原值；之后每次 update 拿到当前值、返回新值
    private func call(initial: Any) -> JSValue? {
        guard !isDisabled else { return nil }
        var argument = initial
        if !hasRunInit {
            hasRunInit = true
            if let initFunction {
                let result = timed { initFunction.call(withArguments: [initial]) }
                if context.exception != nil {
                    context.exception = nil
                } else if let result, !result.isUndefined, !result.isNull {
                    initResult = result
                    argument = result
                }
                if isDisabled { return nil }
            }
        }
        guard let updateFunction else { return initResult }
        let result = timed { updateFunction.call(withArguments: [argument]) }
        if let exception = context.exception {
            problem = isDisabled
                ? "脚本单次运行超过 \(Int(Self.timeLimit * 1000)) 毫秒，已停用"
                : "脚本出错：\(exception.toString() ?? "")"
            context.exception = nil
            return nil
        }
        return result
    }

    /// 调用一次，超过时限（被 JavaScriptCore 终止）就停用这个脚本
    private func timed(_ body: () -> JSValue?) -> JSValue? {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        if context.exception != nil, elapsed >= Self.timeLimit * 0.9 { isDisabled = true }
        return result
    }

    private static func value(of result: JSValue) -> SIMD3<Float>? {
        if result.isNumber {
            let number = Float(result.toDouble())
            return SIMD3(number, number, number)
        }
        guard result.isObject else { return nil }
        let x = result.objectForKeyedSubscript("x"), y = result.objectForKeyedSubscript("y")
        let z = result.objectForKeyedSubscript("z")
        guard let x, let y, let z, x.isNumber, y.isNumber, z.isNumber else { return nil }
        return SIMD3(Float(x.toDouble()), Float(y.toDouble()), Float(z.toDouble()))
    }

    private static func vector3(in context: JSContext, _ value: SIMD3<Float>) -> JSValue? {
        guard let object = JSValue(newObjectIn: context) else { return nil }
        object.setObject(Double(value.x), forKeyedSubscript: "x" as NSString)
        object.setObject(Double(value.y), forKeyedSubscript: "y" as NSString)
        object.setObject(Double(value.z), forKeyedSubscript: "z" as NSString)
        return object
    }

    /// canvasSize / size 这类二维值
    private static func vector2(in context: JSContext, _ value: SIMD2<Float>) -> JSValue? {
        guard let object = JSValue(newObjectIn: context) else { return nil }
        object.setObject(Double(value.x), forKeyedSubscript: "x" as NSString)
        object.setObject(Double(value.y), forKeyedSubscript: "y" as NSString)
        return object
    }

    /// 取全局里的函数；不存在时返回 nil（`objectForKeyedSubscript` 给的是 undefined，不能直接调用）
    private static func function(named name: String, in context: JSContext) -> JSValue? {
        guard let value = context.objectForKeyedSubscript(name), !value.isUndefined, !value.isNull else { return nil }
        return value
    }

    // MARK: - 鼠标事件

    /// 脚本里注册了这个回调吗（`cursorEnter` / `cursorLeave` / `cursorMove`…
    /// 桌面窗口收不到点击，所以只送"进入 / 离开 / 移动"）
    func hasHandler(_ name: String) -> Bool { Self.function(named: name, in: context) != nil }

    /// 调一个鼠标回调，参数是 `{ worldPosition: Vec3 }`（画布坐标）
    func callHandler(_ name: String, worldPosition: SIMD2<Float>) {
        guard let function = Self.function(named: name, in: context) else { return }
        guard let event = JSValue(newObjectIn: context) else { return }
        event.setObject(
            vector(SIMD3(worldPosition.x, worldPosition.y, 0)),
            forKeyedSubscript: "worldPosition" as NSString)
        _ = function.call(withArguments: [event])
        if let exception = context.exception {
            problem = "\(name) 回调出错：\(exception.toString() ?? "")"
            context.exception = nil
        }
    }

    /// 交给脚本的向量值：优先用 Vec3 实例（脚本会调 .add / .subtract 这些方法），给不出就退回普通对象
    private func vector(_ value: SIMD3<Float>) -> JSValue? {
        if let vec3, let instance = vec3.construct(withArguments: [value.x, value.y, value.z]) { return instance }
        return Self.vector3(in: context, value)
    }

    /// 把场景对象接口装进 JS：图层的属性读写都通过这几个块回到 Swift 的运行时状态。
    /// 没有场景状态时（测试、或只有单个图层脚本）装的是空替身，脚本照样能跑，只是改了不生效。
    private static func installSceneGraph(_ graph: SceneGraphScriptAPI?, owner: Int, in context: JSContext) {
        context.setObject(owner, forKeyedSubscript: "__scriptOwner" as NSString)
        let name: @convention(block) (Int) -> String? = { graph?.layerName($0) }
        let alpha: @convention(block) (Int) -> Double = { graph?.layerAlpha($0) ?? 1 }
        let setAlpha: @convention(block) (Int, Double) -> Void = { id, value in
            if let graph { graph.setLayerAlpha(id, value) }
        }
        let visible: @convention(block) (Int) -> Bool = { graph?.layerVisible($0) ?? true }
        let setVisible: @convention(block) (Int, Bool) -> Void = { id, value in
            if let graph { graph.setLayerVisible(id, value) }
        }
        let origin: @convention(block) (Int) -> [Double] = { id in
            let value = graph?.layerOrigin(id) ?? .zero
            return [Double(value.x), Double(value.y), Double(value.z)]
        }
        let setOrigin: @convention(block) (Int, Double, Double, Double) -> Void = { id, x, y, z in
            if let graph { graph.setLayerOrigin(id, SIMD3(Float(x), Float(y), Float(z))) }
        }
        let scale: @convention(block) (Int) -> [Double] = { id in
            let value = graph?.layerScale(id) ?? SIMD3(1, 1, 1)
            return [Double(value.x), Double(value.y), Double(value.z)]
        }
        let setScale: @convention(block) (Int, Double, Double, Double) -> Void = { id, x, y, z in
            if let graph { graph.setLayerScale(id, SIMD3(Float(x), Float(y), Float(z))) }
        }
        let children: @convention(block) (Int) -> [Int] = { graph?.layerChildren($0) ?? [] }
        let create: @convention(block) (String) -> Int = { graph?.createLayer(model: $0) ?? -1 }
        let angles: @convention(block) (Int) -> [Double] = { id in
            let value = graph?.layerAngles(id) ?? .zero
            return [Double(value.x), Double(value.y), Double(value.z)]
        }
        let setAngles: @convention(block) (Int, Double, Double, Double) -> Void = { id, x, y, z in
            if let graph { graph.setLayerAngles(id, SIMD3(Float(x), Float(y), Float(z))) }
        }
        let size: @convention(block) (Int) -> [Double] = { id in
            let value = graph?.layerSize(id) ?? SIMD2(1, 1)
            return [Double(value.x), Double(value.y)]
        }
        let index: @convention(block) (Int) -> Int = { graph?.layerIndex($0) ?? -1 }
        let idByName: @convention(block) (String) -> Int = { graph?.layerID(named: $0) ?? -1 }
        let sort: @convention(block) (Int, Int) -> Void = { id, position in
            if let graph { graph.sortLayer(id, index: position) }
        }
        let alignment: @convention(block) (Int) -> String = { graph?.layerAlignment($0) ?? "center" }
        let setAlignment: @convention(block) (Int, String) -> Void = { id, value in
            if let graph { graph.setLayerAlignment(id, value) }
        }
        let parallaxDepth: @convention(block) (Int) -> [Double] = { id in
            let value = graph?.layerParallaxDepth(id) ?? SIMD2(1, 1)
            return [Double(value.x), Double(value.y)]
        }
        let setParallaxDepth: @convention(block) (Int, Double, Double) -> Void = { id, x, y in
            if let graph { graph.setLayerParallaxDepth(id, SIMD2(Float(x), Float(y))) }
        }
        context.setObject(name, forKeyedSubscript: "__layerName" as NSString)
        context.setObject(alpha, forKeyedSubscript: "__layerAlpha" as NSString)
        context.setObject(setAlpha, forKeyedSubscript: "__layerSetAlpha" as NSString)
        context.setObject(visible, forKeyedSubscript: "__layerVisible" as NSString)
        context.setObject(setVisible, forKeyedSubscript: "__layerSetVisible" as NSString)
        context.setObject(origin, forKeyedSubscript: "__layerOrigin" as NSString)
        context.setObject(setOrigin, forKeyedSubscript: "__layerSetOrigin" as NSString)
        context.setObject(scale, forKeyedSubscript: "__layerScale" as NSString)
        context.setObject(setScale, forKeyedSubscript: "__layerSetScale" as NSString)
        context.setObject(children, forKeyedSubscript: "__layerChildren" as NSString)
        context.setObject(size, forKeyedSubscript: "__layerSize" as NSString)
        context.setObject(create, forKeyedSubscript: "__createLayer" as NSString)
        context.setObject(angles, forKeyedSubscript: "__layerAngles" as NSString)
        context.setObject(setAngles, forKeyedSubscript: "__layerSetAngles" as NSString)
        context.setObject(index, forKeyedSubscript: "__layerIndex" as NSString)
        context.setObject(idByName, forKeyedSubscript: "__layerIDByName" as NSString)
        context.setObject(sort, forKeyedSubscript: "__sortLayer" as NSString)
        context.setObject(alignment, forKeyedSubscript: "__layerAlignment" as NSString)
        context.setObject(setAlignment, forKeyedSubscript: "__layerSetAlignment" as NSString)
        context.setObject(parallaxDepth, forKeyedSubscript: "__layerParallaxDepth" as NSString)
        context.setObject(setParallaxDepth, forKeyedSubscript: "__layerSetParallaxDepth" as NSString)
    }

    /// 脚本注册过音频频谱吗（`engine.registerAudioBuffers`）；注册了就不会再撤销，记住结果免得每帧查 JS
    var wantsAudio: Bool {
        if registeredAudio { return true }
        guard let list = context.objectForKeyedSubscript("__audioBufferList"),
              let length = list.objectForKeyedSubscript("length"), length.isNumber
        else { return false }
        registeredAudio = length.toInt32() > 0
        return registeredAudio
    }
    private var registeredAudio = false

    /// 把系统音频的频谱推给脚本里注册过的 AudioBuffers（每帧一次）
    func refreshAudio(_ bands: (left: [Float], right: [Float])?) {
        guard let bands, wantsAudio,
              let apply = context.objectForKeyedSubscript("__applyAudioBands"), apply.isObject
        else { return }
        let left = JSValue(object: bands.left.map { Double($0) }, in: context)
        let right = JSValue(object: bands.right.map { Double($0) }, in: context)
        _ = apply.call(withArguments: [left as Any, right as Any])
        if context.exception != nil { context.exception = nil }
    }

    /// engine 上的常量与函数（对照 WE 的 IEngine 文档）：
    /// - 常量：AUDIO_RESOLUTION_16 / 32 / 64；
    /// - 判断类函数：桌面端、横向、当前是壁纸而不是屏保、不在编辑器里；
    /// - `registerAudioBuffers`：返回的数组由 `refreshAudio` 每帧用系统音频的频谱刷新
    ///   （没有采集到音频时是 0，也就是静音的样子）。
    private static func installEngineAPI(_ engine: JSValue, in context: JSContext, canvasSize: SIMD2<Float>) {
        engine.setObject(16, forKeyedSubscript: "AUDIO_RESOLUTION_16" as NSString)
        engine.setObject(32, forKeyedSubscript: "AUDIO_RESOLUTION_32" as NSString)
        engine.setObject(64, forKeyedSubscript: "AUDIO_RESOLUTION_64" as NSString)
        let yes: @convention(block) () -> Bool = { true }
        let no: @convention(block) () -> Bool = { false }
        engine.setObject(yes, forKeyedSubscript: "isDesktopDevice" as NSString)
        engine.setObject(no, forKeyedSubscript: "isMobileDevice" as NSString)
        engine.setObject(yes, forKeyedSubscript: "isWallpaper" as NSString)
        engine.setObject(no, forKeyedSubscript: "isScreensaver" as NSString)
        engine.setObject(no, forKeyedSubscript: "isRunningInEditor" as NSString)
        engine.setObject(canvasSize.x < canvasSize.y ? yes : no, forKeyedSubscript: "isPortrait" as NSString)
        engine.setObject(canvasSize.x < canvasSize.y ? no : yes, forKeyedSubscript: "isLandscape" as NSString)
        engine.setObject(Self.vector2(in: context, canvasSize), forKeyedSubscript: "screenResolution" as NSString)
        let shortcut: @convention(block) (String) -> Bool = { _ in false }
        engine.setObject(shortcut, forKeyedSubscript: "openUserShortcut" as NSString)
    }

    /// `thisObject` / `thisScene` 的最小替身：框架类脚本靠它们拿子图层，拿不到就自己退回静态值
    private static func thisObject(in context: JSContext, name: String) -> JSValue? {
        guard let object = JSValue(newObjectIn: context) else { return nil }
        object.setObject(name, forKeyedSubscript: "name" as NSString)
        let emptyList: @convention(block) () -> [Any] = { [] }
        object.setObject(emptyList, forKeyedSubscript: "getChildren" as NSString)
        object.setObject(0, forKeyedSubscript: "getAnimationLayerCount" as NSString)
        let noLayer: @convention(block) () -> Any? = { nil }
        object.setObject(noLayer, forKeyedSubscript: "getAnimationLayer" as NSString)
        return object
    }

    private static func thisScene(in context: JSContext) -> JSValue? {
        guard let scene = JSValue(newObjectIn: context) else { return nil }
        let noLayer: @convention(block) () -> Any? = { nil }
        let noIndex: @convention(block) () -> Int32 = { -1 }
        scene.setObject(noLayer, forKeyedSubscript: "getLayer" as NSString)
        scene.setObject(noIndex, forKeyedSubscript: "getLayerIndex" as NSString)
        scene.setObject(0, forKeyedSubscript: "getLayerCount" as NSString)
        return scene
    }

    // MARK: - 静态检查（取不到执行时限时的退路）

    /// 拒绝会让宿主卡住的常见写法。只在执行时限不可用时使用：它挡不住刻意绕过的写法，
    /// 还会误伤带正常循环的脚本
    static func isSafe(_ source: String) -> Bool {
        let code = removingComments(source)
        let patterns = [
            #"\bfor\s*\("#, #"\bwhile\s*\("#, #"\bdo\s*\{"#,
            #"\beval\s*\("#, #"\bnew\s+Function\b"#, #"\bFunction\s*\("#,
            #"\bimport\b"#, #"\brequire\s*\("#, #"\bexport\s+default\b"#,
            #"\bsetTimeout\b"#, #"\bsetInterval\b"#, #"\brequestAnimationFrame\b"#,
            #"\bfetch\s*\("#, #"\bXMLHttpRequest\b"#, #"\bWebAssembly\b"#, #"\bimportScripts\b"#,
        ]
        return !patterns.contains { pattern in
            code.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// 去掉注释再检查，免得被注释掉的代码误伤（`~/wp` 里就有注释掉的 for 循环说明）
    static func removingComments(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var quote: Character?
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if let current = quote {
                output.append(character)
                if character == "\\", next < source.endIndex {
                    output.append(source[next])
                    index = source.index(after: next)
                    continue
                }
                if character == current { quote = nil }
                index = next
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
                output.append(character)
                index = next
                continue
            }
            if character == "/", next < source.endIndex, source[next] == "/" {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            if character == "/", next < source.endIndex, source[next] == "*" {
                index = source.index(after: next)
                while index < source.endIndex {
                    let after = source.index(after: index)
                    if source[index] == "*", after < source.endIndex, source[after] == "/" {
                        index = source.index(after: after)
                        break
                    }
                    index = after
                }
                continue
            }
            output.append(character)
            index = next
        }
        return output
    }

    /// WE 的脚本是 ES 模块（`export function update` / `export var scriptProperties`）；
    /// JavaScriptCore 没有模块加载，去掉行首的 export 就能当普通脚本跑
    static func withoutModuleSyntax(_ source: String) -> String {
        // 只在行首匹配会漏掉压缩过的脚本（`"use strict";export var x=…` 整行连着写），
        // 所以按"前面是行首、分号或花括号"来认
        source.replacingOccurrences(
            of: #"(^|[;\{\}\n])(\s*)export\s+"#, with: "$1$2", options: .regularExpression)
    }

    /// 宿主注入的全局对象和方法
    private static let prelude = """
    (function () {
        const RealDate = Date;
        function ScriptDate(...args) {
            return args.length ? new RealDate(...args) : new RealDate(__nowMillis());
        }
        ScriptDate.now = () => __nowMillis();
        ScriptDate.parse = RealDate.parse;
        ScriptDate.UTC = RealDate.UTC;
        ScriptDate.prototype = RealDate.prototype;
        globalThis.Date = ScriptDate;

        class Vec3 {
            constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }
            clone() { return new Vec3(this.x, this.y, this.z); }
            // WE 的写法有两种：copy() 当克隆用（可视化条就是这么写的），copy(v) 从另一个向量拷过来
            copy(v) {
                if (v === undefined || v === null) return new Vec3(this.x, this.y, this.z);
                this.x = v.x; this.y = v.y; this.z = v.z; return this;
            }
            add(v) { return new Vec3(this.x + v.x, this.y + v.y, this.z + v.z); }
            subtract(v) { return new Vec3(this.x - v.x, this.y - v.y, this.z - v.z); }
            multiply(v) { return new Vec3(this.x * v.x, this.y * v.y, this.z * v.z); }
            divide(v) { return new Vec3(this.x / v.x, this.y / v.y, this.z / v.z); }
            multiplyScalar(s) { return new Vec3(this.x * s, this.y * s, this.z * s); }
            length() { return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z); }
            normalize() { const l = this.length() || 1; return this.multiplyScalar(1 / l); }
            dot(v) { return this.x * v.x + this.y * v.y + this.z * v.z; }
            cross(v) {
                return new Vec3(this.y * v.z - this.z * v.y, this.z * v.x - this.x * v.z,
                                this.x * v.y - this.y * v.x);
            }
            reflect(n) { return this.subtract(n.multiplyScalar(2 * this.dot(n))); }
            equals(v) { return this.x === v.x && this.y === v.y && this.z === v.z; }
            toString() { return this.x + ' ' + this.y + ' ' + this.z; }
        }
        globalThis.Vec3 = Vec3;
        globalThis.Vec2 = class Vec2 {
            constructor(x = 0, y = 0) { this.x = x; this.y = y; }
            clone() { return new Vec2(this.x, this.y); }
            copy(v) {
                if (v === undefined || v === null) return new Vec2(this.x, this.y);
                this.x = v.x; this.y = v.y; return this;
            }
            add(v) { return new Vec2(this.x + v.x, this.y + v.y); }
            subtract(v) { return new Vec2(this.x - v.x, this.y - v.y); }
            multiply(v) { return new Vec2(this.x * v.x, this.y * v.y); }
            divide(v) { return new Vec2(this.x / v.x, this.y / v.y); }
            toString() { return this.x + ' ' + this.y; }
        };

        // WE 的媒体集成（正在播放的歌曲、专辑封面）：事件类型和状态常量。宿主不发媒体事件，
        // 脚本就停在"没有在放"（PLAYBACK_STOPPED）——和 WE 里没开媒体播放器时一样，专辑封面这类图层保持隐藏。
        // 以前没有这些名字，脚本一载入就因为 MediaPlaybackEvent 未定义失败，按静态值处理成一直显示
        globalThis.MediaPlaybackEvent = { PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 };
        globalThis.MediaPropertiesEvent = class MediaPropertiesEvent {};
        globalThis.MediaThumbnailEvent = class MediaThumbnailEvent {};
        globalThis.MediaTimelineEvent = class MediaTimelineEvent {};
        globalThis.MediaStatusEvent = class MediaStatusEvent {};

        globalThis.createScriptProperties = function () {
            const values = {};
            const builder = new Proxy({}, {
                get(target, key) {
                    if (key === 'finish') return () => values;
                    return (config) => {
                        if (config && typeof config === 'object' && config.name !== undefined) {
                            if ('value' in config) values[config.name] = config.value;
                            else if (Array.isArray(config.options) && config.options.length)
                                values[config.name] = config.options[0].value;
                        }
                        return builder;
                    };
                }
            });
            return builder;
        };

        globalThis.shared = globalThis.shared || {};
        globalThis.console = { log: () => {}, warn: () => {}, error: () => {}, info: () => {} };
        globalThis.localStorage = { get: () => null, set: () => {}, remove: () => {}, clear: () => {} };
        globalThis.Math.random = (() => { let seed = 12345; return () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648; })();

        // 场景对象接口：图层对象把属性读写转给宿主（`thisObject` / `thisScene`）。
        // 幻灯片控制器那类脚本靠它遍历子图层、改透明度和缩放、调整绘制顺序。
        const layerCache = new Map();
        class Layer {
            constructor(id) { this.__id = id; }
            get name() { return __layerName(this.__id); }
            get alpha() { return __layerAlpha(this.__id); }
            set alpha(value) { __layerSetAlpha(this.__id, value); }
            get visible() { return __layerVisible(this.__id); }
            set visible(value) { __layerSetVisible(this.__id, value); }
            get origin() { const p = __layerOrigin(this.__id); return new Vec3(p[0], p[1], p[2]); }
            set origin(value) { __layerSetOrigin(this.__id, value.x, value.y, value.z); }
            get scale() { const p = __layerScale(this.__id); return new Vec3(p[0], p[1], p[2]); }
            set scale(value) { __layerSetScale(this.__id, value.x, value.y, value.z); }
            get size() { const p = __layerSize(this.__id); return new Vec2(p[0], p[1]); }
            get angles() { const p = __layerAngles(this.__id); return new Vec3(p[0], p[1], p[2]); }
            set angles(value) { __layerSetAngles(this.__id, value.x, value.y, value.z); }
            // 对齐方式："center" / "bottom" / "topleft"…（可视化条把柱子设成底边对齐，从底边往上长）
            get alignment() { return __layerAlignment(this.__id); }
            set alignment(value) { __layerSetAlignment(this.__id, String(value)); }
            // 视差深度（general.cameraparallax 打开时决定这一层跟着镜头挪多少）
            get parallaxDepth() { const p = __layerParallaxDepth(this.__id); return new Vec2(p[0], p[1]); }
            set parallaxDepth(value) { __layerSetParallaxDepth(this.__id, value.x, value.y); }
            getChildren() { return __layerChildren(this.__id).map((id) => globalThis.__layerByID(id)); }
            // 特效实例（`effect.instance.alpha`）：结构给上，改动还不生效
            get instance() { return { alpha: 0 }; }
        }
        globalThis.__layerByID = function (id) {
            if (!layerCache.has(id)) layerCache.set(id, new Layer(id));
            return layerCache.get(id);
        };
        globalThis.__makeScene = function () {
            return {
                getLayer(name) {
                    const id = __layerIDByName(name);
                    return id >= 0 ? globalThis.__layerByID(id) : undefined;
                },
                getLayerIndex(layer) {
                    return layer && layer.__id !== undefined ? __layerIndex(layer.__id) : -1;
                },
                sortLayer(layer, index) {
                    if (layer && layer.__id !== undefined) __sortLayer(layer.__id, index);
                },
                // 运行时建图层（WE 的 IScene.createLayer）：返回的图层句柄可以直接改属性
                createLayer(model) {
                    const id = __createLayer(model);
                    return id >= 0 ? globalThis.__layerByID(id) : undefined;
                }
            };
        };
    })();
    """
}
