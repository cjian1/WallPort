import Accelerate
import CoreAudio
import Foundation

/// 系统音频的频谱：WE 的"跟着音乐律动"（可视化条、随音乐脉动的特效、`engine.registerAudioBuffers`）都要它。
///
/// 采集用 Core Audio 的**进程 tap**（macOS 14.2+）：`CATapDescription` 做一个"排除若干进程"的全局
/// 立体声 tap（即系统输出），把它挂到一个私有聚合设备上，用 IOProc 读样本。这样不需要屏幕录制权限，
/// 只会在第一次使用时弹一次"系统音频录制"的授权（打包的 App 要在 Info.plist 里写
/// `NSAudioCaptureUsageDescription`）。只有用到音频律动的场景在播放时才采集（见 `acquire` / `release`）。
///
/// 样本攒够一窗（1024 点）就做一次 FFT，按 WE 的 16/32/64 段做**对数分频**（WE 的
/// `g_AudioSpectrum16Left[16]` 这类 uniform 和脚本接口的 AudioBuffers 都是这么分的），
/// 再按时间做一点平滑，免得柱子抖得看不清。
public final class SystemAudioSpectrum: @unchecked Sendable {
    /// 一窗 FFT 的采样数
    static let window = 1024
    /// 平滑系数：新值占多少（越小越稳）
    static let smoothing: Float = 0.35

    private let lock = NSLock()
    private var _left = [Float](repeating: 0, count: 64)
    private var _right = [Float](repeating: 0, count: 64)
    private var _isRunning = false
    /// 采集不可用时的原因（没授权、系统太旧、没有输出设备……）
    public private(set) var problem: String?

    deinit { stop() }

    public init() {}

    /// 全局共享的一份：桌面、锁屏、离屏工具都用同一个采集（多处同时建 tap 会互相打断）
    public static let shared = SystemAudioSpectrum()

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    /// 64 段频谱（WE 的分辨率之一；其余分辨率由它降采样得到）
    public var bands: (left: [Float], right: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        return (_left, _right)
    }

    /// 开发工具用：不采集、直接给定 64 段频谱（离线出图时看音乐可视化的柱子画在哪里、多高）
    public func simulate(left: [Float], right: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        _left = (0..<64).map { left.indices.contains($0) ? left[$0] : 0 }
        _right = (0..<64).map { right.indices.contains($0) ? right[$0] : 0 }
    }

    /// WE 的 16 / 32 / 64 段频谱：脚本接口和特效 uniform 用这几个
    public func bands(_ count: Int) -> (left: [Float], right: [Float]) {
        let (left, right) = bands
        guard count != left.count, count > 0 else { return (left, right) }
        func resample(_ values: [Float]) -> [Float] {
            (0..<count).map { index in
                let start = index * values.count / count
                let end = max(start + 1, (index + 1) * values.count / count)
                return values[start..<end].reduce(0, +) / Float(end - start)
            }
        }
        return (resample(left), resample(right))
    }

    // MARK: - 采集

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var fft: FFTSetup?
    private var windowValues: [Float] = []
    /// 还没分析的样本（左、右声道，个数始终相同）
    private var samples: [Float] = []
    private var rightSamples: [Float] = []
    private let fftLog2 = vDSP_Length(10)   // 1024 点

    /// 正在用频谱的场景个数：第一个用的时候开始采集，最后一个不用了就停（采集期间系统会亮
    /// "正在录制系统音频"的指示，所以不用的时候不能一直开着）
    private var users = 0

    /// 登记一个使用者；需要时开始采集。返回采集是否在跑
    @discardableResult
    public func acquire() -> Bool {
        lock.lock()
        users += 1
        lock.unlock()
        return start()
    }

    /// 注销一个使用者；没人用了就停止采集
    public func release() {
        lock.lock()
        users = max(0, users - 1)
        let idle = users == 0
        lock.unlock()
        if idle { stop() }
    }

    /// 开始采集；失败时返回 false 并留下 `problem`（界面照常跑，频谱保持 0）
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        guard #available(macOS 14.2, *) else {
            problem = String(localized: "系统音频采集需要 macOS 14.2 或更新版本")
            return false
        }
        do {
            try startCapture()
            lock.lock()
            _isRunning = true
            lock.unlock()
            return true
        } catch {
            problem = error.localizedDescription
            stop()
            return false
        }
    }

    public func stop() {
        guard #available(macOS 14.2, *) else { return }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        lock.lock()
        _isRunning = false
        samples = []
        rightSamples = []
        _left = [Float](repeating: 0, count: 64)
        _right = [Float](repeating: 0, count: 64)
        lock.unlock()
    }

    @available(macOS 14.2, *)
    private func startCapture() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [AudioObjectID]())
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            throw AudioError(String(localized: "创建系统音频 tap 失败（多半是没授权系统音频录制）"))
        }
        tapID = tap

        let aggregateUID = "MacWallpaper-Audio-\(UUID().uuidString)"
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MacWallpaper 音频",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: 0,
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                ]
            ],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
            throw AudioError("创建聚合设备失败")
        }
        aggregateID = device

        // tap 的格式（采样率、声道数）
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else {
            throw AudioError("读不到系统音频的格式")
        }
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48000
        fft = vDSP_create_fftsetup(fftLog2, FFTRadix(kFFTRadix2))
        windowValues = [Float](repeating: 0, count: Self.window)
        vDSP_hann_window(&windowValues, vDSP_Length(Self.window), Int32(vDSP_HANN_NORM))

        let queue = DispatchQueue(label: "MacWallpaper.audio")
        var status = noErr
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            self.append(buffers)
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, queue, block)
        guard status == noErr, let ioProcID else { throw AudioError("装不上音频回调") }
        guard AudioDeviceStart(device, ioProcID) == noErr else { throw AudioError("启动音频采集失败") }
    }

    private var sampleRate: Double = 48000

    /// IOProc 拿到的样本：拆成左右声道，攒够一窗就分析一次
    private func append(_ buffers: UnsafeMutableAudioBufferListPointer) {
        let (left, right) = Self.channels(of: buffers)
        guard !left.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: left)
        rightSamples.append(contentsOf: right)
        // 两个声道的样本数始终相同；一次回调带来好几窗时只分析最新的一窗
        while samples.count >= Self.window * 2 {
            samples.removeFirst(Self.window)
            rightSamples.removeFirst(Self.window)
        }
        if samples.count >= Self.window {
            analyse(Array(samples.prefix(Self.window)), right: Array(rightSamples.prefix(Self.window)))
            samples.removeFirst(Self.window)
            rightSamples.removeFirst(Self.window)
        }
    }

    /// 把一次回调的样本拆成左右声道（个数相同）。tap 的格式可能是交错的（一个缓冲里 L R L R…），
    /// 也可能每个声道一个缓冲；单声道时左右相同
    static func channels(of buffers: UnsafeMutableAudioBufferListPointer) -> (left: [Float], right: [Float]) {
        guard let first = buffers.first, let data = first.mData else { return ([], []) }
        if buffers.count >= 2, let second = buffers[1].mData {
            let count = min(Int(first.mDataByteSize), Int(buffers[1].mDataByteSize)) / MemoryLayout<Float>.size
            return (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)),
                    Array(UnsafeBufferPointer(start: second.assumingMemoryBound(to: Float.self), count: count)))
        }
        let channelCount = max(1, Int(first.mNumberChannels))
        let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channelCount
        let frames = data.assumingMemoryBound(to: Float.self)
        let rightOffset = min(1, channelCount - 1)
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            left[frame] = frames[frame * channelCount]
            right[frame] = frames[frame * channelCount + rightOffset]
        }
        return (left, right)
    }

    /// 一窗样本 → 64 段对数频谱
    private func analyse(_ left: [Float], right: [Float]) {
        guard let fft else { return }
        let half = Self.window / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: Self.window)
        var magnitudes = [Float](repeating: 0, count: half)
        var leftBands = [Float](repeating: 0, count: 64)
        var rightBands = [Float](repeating: 0, count: 64)
        for (index, channel) in [left, right].enumerated() {
            vDSP_vmul(channel, 1, windowValues, 1, &windowed, 1, vDSP_Length(Self.window))
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { pointer in
                            vDSP_ctoz(pointer, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            var bands = Self.logarithmicBands(
                magnitudes, sampleRate: Float(sampleRate), fftSize: Self.window, count: 64)
            for index in 0..<64 { bands[index] = min(1, bands[index]) }
            if index == 0 { leftBands = bands } else { rightBands = bands }
        }
        let oldLeft = _left, oldRight = _right
        for index in 0..<64 {
            _left[index] = oldLeft[index] + (leftBands[index] - oldLeft[index]) * Self.smoothing
            _right[index] = oldRight[index] + (rightBands[index] - oldRight[index]) * Self.smoothing
        }
    }

    /// 把线性频谱按对数分频成 `count` 段（20 Hz – 16 kHz），每段取峰值再归一化到 0–1
    static func logarithmicBands(_ magnitudes: [Float], sampleRate: Float, fftSize: Int, count: Int) -> [Float] {
        let bins = magnitudes.count
        guard bins > 1, count > 0 else { return [Float](repeating: 0, count: count) }
        let low: Float = 20
        let high = min(16000, sampleRate / 2)
        let binWidth = sampleRate / Float(fftSize)
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let start = low * pow(high / low, Float(index) / Float(count))
            let end = low * pow(high / low, Float(index + 1) / Float(count))
            let first = max(1, Int(start / binWidth))
            let last = min(bins - 1, max(first, Int(end / binWidth) - 1))
            var peak: Float = 0
            for bin in first...last { peak = max(peak, magnitudes[bin]) }
            // 归一化：FFT 的幅度和窗长、汉宁窗的能量有关，除一个经验常数再开方压一下动态范围
            result[index] = min(1, sqrt(peak / Float(fftSize) * 8))
        }
        return result
    }

    struct AudioError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
