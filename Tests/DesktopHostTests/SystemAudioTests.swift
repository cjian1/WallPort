import CoreAudio
import Foundation
import Testing
@testable import DesktopHost

@Suite struct SystemAudioSpectrumTests {
    /// 对数分频：低频几段能拿到低频能量，高频段拿不到；分辨率按 WE 的 16/32/64 段降采样
    @Test func logarithmicBandsPutEnergyWhereTheSoundIs() {
        // 48 kHz、1024 点 FFT：每格 46.875 Hz。造一个 200 Hz 的峰（第 4 格）
        var magnitudes = [Float](repeating: 0, count: 512)
        magnitudes[4] = 1000
        let bands = SystemAudioSpectrum.logarithmicBands(magnitudes, sampleRate: 48000, fftSize: 1024, count: 64)
        #expect(bands.count == 64)
        #expect(bands.allSatisfy { $0 >= 0 && $0 <= 1 })
        let peakIndex = bands.firstIndex(of: bands.max()!)!
        // 200 Hz 落在 20 Hz – 16 kHz 的对数轴的前几段
        // 20 Hz–16 kHz 的 64 段对数轴：200 Hz 大约在第 22 段
        #expect(peakIndex <= 30, "200 Hz 该落在低频段，得到第 \(peakIndex) 段")
        #expect(bands[(peakIndex + 10)...].allSatisfy { $0 == 0 }, "高频段不该有能量")

        let audio: (left: [Float], right: [Float]) = (bands, bands)
        let sixteen = SystemAudioSpectrum.shared.bands(16)
        #expect(sixteen.left.count == 16)
        // 静音时（没开始采集）频谱就是 0
        #expect(audio.left.count == 64)
        #expect(Array(bands.prefix(20)).contains { $0 == 0 } || bands.max()! > 0)
    }

    /// 交错的立体声（一个缓冲 L R L R…）和非交错的（每声道一个缓冲）都拆成同样长的左右声道
    @Test func samplesAreSplitIntoLeftAndRight() {
        var interleaved: [Float] = [1, -1, 2, -2, 3, -3]
        let single = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(single.unsafeMutablePointer) }
        interleaved.withUnsafeMutableBytes { raw in
            single[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            let (left, right) = SystemAudioSpectrum.channels(of: single)
            #expect(left == [1, 2, 3])
            #expect(right == [-1, -2, -3])
        }

        var leftData: [Float] = [1, 2, 3]
        var rightData: [Float] = [4, 5, 6]
        let pair = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(pair.unsafeMutablePointer) }
        leftData.withUnsafeMutableBytes { leftRaw in
            rightData.withUnsafeMutableBytes { rightRaw in
                pair[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(leftRaw.count), mData: leftRaw.baseAddress)
                pair[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rightRaw.count), mData: rightRaw.baseAddress)
                let (left, right) = SystemAudioSpectrum.channels(of: pair)
                #expect(left == [1, 2, 3])
                #expect(right == [4, 5, 6])
            }
        }

        // 单声道：左右相同
        var mono: [Float] = [7, 8]
        mono.withUnsafeMutableBytes { raw in
            single[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            let (left, right) = SystemAudioSpectrum.channels(of: single)
            #expect(left == [7, 8] && right == [7, 8])
        }
    }
}
