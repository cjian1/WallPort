import AppKit

/// 能出声的壁纸内容：视频、网页、场景里的声音对象。
///
/// 壁纸默认都静音（桌面背景突然出声会吓人一跳），菜单里的"播放壁纸声音"统一打开。
/// 打开后声音仍然跟着播放状态走：壁纸被遮住或被用户暂停时声音也停。
@MainActor
public protocol AudioPlaying: DesktopContent {
    func setAudioEnabled(_ enabled: Bool)
    /// 这个壁纸自己的音量（0–1，壁纸设置里调的）；和"出不出声"分开：静音由 setAudioEnabled 管
    func setVolume(_ volume: Float)
}
