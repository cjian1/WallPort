import VideoToolbox

/// 系统自带、但默认不给 AVFoundation 用的视频解码器。
///
/// 创意工坊里有的视频壁纸是装在 MP4 里的 **VP9**（`vp09`），AVFoundation 默认报"无法播放"。
/// macOS 11 起系统自带 VP9 解码器，进程里调一次 `VTRegisterSupplementalVideoDecoderIfAvailable`
/// 登记以后，AVPlayer / AVAssetReader 就能直接播放和解码（本机核对：登记前 isPlayable = false，
/// 登记后 true、第一帧能解出来）。AV1 也一并登记：有硬件解码的机器上系统本来就支持，没有的话这次调用什么也不做。
public enum VideoDecoders {
    private static let registration: Void = {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
    }()

    /// 登记系统的补充解码器；可以反复调用，只有第一次真正生效
    public static func registerSystemDecoders() {
        _ = registration
    }
}
