import AVFoundation
import CoreGraphics
import CoreVideo
import DesktopHost
import Metal

/// 视频纹理（`.tex` 里装的是 MP4）：按场景时间取帧，传给贴图。
///
/// **解码在后台线程**：渲染每帧报一下要的时间，后台用 `AVAssetReader` 顺序往前解，提前解好几帧放着；
/// 桌面上渲染只取现成的帧、从不等（`texture(at:waits: false)`）——解码跟不上时视频停在上一帧，App 不卡。
/// 原来在渲染线程（主线程）上同步等解码器：4000×2400、60 帧的视频在"不限制帧率"下主线程被占满，
/// 每秒只画出 5 帧，整个 App 跟着卡。离线出图要准确的那一帧，照样等（`waits: true`）。
///
/// 时间按"连续时间"算（第几圈 × 时长 + 帧在视频里的时间）：解到结尾马上接着解下一圈的开头，
/// 循环回到开头时不用在那一刻重建 reader。时间倒退（场景重建、时间回绕）、或者落后太多时，
/// 在后台从要的时间重新开始读。
///
/// 解出来的帧**不拷贝**：让解码器直接按需要的尺寸输出（比屏幕上用到的大时在解码时就缩小），
/// 输出放在 IOSurface 上，用 `CVMetalTextureCache` 直接包成 GPU 贴图。
/// 时长和视频轨用异步接口在后台读，读到之前 `texture(at:)` 返回 nil，调用方继续用第一帧。
final class VideoTexture: @unchecked Sendable {
    private let url: URL
    private let device: any MTLDevice
    private let maxDimension: Int
    private let condition = NSCondition()
    private let decodeQueue = DispatchQueue(label: "SceneRenderer.VideoTexture", qos: .userInitiated)

    // 后台读到的（加锁）
    /// 时长（秒）和视频轨；nil 表示还没读到（或读不出来）
    private var duration: Double?
    private var asset: AVURLAsset?
    private var track: AVAssetTrack?
    /// 视频画面的原始尺寸；按它和 `maxDimension` 算让解码器输出多大
    private var naturalSize: CGSize?
    /// 一帧多长（秒），按视频的标称帧率
    private var frameDuration = 1.0 / 30

    // 渲染和解码两边共用（加锁）
    private struct Frame {
        /// 连续时间（秒）
        let time: Double
        let texture: any MTLTexture
        /// 包装着解码器的缓冲：留着它，解码器的缓冲池就不会拿这块去装新帧
        let wrapped: CVMetalTexture?
    }
    /// 解好、还没轮到的帧（时间从小到大）
    private var ready: [Frame] = []
    /// 正在显示的帧，和 GPU 可能还在读的前两帧（屏幕最多两帧在路上）
    private var current: Frame?
    private var recent: [Frame] = []
    /// 渲染最近要的时间（连续时间）
    private var requested: Double = 0
    private var lastRequested: Double?
    /// 时间倒退或者要从别处重新读时加一：解码线程看到变了就按 `requested` 重建 reader
    private var generation = 0
    private var decoding = false
    /// 读不出来了（reader 建不起来）：不再尝试
    private var failed = false

    // 只在解码线程上碰
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var readerGeneration = -1
    /// 这个 reader 解的是第几圈
    private var readerLoop = 0
    /// 这个 reader 最近解出的一帧的时间（连续时间）；刚建好还没出帧时是 nil
    private var decodedTime: Double?
    /// 这个 reader 从这一圈的第几秒开始读
    private var readerStart = 0.0
    private var textureCache: CVMetalTextureCache?

    /// 提前解好几帧
    private static let lookahead = 2
    /// 落后超过这么多秒就从要的时间重新读，不一帧帧追
    private static let maximumLag = 0.5

    init?(data: Data, device: any MTLDevice, maxDimension: Int) {
        VideoDecoders.registerSystemDecoders()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macwallpaper-video-\(UUID().uuidString).mp4")
        do { try data.write(to: url) } catch { return nil }
        self.url = url
        self.device = device
        self.maxDimension = maxDimension
        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess { textureCache = cache }
        let asset = AVURLAsset(url: url)
        Task.detached { [weak self] in
            guard let duration = try? await asset.load(.duration), CMTimeGetSeconds(duration) > 0,
                  let track = try? await asset.loadTracks(withMediaType: .video).first
            else { return }
            let size = try? await track.load(.naturalSize)
            let rate = try? await track.load(.nominalFrameRate)
            self?.didLoad(asset, duration: CMTimeGetSeconds(duration), track: track, naturalSize: size, frameRate: rate)
        }
    }

    deinit {
        reader?.cancelReading()
        try? FileManager.default.removeItem(at: url)
    }

    /// 轨道只弱引用它的 asset，所以 asset 本身也要留着
    private func didLoad(
        _ asset: AVURLAsset, duration: Double, track: AVAssetTrack, naturalSize: CGSize?, frameRate: Float?
    ) {
        condition.lock()
        defer { condition.unlock() }
        self.asset = asset
        self.duration = duration
        self.track = track
        self.naturalSize = naturalSize
        if let frameRate, frameRate > 0 { frameDuration = 1 / Double(frameRate) }
    }

    /// 让解码器输出的尺寸：不超过 `maxDimension`，保持比例；不知道原始尺寸时 nil（按原尺寸输出）
    private var outputSize: (width: Int, height: Int)? {
        guard let naturalSize, naturalSize.width != 0, naturalSize.height != 0 else { return nil }
        let width = Int(abs(naturalSize.width).rounded()), height = Int(abs(naturalSize.height).rounded())
        let scale = min(1, Float(maxDimension) / Float(max(width, height, 1)))
        guard scale < 1 else { return nil }
        return (max(1, Int((Float(width) * scale).rounded())), max(1, Int((Float(height) * scale).rounded())))
    }

    /// 场景时间 → 这一时刻的贴图（还没准备好或解不出时返回 nil，调用方继续用上一张）。
    /// `waits` 为 false 时只取已经解好的帧、从不等（桌面上用）；为 true 时解到这一刻为止（离线出图用）
    func texture(at time: Float, waits: Bool = true) -> (any MTLTexture)? {
        condition.lock()
        guard duration != nil, !failed else {
            condition.unlock()
            return nil
        }
        let target = Double(time)
        if let lastRequested, target < lastRequested - 0.001 {
            // 时间倒退：丢掉解好的，从新的时间重新读
            generation += 1
            ready = []
        }
        lastRequested = target
        requested = target
        condition.unlock()
        if waits {
            decodeQueue.sync { fill(waiting: true) }
        } else {
            scheduleDecoding()
        }
        condition.lock()
        defer { condition.unlock() }
        // 轮到的帧：时间不晚于要的时间的最后一帧
        while let next = ready.first, next.time <= target + 0.0005 {
            ready.removeFirst()
            if let current { recent.append(current) }
            if recent.count > 2 { recent.removeFirst() }
            current = next
        }
        return current?.texture
    }

    private func scheduleDecoding() {
        condition.lock()
        let start = !decoding
        decoding = true
        condition.unlock()
        guard start else { return }
        decodeQueue.async { [weak self] in self?.fill(waiting: false) }
    }

    /// 在解码线程上往前解：解到比要的时间提前 `lookahead` 帧（`waiting` 时解到刚过要的时间就停）
    private func fill(waiting: Bool) {
        while true {
            condition.lock()
            guard let duration, let asset, let track, !failed else {
                decoding = false
                condition.unlock()
                return
            }
            let target = requested, generation = generation
            let enough = waiting
                ? ((ready.last?.time ?? current?.time).map { $0 > target } ?? false)
                : ready.filter { $0.time > target }.count >= Self.lookahead
            if enough, generation == readerGeneration {
                decoding = false
                condition.unlock()
                return
            }
            let size = outputSize
            condition.unlock()

            // 时间倒退、刚开始、或者落后太多：从要的时间所在那一圈、那个位置重新读
            let behind = decodedTime.map { target - $0 > Self.maximumLag } ?? false
            if reader == nil || generation != readerGeneration || behind {
                let loop = floor(target / duration)
                guard startReader(asset: asset, track: track, size: size, loop: Int(loop),
                                  from: target - loop * duration, duration: duration)
                else {
                    condition.lock()
                    failed = true
                    decoding = false
                    condition.unlock()
                    return
                }
                readerGeneration = generation
                if behind {
                    condition.lock()
                    ready = []
                    condition.unlock()
                }
            }
            guard let output, let sample = output.copyNextSampleBuffer() else {
                // 这一圈解完了：接着从头解下一圈（在这里就建好，循环回到开头时不用等）。
                // 出错了、或者从头读完一整圈一帧都没有：不再尝试（从快到结尾的地方开始读时没有帧是正常的）
                guard reader?.status == .completed, decodedTime != nil || readerStart > 0,
                      startReader(asset: asset, track: track, size: size, loop: readerLoop + 1, from: 0, duration: duration)
                else {
                    condition.lock()
                    failed = true
                    decoding = false
                    condition.unlock()
                    return
                }
                continue
            }
            let time = Double(readerLoop) * duration + CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            decodedTime = time
            guard let buffer = CMSampleBufferGetImageBuffer(sample), let frame = wrap(buffer, time: time) else { continue }
            condition.lock()
            // 解的时候时间倒退了：这一帧不要
            if generation == self.generation {
                ready.append(frame)
                // 早就过了的帧留一帧就够（给"刚好轮到"用），免得占着解码器的缓冲
                while ready.count > 1, ready[1].time <= requested { ready.removeFirst() }
            }
            condition.unlock()
        }
    }

    /// 在解码线程上建 reader：从第 `loop` 圈的 `start` 秒开始读
    private func startReader(
        asset: AVURLAsset, track: AVAssetTrack, size: (width: Int, height: Int)?, loop: Int, from start: Double,
        duration: Double
    ) -> Bool {
        reader?.cancelReading()
        reader = nil
        output = nil
        guard let created = try? AVAssetReader(asset: asset) else { return false }
        if start > 0 {
            created.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        }
        // 输出放在 IOSurface 上、能直接给 Metal 用；比需要的大时让解码器在解码时就缩小
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        if let size {
            settings[kCVPixelBufferWidthKey as String] = size.width
            settings[kCVPixelBufferHeightKey as String] = size.height
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        trackOutput.alwaysCopiesSampleData = false
        guard created.canAdd(trackOutput) else { return false }
        created.add(trackOutput)
        guard created.startReading() else { return false }
        reader = created
        output = trackOutput
        readerLoop = loop
        readerStart = start
        decodedTime = nil
        return true
    }

    /// 解出来的 BGRA 帧直接包成 BGRA 贴图（采样时 Metal 自己换回 RGBA），不拷贝；包不成时拷一份
    private func wrap(_ buffer: CVPixelBuffer, time: Double) -> Frame? {
        if let textureCache {
            var wrapped: CVMetalTexture?
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            if CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
               let wrapped, let metal = CVMetalTextureGetTexture(wrapped) {
                return Frame(time: time, texture: metal, wrapped: wrapped)
            }
        }
        return copy(buffer).map { Frame(time: time, texture: $0, wrapped: nil) }
    }

    /// 包不成贴图时（没有 IOSurface 之类）的老办法：拷进一张新的 BGRA 贴图（GPU 可能还在读上一张，不能覆盖它）；
    /// 比需要的尺寸大时按最近点缩小，免得整屏视频占用过多显存
    private func copy(_ buffer: CVPixelBuffer) -> (any MTLTexture)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let scale = min(1, Float(maxDimension) / Float(max(width, height, 1)))
        let targetWidth = max(1, Int((Float(width) * scale).rounded()))
        let targetHeight = max(1, Int((Float(height) * scale).rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: targetWidth, height: targetHeight, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let region = MTLRegionMake2D(0, 0, targetWidth, targetHeight)
        if targetWidth == width, targetHeight == height {
            texture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
            return texture
        }
        var pixels = [UInt32](repeating: 0, count: targetWidth * targetHeight)
        for y in 0..<targetHeight {
            let row = base.advanced(by: min(height - 1, y * height / targetHeight) * bytesPerRow)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<targetWidth {
                pixels[y * targetWidth + x] = row[min(width - 1, x * width / targetWidth)]
            }
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: region, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: targetWidth * 4)
        }
        return texture
    }
}
