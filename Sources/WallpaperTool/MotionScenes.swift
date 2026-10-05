import CoreGraphics
import Foundation
import ImageIO
import Metal
import SceneRenderer
import WallpaperFormats
import WallpaperLibrary

/// 每个动态场景按画面动得多快会被自动帧率定成几帧（见 `AdaptiveFrameRate`），以及按这个帧率能省多少 GPU。
/// 和桌面上一样按每秒 30 帧连续画，在第 3、5、7、9 秒各量一次（隔 3 帧的两张画面）。只打印编号和数字。
///
///   WallpaperTool motion-scenes <目录> <WE 自带素材目录>
///   TARGET_WIDTH / TARGET_HEIGHT：屏幕像素尺寸，默认 3024×1964（14 寸 MacBook Pro，每个点 2 个像素）
func motionScenes(in directory: String, assets: URL) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice(), let probe = try? MotionProbe(device: device) else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    let environment = ProcessInfo.processInfo.environment
    let width = environment["TARGET_WIDTH"].flatMap(Int.init) ?? 3024
    let height = environment["TARGET_HEIGHT"].flatMap(Int.init) ?? 1964
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

    final class Captured: @unchecked Sendable {
        let lock = NSLock()
        var frame: LumaFrame?
    }
    var rows: [(id: String, gpu: Double, rate: Int, detail: String)] = []
    /// 每次测量在 CPU 上比两帧用了多久（毫秒）
    var estimateTimes: [Double] = []
    for folder in folders {
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene,
              let package = try? ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg")),
              let renderer = try? SceneRenderer(
                  device: device, package: package, assets: assets, targetSize: SIMD2(Float(width), Float(height)),
                  userProperties: project.propertyValuesJSON(overrides: [:])),
              renderer.needsAnimation
        else { continue }
        var gpu: [Double] = []
        /// 画第 `frame` 帧（按 30 帧算的时间）；要的话顺便缩一张亮度图
        func render(_ frame: Int, capture: Bool) -> LumaFrame? {
            guard let commands = renderer.makeCommandBuffer() else { return nil }
            renderer.encode(
                into: target, commandBuffer: commands, time: Float(frame) / 30, pointer: SIMD2(0.5, 0.5),
                pointerEvents: [])
            let captured = Captured()
            if capture {
                probe.capture(target, into: commands) { luma in
                    captured.lock.withLock { captured.frame = luma }
                }
            }
            commands.commit()
            commands.waitUntilCompleted()
            gpu.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
            // 完成回调可能比 waitUntilCompleted 晚一点点
            for _ in 0..<200 where capture && captured.lock.withLock({ captured.frame == nil }) { usleep(1000) }
            return captured.lock.withLock { captured.frame }
        }
        var results: [MotionEstimator.Result] = []
        for second in [3, 5, 7, 9] {
            let start = second * 30
            for frame in (start - 6)..<start { _ = render(frame, capture: false) }
            guard let earlier = render(start, capture: true) else { continue }
            _ = render(start + 1, capture: false)
            _ = render(start + 2, capture: false)
            guard let later = render(start + 3, capture: true) else { continue }
            let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard let result = MotionEstimator.measure(from: earlier, to: later, interval: 0.1) else { continue }
            estimateTimes.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e6)
            results.append(result)
            if let debug = environment["MOTION_DEBUG"] {
                writeBlockMap(earlier: earlier, later: later, to: "\(debug)/\(folder.lastPathComponent)-\(second).png")
            }
        }
        guard !results.isEmpty else { continue }
        let rate = results.map { AdaptiveFrameRate.frameRate(for: $0, backingScale: 2, cap: 30) }.max() ?? 30
        let detail = results.map { result in
            String(format: "%.0f/%.0f(%d,%d,%d)", result.speed, result.fadeRate, result.movingBlocks,
                   result.warpingBlocks, result.fadingBlocks)
        }.joined(separator: " ")
        rows.append((folder.lastPathComponent, gpu.reduce(0, +) / Double(gpu.count), rate, detail))
        print(String(format: "%-12@ %2d 帧  GPU %5.2f ms  速度（像素/秒）/ 明暗（级/秒）（挪动、变形、明暗块数）%@", folder.lastPathComponent, rate,
                     rows.last!.gpu, detail))
    }
    var counts: [Int: Int] = [:]
    for row in rows { counts[row.rate, default: 0] += 1 }
    let before = rows.reduce(0) { $0 + $1.gpu * 30 }
    let after = rows.reduce(0) { $0 + $1.gpu * Double($1.rate) }
    print("动态场景 \(rows.count) 个：" + counts.sorted { $0.key < $1.key }.map { "\($0.key) 帧 \($0.value) 个" }
        .joined(separator: "、"))
    print(String(format: "GPU（每秒合计，按 30 帧 → 自动帧率）%.0f → %.0f ms（省 %.0f%%）", before, after,
                 100 * (1 - after / max(before, 1))))
    let sortedTimes = estimateTimes.sorted()
    if !sortedTimes.isEmpty {
        print(String(format: "比两帧的 CPU 时间：中位 %.1f ms，最长 %.1f ms（%d 次）", sortedTimes[sortedTimes.count / 2],
                     sortedTimes.last!, sortedTimes.count))
    }
    return 0
}

/// 诊断图：后一帧的亮度图上按块着色——绿 = 整块挪动、紫 = 形状在变（越亮越快）、红 = 顶到搜索范围、蓝 = 只是明暗在变
private func writeBlockMap(earlier: LumaFrame, later: LumaFrame, to path: String) {
    guard let blocks = MotionEstimator.blocks(from: earlier, to: later) else { return }
    let width = later.width, height = later.height
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for index in 0..<(width * height) {
        let value = later.pixels[index] / 2
        rgba[index * 4] = value; rgba[index * 4 + 1] = value; rgba[index * 4 + 2] = value
    }
    for block in blocks where block.kind != .still {
        let color: (UInt8, UInt8, UInt8) = switch block.kind {
        case .fading: (40, 80, 255)
        case .warping: (UInt8(min(255, 80 + block.shift * 40)), 0, UInt8(min(255, 80 + block.shift * 40)))
        default: block.atEdge ? (255, 40, 40) : (0, UInt8(min(255, 80 + block.shift * 40)), 0)
        }
        for y in block.y..<(block.y + MotionEstimator.block) {
            for x in block.x..<(block.x + MotionEstimator.block) {
                let index = (y * width + x) * 4
                rgba[index] = UInt8((Int(rgba[index]) + Int(color.0)) / 2)
                rgba[index + 1] = UInt8((Int(rgba[index + 1]) + Int(color.1)) / 2)
                rgba[index + 2] = UInt8((Int(rgba[index + 2]) + Int(color.2)) / 2)
            }
        }
    }
    guard let context = CGContext(
        data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
