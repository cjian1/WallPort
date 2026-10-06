import Foundation
import Metal
import SceneRenderer
import WallpaperFormats
import WallpaperLibrary

/// 每个动态场景在屏幕尺寸上每帧要花多少：CPU（本线程的编码、粒子模拟、蒙皮、脚本；以及整个进程的，
/// 含 Metal 驱动的线程）和 GPU 时间，再按每秒 30 帧折成"一直开着要占多少"。
/// 静态场景（没有特效和动画）在桌面上只画一次，不计。只打印编号和数量，不打印标题。
///
///   WallpaperTool bench-scenes <目录> <WE 自带素材目录> [帧数]
///   TARGET_WIDTH / TARGET_HEIGHT：屏幕像素尺寸，默认 3024×1964（14 寸 MacBook Pro）
///   HIDDEN_ELEMENTS：关掉某些粒子 / 特效（键见 SceneElements），拆分每帧的开销
///   BENCH_FPS：按每秒多少帧推进场景时间（默认 30；"不限制帧率"时 ProMotion 屏是 120）
///   BENCH_REALTIME=秒数：改成按真实时间跑这么久（和桌面上一样不等 GPU、视频只取解好的帧），看主线程会不会被卡住
func benchScenes(in directory: String, assets: URL, frames: Int) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    let environment = ProcessInfo.processInfo.environment
    let width = environment["TARGET_WIDTH"].flatMap(Int.init) ?? 3024
    let height = environment["TARGET_HEIGHT"].flatMap(Int.init) ?? 1964
    let fps = max(1, environment["BENCH_FPS"].flatMap(Int.init) ?? 30)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: SceneRenderer.pixelFormat, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    guard let target = device.makeTexture(descriptor: descriptor) else {
        print("✗ 建不了渲染目标")
        return 1
    }
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    struct Row {
        let id: String
        let summary: String
        let threadCPU: Double
        /// 编码一帧的墙钟时间：在桌面上就是主线程被占住多久（含等视频解码这类阻塞）
        let wall: Double
        let processCPU: Double
        let gpu: Double
    }
    var rows: [Row] = []
    var staticCount = 0
    /// 只有脚本 / 文字会改画面的场景：桌面上图层状态变了才画（见 `redrawsOnlyWhenStateChanges`）
    var stateDrivenCount = 0
    for folder in folders {
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene,
              let package = try? ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))
        else { continue }
        let id = folder.lastPathComponent
        // HIDDEN_ELEMENTS='effect:shake,particles:xxx'：和设置面板里关掉这几项一样，用来拆分每帧的开销
        let hidden = Set((environment["HIDDEN_ELEMENTS"] ?? "").split(separator: ",").map(String.init))
        guard let renderer = try? SceneRenderer(
            device: device, package: package, assets: assets, targetSize: SIMD2(Float(width), Float(height)),
            userProperties: project.propertyValuesJSON(overrides: [:]), hiddenElements: hidden)
        else {
            print("✗ \(id) 建不起来")
            continue
        }
        guard renderer.needsAnimation else {
            staticCount += 1
            continue
        }
        guard !renderer.redrawsOnlyWhenStateChanges else {
            stateDrivenCount += 1
            continue
        }
        func frame(_ index: Int) -> (thread: Double, wall: Double, gpu: Double) {
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let startedWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard let commands = renderer.makeCommandBuffer() else { return (0, 0, 0) }
            renderer.encode(
                into: target, commandBuffer: commands, time: 5 + Float(index) / Float(fps), pointer: SIMD2(0.5, 0.5),
                pointerEvents: [])
            commands.commit()
            let encoded = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let encodedWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            commands.waitUntilCompleted()
            return (Double(encoded - started) / 1e6, Double(encodedWall - startedWall) / 1e6,
                    (commands.gpuEndTime - commands.gpuStartTime) * 1000)
        }
        for index in 0..<5 { _ = frame(index) }
        if let seconds = environment["BENCH_REALTIME"].flatMap(Double.init) {
            realtime(renderer, target: target, fps: fps, seconds: seconds, id: id)
            continue
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let processBefore = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        var thread = 0.0, wall = 0.0, gpu = 0.0
        for index in 0..<frames {
            let cost = frame(index + 5)
            thread += cost.thread
            wall += cost.wall
            gpu += cost.gpu
        }
        getrusage(RUSAGE_SELF, &usage)
        let process = (seconds(usage.ru_utime) + seconds(usage.ru_stime) - processBefore) * 1000
        rows.append(Row(
            id: id, summary: "\(renderer.drawnLayerCount) 层、\(renderer.renderedEffectCount) 个特效",
            threadCPU: thread / Double(frames), wall: wall / Double(frames), processCPU: process / Double(frames),
            gpu: gpu / Double(frames)))
    }
    print("屏幕 \(width)×\(height)，每秒 \(fps) 帧推进，每个场景量 \(frames) 帧；静态场景 \(staticCount) 个（桌面上只画一次，不计）、"
        + "只有脚本 / 文字会改画面的 \(stateDrivenCount) 个（状态变了才画，不计）")
    print("编号          内容                 CPU/帧(本线程)  主线程占用/帧  CPU/帧(整个进程)  GPU/帧   \(fps) 帧时约占 CPU  GPU")
    let percent = Double(fps) / 10
    for row in rows.sorted(by: { $0.processCPU > $1.processCPU }) {
        print(String(
            format: "%-13@ %-20@ %8.2f ms %11.2f ms %12.2f ms %9.2f ms %9.0f%% %9.0f%%",
            row.id, row.summary, row.threadCPU, row.wall, row.processCPU, row.gpu, row.processCPU * percent,
            row.gpu * percent))
    }
    return 0
}

/// 按真实时间跑（和桌面上一样：场景时间跟着墙钟走，每秒 `fps` 帧，不等 GPU 画完），统计每帧编码占了主线程多久、
/// 实际画出多少帧——主线程一被卡住，下一帧要追的时间就更长，看得出会不会越追越慢
private func realtime(_ renderer: SceneRenderer, target: any MTLTexture, fps: Int, seconds: Double, id: String) {
    // 和桌面上一样：视频贴图只用后台解好的帧
    renderer.waitsForVideoFrames = false
    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9 }
    var costs: [Double] = []
    var busy = 0.0
    var next = 0.0
    while now() < seconds {
        let began = now()
        guard let commands = renderer.makeCommandBuffer() else { break }
        renderer.encode(
            into: target, commandBuffer: commands, time: Float(5 + began), pointer: SIMD2(0.5, 0.5), pointerEvents: [])
        commands.commit()
        let cost = now() - began
        costs.append(cost * 1000)
        busy += cost
        next = max(next + 1 / Double(fps), now())
        let wait = next - now()
        if wait > 0 { usleep(UInt32(wait * 1e6)) }
    }
    costs.sort()
    let percentile = { (p: Double) in costs.isEmpty ? 0 : costs[min(costs.count - 1, Int(Double(costs.count) * p))] }
    print(String(
        format: "%@ 实时 %.0f 秒：画了 %d 帧（%.0f 帧/秒，目标 %d），主线程占用 %.0f%%，每帧编码 中位 %.1f ms、95%% %.1f ms、最长 %.1f ms",
        id, seconds, costs.count, Double(costs.count) / seconds, fps, busy / seconds * 100, percentile(0.5),
        percentile(0.95), costs.last ?? 0))
}

private func seconds(_ time: timeval) -> Double {
    Double(time.tv_sec) + Double(time.tv_usec) / 1e6
}
