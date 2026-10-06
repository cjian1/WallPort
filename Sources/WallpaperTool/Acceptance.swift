import CoreGraphics
import Foundation
import ImageIO
import Metal
import SceneRenderer
import UniformTypeIdentifiers
import WallpaperFormats
import WallpaperLibrary

/// M6 验收：给语料里的每个场景一个可复现的「正常 / 不正常」判定，汇总通过率。
///
///     WallpaperTool acceptance <目录> <WE 自带素材目录> <输出目录> [宽 高]
///
/// 判定口径（写进 docs/M6-验收清单.md）：
/// 1. 能构建、能渲染 0 秒和 1.5 秒两帧，没有报错；
/// 2. `unsupported` 里除了白名单（写着证据的豁免）以外没有别的项——这一条是重点：
///    像 general.zoom / 视差 / 重力这种「解析层面就没读」的整场景特性，靠 SceneFeatureCoverage
///    补进 `unsupported`，不然通过率会虚高成满分；
/// 3. 有动画的场景两帧要真的不一样（自动帧率定 20/24 帧的前提）；
/// 4. 会跟鼠标的场景，指针在左在右画面要不一样（视差、跟鼠标的粒子 / 特效）；
/// 5. 取景自检：按屏幕比例渲染的和按画布比例渲染后取中间那一块要比得上（屏幕比例不同时画面没错位）。
///
/// 渲染出的 PNG 是壁纸作者的内容，只能放在仓库外面；这里默认也存一份供人工抽查。
///
/// 白名单（豁免）是**类别级**的，逐条给证据，不允许按场景放行：
/// - 「脚本驱动的字段（按静态值处理）」以及 `problems` 里的 `Attempted to assign to readonly property`：
///   语料里这几个场景把「拖动位置」脚本挂在了 `visible` 上，**WE 自己也会报同样的错**、同样按静态值处理；
/// - 「开场淡入（camerafade，未实现）」：WE 加载时会从黑色淡进来，差异只在开头 ≤ 2 秒；场景文件里没有时长参数，
///   没有 WE 参照就复现不了，先记为已知偏差。
enum Acceptance {
    /// 判定为「豁免」的类别（字符串前缀匹配）
    static let exemptPrefixes = [
        "脚本驱动的字段（按静态值处理）",
        "开场淡入（camerafade，未实现）",
        "LED 联动（ledsource，未实现）",
    ]
    /// `problems` 里认定为豁免的（WE 也这样）
    static let exemptProblemMarkers = ["Attempted to assign to readonly property"]

    /// 两帧差异小于它就算「有动画却不动」
    static let motionThreshold = 0.05
    /// 量画面动不动用的时间点：只比 0 秒和 1.5 秒会漏掉"几秒才换一次"的幻灯片
    static let motionTimes: [Float] = [0, 1.5, 6, 12]
    /// 会跟鼠标的场景，左右指针的画面差异小于它就算「没跟上鼠标」。视差是渐变效果，门槛比动画低
    static let pointerThreshold = 0.02
    /// 取景自检的上限。按屏幕比例和按画布比例渲染本来就不会逐像素一样（文字防出界、只在内容附近算的特效、
    /// 复制的背景……），所以这里只抓**明显错位**的；细一点的差异走 framing-check 单独看
    static let framingMeanLimit = 6.0
    static let framingPercentLimit = 30.0

    struct Verdict: Codable {
        var id: String
        var title: String
        var rating: String?
        var pass: Bool
        var reasons: [String]
        var exemptions: [String]
        /// 渲染器报告的暂不支持 / 问题（原样存下来）
        var unsupported: [String]
        var problems: [String]
        var animated: Bool
        var motionDifference: Double
        var followsPointer: Bool
        var pointerDifference: Double
        var framingMean: Double
        var framingPercent: Double
        var previewDifference: Double
        var previewFlippedDifference: Double
        var buildSeconds: Double
    }

    struct Summary: Codable {
        var total: Int
        var passed: Int
        var passRate: Double
        var failed: [String]
        var exemptOnly: [String]
        var targetSize: [Int]
        var generatedAt: String
    }
}

func acceptance(in directory: String, assets: URL, output: String, width: Int, height: Int) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    let outputRoot = URL(fileURLWithPath: output, isDirectory: true)
    let images = outputRoot.appendingPathComponent("images", isDirectory: true)
    try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var verdicts: [Acceptance.Verdict] = []
    for folder in folders {
        guard let project = try? WallpaperProject(folder: folder), project.kind == .scene else { continue }
        verdicts.append(measure(project: project, assets: assets, device: device, width: width, height: height, images: images))
    }

    let passed = verdicts.filter(\.pass).count
    let rate = verdicts.isEmpty ? 0 : Double(passed) / Double(verdicts.count)
    let summary = Acceptance.Summary(
        total: verdicts.count, passed: passed, passRate: rate,
        failed: verdicts.filter { !$0.pass }.map(\.id),
        exemptOnly: verdicts.filter { $0.pass && !$0.exemptions.isEmpty }.map(\.id),
        targetSize: [width, height],
        generatedAt: ISO8601DateFormatter().string(from: Date()))

    writeJSON(verdicts, to: outputRoot.appendingPathComponent("verdicts.json"))
    writeJSON(summary, to: outputRoot.appendingPathComponent("summary.json"))
    writeMarkdownReport(verdicts, summary: summary, to: outputRoot.appendingPathComponent("summary.md"))

    print("验收：\(passed) / \(verdicts.count) 正常（\(String(format: "%.1f", rate * 100))%）"
        + "，屏幕 \(width)×\(height)")
    if !summary.failed.isEmpty {
        print("不正常（\(summary.failed.count)）：")
        for verdict in verdicts where !verdict.pass {
            print("  ✗ \(verdict.id)  \(verdict.reasons.joined(separator: "；"))")
        }
    }
    print("结果在 \(outputRoot.path)（含壁纸作者的内容，不要放进仓库）")
    return rate >= 0.85 ? 0 : 1
}

// MARK: - 单个场景

private func measure(
    project: WallpaperProject, assets: URL, device: any MTLDevice, width: Int, height: Int, images: URL
) -> Acceptance.Verdict {
    var verdict = Acceptance.Verdict(
        id: project.folder.lastPathComponent, title: project.title, rating: project.rating?.rawValue,
        pass: false, reasons: [], exemptions: [], unsupported: [], problems: [],
        animated: false, motionDifference: 0, followsPointer: false, pointerDifference: 0,
        framingMean: 0, framingPercent: 0, previewDifference: -1, previewFlippedDifference: -1,
        buildSeconds: 0)

    let renderer: SceneRenderer
    let scene: SceneDescription?
    let started = Date()
    do {
        let package = try ScenePackage(contentsOf: project.folder.appendingPathComponent("scene.pkg"))
        scene = try? SceneDescription(json: package.contents(of: "scene.json") ?? Data())
        renderer = try SceneRenderer(
            device: device, package: package, assets: assets, targetSize: SIMD2(Float(width), Float(height)),
            userProperties: project.propertyValuesJSON(overrides: [:]))
    } catch {
        verdict.reasons.append("构建失败：\(error.localizedDescription)")
        return verdict
    }
    // 这个场景**该**不該跟着鼠标动：打开视差、而且有图层真的设了非 0 的视差深度。
    // 只有 X 方向有深度、或只有 Y 方向有深度的都有，所以下面两个采样点在对角线上（两个方向一起推）
    let parallaxExpected = scene.map { scene in
        scene.cameraEffects.parallaxEnabled
            && scene.objects.contains { $0.isVisible && ($0.parallaxDepth.x != 0 || $0.parallaxDepth.y != 0) }
    } ?? false
    verdict.buildSeconds = Date().timeIntervalSince(started)

    // 渲染两帧：构建能过不代表画得出来
    let small = 320
    let smallHeight = max(1, Int((Double(small) * Double(height) / Double(max(width, 1))).rounded()))
    var frames: [CGImage] = []
    do {
        for time in Acceptance.motionTimes {
            frames.append(try renderer.renderImage(width: small, height: smallHeight, time: time))
        }
    } catch {
        verdict.reasons.append("渲染失败：\(error.localizedDescription)")
        return verdict
    }
    // 画面动不动：几个时间点里差得最多的那一对
    for index in frames.indices {
        for other in frames.index(after: index)..<frames.count {
            verdict.motionDifference = max(
                verdict.motionDifference, meanDifference(frames[index], frames[other], flipFirst: false, size: 128))
        }
    }
    verdict.animated = verdict.motionDifference > Acceptance.motionThreshold
    verdict.followsPointer = renderer.followsPointerPosition
    if parallaxExpected {
        do {
            let left = try renderer.renderImage(width: small, height: smallHeight, time: 1.5, pointer: SIMD2(0.2, 0.2))
            let right = try renderer.renderImage(width: small, height: smallHeight, time: 1.5, pointer: SIMD2(0.8, 0.8))
            verdict.pointerDifference = meanDifference(left, right, flipFirst: false, size: 128)
        } catch {
            verdict.reasons.append("跟鼠标的渲染失败：\(error.localizedDescription)")
        }
    }
    verdict.unsupported = renderer.unsupported.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
    verdict.problems = renderer.problems

    // 取景自检：屏幕比例 vs 画布比例，和 framing-check 同一套。
    // 作者把画布留得比内容大时（fillBox）取景本来就故意不一样，跳过
    if renderer.fillBox == nil, let (mean, percent) = framingDifference(renderer: renderer, width: width, height: height) {
        verdict.framingMean = mean
        verdict.framingPercent = percent
    }
    // 和项目自带 preview.jpg 的相似度：软信号，只记录不判定
    if let preview = project.preview.flatMap(loadCGImage) {
        let previewWidth = min(256, preview.width)
        let previewHeight = max(1, Int((Double(previewWidth) * Double(preview.height) / Double(max(preview.width, 1))).rounded()))
        if let render = try? renderer.renderImage(width: previewWidth, height: previewHeight, time: 5) {
            verdict.previewDifference = meanDifference(render, preview, flipFirst: false, size: 32)
            verdict.previewFlippedDifference = meanDifference(render, preview, flipFirst: true, size: 32)
        }
    }

    // 判定
    for entry in verdict.unsupported {
        if Acceptance.exemptPrefixes.contains(where: { entry.hasPrefix($0) }) {
            verdict.exemptions.append("暂不支持·豁免 \(entry)")
        } else {
            verdict.reasons.append("暂不支持：\(entry)")
        }
    }
    for problem in verdict.problems {
        if Acceptance.exemptProblemMarkers.contains(where: { problem.contains($0) }) {
            verdict.exemptions.append("问题·豁免 \(problem)")
        } else {
            verdict.reasons.append("问题：\(problem)")
        }
    }
    // 只有"不用脚本、自己就随时间变"的内容才要求必须动；纯脚本驱动的（时钟默认隐藏、幻灯片还没翻页）不判
    if renderer.animatesOverTime, !verdict.animated {
        verdict.reasons.append(String(format: "有动画却不动（两帧差异 %.3f）", verdict.motionDifference))
    }
    if parallaxExpected, verdict.pointerDifference <= Acceptance.pointerThreshold {
        verdict.reasons.append(String(format: "跟鼠标却不跟（鼠标差异 %.3f）", verdict.pointerDifference))
    }
    if verdict.framingMean > Acceptance.framingMeanLimit || verdict.framingPercent > Acceptance.framingPercentLimit {
        verdict.reasons.append(String(format: "取景不对（平均差 %.2f，变化像素 %.1f%%）", verdict.framingMean, verdict.framingPercent))
    }
    verdict.pass = verdict.reasons.isEmpty

    // 存两张图供人工抽查（只存 Everyone 分级，避免把不适合查看的内容落到盘上）
    if project.rating == nil || project.rating == .everyone {
        try? writePNG(frames[1], to: images.appendingPathComponent("\(verdict.id)-t1.5.png"))
    }
    return verdict
}

/// 屏幕比例渲染 vs 画布比例渲染取中间：两张应当差不多（和 framing-check 同一套算法）
private func framingDifference(
    renderer: SceneRenderer, width: Int, height: Int
) -> (mean: Double, percent: Double)? {
    guard width > 0, height > 0,
          let screen = try? renderer.renderImage(width: width, height: height, time: 2)
    else { return nil }
    let aspect = renderer.canvasSize.x / max(renderer.canvasSize.y, 1)
    let wide = aspect >= Float(width) / Float(height)
    let fullWidth = wide ? Int((Float(height) * aspect).rounded()) : width
    let fullHeight = wide ? height : Int((Float(width) / aspect).rounded())
    guard fullWidth > 0, fullHeight > 0, fullWidth <= 16384, fullHeight <= 16384,
          let full = try? renderer.renderImage(width: fullWidth, height: fullHeight, time: 2),
          let middle = full.cropping(to: CGRect(
              x: (fullWidth - width) / 2, y: (fullHeight - height) / 2, width: width, height: height))
    else { return nil }
    let result = imageDifference(screen, middle)
    return (result.mean, result.changedPercent)
}

// MARK: - 输出

private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value) {
        try? data.write(to: url, options: .atomic)
    }
}

private func writeMarkdownReport(_ verdicts: [Acceptance.Verdict], summary: Acceptance.Summary, to url: URL) {
    var lines: [String] = []
    lines.append("# M6 验收报告（自动生成）")
    lines.append("")
    lines.append("屏幕尺寸 \(summary.targetSize[0])×\(summary.targetSize[1])，生成于 \(summary.generatedAt)")
    lines.append("")
    lines.append("- 场景总数：\(summary.total)")
    lines.append("- 正常：\(summary.passed)（\(String(format: "%.1f", summary.passRate * 100))%）")
    lines.append("- 门槛：85%（\(Int((Double(summary.total) * 0.85).rounded(.up))) 个）")
    lines.append("")
    lines.append("## 不正常的场景")
    lines.append("")
    if summary.failed.isEmpty {
        lines.append("（没有）")
    } else {
        lines.append("| 编号 | 原因 |")
        lines.append("|---|---|")
        for verdict in verdicts where !verdict.pass {
            lines.append("| \(verdict.id) | \(verdict.reasons.joined(separator: "；")) |")
        }
    }
    lines.append("")
    lines.append("## 只靠豁免通过的场景")
    lines.append("")
    if summary.exemptOnly.isEmpty {
        lines.append("（没有）")
    } else {
        for verdict in verdicts where verdict.pass && !verdict.exemptions.isEmpty {
            lines.append("- \(verdict.id)：\(verdict.exemptions.joined(separator: "；"))")
        }
    }
    lines.append("")
    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func loadCGImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
