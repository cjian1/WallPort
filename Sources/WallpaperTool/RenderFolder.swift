import Foundation
import Metal
import DesktopHost
import SceneRenderer
import WallpaperFormats

/// 渲染一个没打包的场景文件夹（例如 WE 自带的 scenes/particleelementpreviews/*），
/// 按给定的几个时间点各存一张 PNG。文件夹在内存里临时打成 pkg，和真实项目走同一条渲染路径。
func renderFolder(_ folder: String, assets: URL, output: String, times: [Float]) -> Int32 {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("✗ 没有可用的 Metal 设备")
        return 1
    }
    do {
        let package = try ScenePackage(data: packFolder(URL(fileURLWithPath: folder, isDirectory: true)))
        // TARGET_WIDTH / TARGET_HEIGHT 按指定的屏幕尺寸构建（特效缓冲按屏幕尺寸定），用来估算桌面上的
        // 显存占用；给了 TARGET_HEIGHT 就按同一尺寸出图，看到的就是屏幕上真正显示的样子（含铺满裁切）
        let targetWidth = ProcessInfo.processInfo.environment["TARGET_WIDTH"].flatMap(Float.init) ?? 1280
        let targetHeight = ProcessInfo.processInfo.environment["TARGET_HEIGHT"].flatMap(Float.init)
            ?? targetWidth * 9 / 16
        let before = device.currentAllocatedSize
        // USER_PROPERTIES='{"名字": 值}'：代入用户属性（脚本里读 engine.userProperties 的场景要用）
        let userProperties = ProcessInfo.processInfo.environment["USER_PROPERTIES"].map { Data($0.utf8) }
        // HIDDEN_ELEMENTS='particles:Ember,effect:nitro'：和设置面板"显示内容"里关掉这几项一样（键见 SceneElements）
        let hiddenElements = Set(
            (ProcessInfo.processInfo.environment["HIDDEN_ELEMENTS"] ?? "").split(separator: ",").map(String.init))
        let renderer = try SceneRenderer(
            device: device, package: package, assets: assets, targetSize: SIMD2(targetWidth, targetHeight),
            userProperties: userProperties, hiddenElements: hiddenElements)
        // SYSTEM_AUDIO=1 时接上系统音频（看音频律动的效果）；默认不采集，出图结果可复现
        if ProcessInfo.processInfo.environment["SYSTEM_AUDIO"] != nil, SystemAudioSpectrum.shared.start() {
            renderer.audioSpectrum = SystemAudioSpectrum.shared
        }
        // FAKE_AUDIO=0.6：不采集，用一段固定的频谱（低频高、高频低，最大值是给定的数），看可视化柱子画在哪
        if let level = ProcessInfo.processInfo.environment["FAKE_AUDIO"].flatMap(Float.init) {
            let spectrum = SystemAudioSpectrum()
            let bands = (0..<64).map { level * (1 - Float($0) / 80) }
            spectrum.simulate(left: bands, right: bands)
            renderer.audioSpectrum = spectrum
        }
        print(String(format: "构建后显存 %.0f MB", Double(device.currentAllocatedSize - before) / 1_048_576))
        let aspect = renderer.canvasSize.y / renderer.canvasSize.x
        let screenShot = ProcessInfo.processInfo.environment["TARGET_HEIGHT"] != nil
        let width = screenShot ? Int(targetWidth) : 1280
        let height = screenShot ? Int(targetHeight) : Int((Float(width) * aspect).rounded())
        for time in times {
            let image = try renderer.renderImage(width: width, height: height, time: time)
            let file = output.replacingOccurrences(of: ".png", with: "") + String(format: "-t%g.png", time)
            try writePNG(image, to: URL(fileURLWithPath: file))
            print("\(file)：\(renderer.liveParticleCount) 个粒子，显存 \(String(format: "%.0f", Double(device.currentAllocatedSize - before) / 1_048_576)) MB")
        }
        print("画了 \(renderer.drawnLayerCount) 层，特效 \(renderer.renderedEffectCount) 个")
        if ProcessInfo.processInfo.environment["SHOW_MEMORY"] != nil {
            for (name, bytes) in renderer.memorySummary.prefix(25) {
                print(String(format: "  %6.1f MB  ", Double(bytes) / 1_048_576) + name)
            }
            let pool = renderer.bufferPoolStats
            print(String(
                format: "  %6.1f MB  特效缓冲池（同时最多借 %d 张）", Double(pool.heapBytes) / 1_048_576, pool.peakBorrowed))
        }
        if ProcessInfo.processInfo.environment["SHOW_EFFECTS"] != nil {
            renderer.effectSummaries.forEach { print("  · \($0)") }
        }
        let skipped = renderer.unsupported.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        if !skipped.isEmpty { print("暂不支持：\(skipped.joined(separator: "、"))") }
        renderer.problems.forEach { print("✗ \($0)") }
        return 0
    } catch {
        print("✗ \(error.localizedDescription)")
        return 1
    }
}

/// 按 scene.pkg 的结构（见 ScenePackage）把文件夹里的文件打成一个包
private func packFolder(_ root: URL) throws -> Data {
    let base = root.standardizedFileURL.path + "/"
    var files: [(String, Data)] = []
    if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            files.append((String(path.dropFirst(base.count)), try Data(contentsOf: url)))
        }
    }
    var header = Data()
    func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
    u32(8)
    header += Data("PKGV0001".utf8)
    u32(files.count)
    var offset = 0
    for (name, data) in files {
        let bytes = Data(name.utf8)
        u32(bytes.count)
        header += bytes
        u32(offset)
        u32(data.count)
        offset += data.count
    }
    return files.reduce(header) { $0 + $1.1 }
}
