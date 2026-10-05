# 兼容字体

没有导入 Wallpaper Engine 自带素材时，场景里引用的 WE 自带字体（`fonts/…`）从这里取。打包时
（`scripts/build-app.sh`、`scripts/release.sh`）整个文件夹拷进 `WallPort.app/Contents/Resources/CompatFonts`；
"关于壁坞"里的许可证由 `scripts/make-credits.sh` 从 `licenses/` 生成。对应关系写在
`Sources/SceneRenderer/Compat/CompatFonts.swift`。

原则：许可证允许再分发、能从原作者处取得的，带原字体；否则换成外观相近的开源字体（2026-10-01 下载、比对字形选定）。

| WE 的字体文件 | 带的字体 | 作者 / 来源 | 许可证 |
|---|---|---|---|
| RobotoMono-Regular.ttf | 原字体 RobotoMono-Regular.ttf（v3.001） | The Roboto Mono Project Authors，github.com/googlefonts/RobotoMono | OFL 1.1 |
| NotoSans-Regular.ttf | 原字体 NotoSans-Regular.ttf | Google / Noto，github.com/notofonts | OFL 1.1 |
| Blackout 2 AM.ttf | 原字体 Blackout-2AM.ttf | Tyler Finck / The League of Moveable Type，github.com/theleagueof/blackout | OFL 1.1 |
| Segment7Standard.otf | 原字体 Segment7Standard.otf | Cedric Knight，fontlibrary.org/en/font/segment7 | OFL 1.1 |
| 8bitOperatorPlus8-Regular.ttf | Pixelify Sans | github.com/google/fonts（ofl/pixelifysans） | OFL 1.1 |
| Alcubierre.otf | Quicksand | github.com/google/fonts（ofl/quicksand） | OFL 1.1 |
| Atami-Regular.otf | Poppins SemiBold | github.com/google/fonts（ofl/poppins） | OFL 1.1 |
| CursedTimerUlil-Aznm.ttf | DSEG14 Classic | keshikan，github.com/keshikan/DSEG（v0.46） | OFL 1.1 |
| Lazer84.ttf、summer85.ttf | Knewave | Tyler Finck，github.com/google/fonts（ofl/knewave） | OFL 1.1 |
| Monofur-PK7og.ttf | Victor Mono | github.com/google/fonts（ofl/victormono） | OFL 1.1 |
| kust.ttf | Permanent Marker | Font Diner，github.com/google/fonts（apache/permanentmarker） | Apache 2.0 |
| opensticks.ttf | Share Tech Mono | Carrois Type Design，github.com/google/fonts（ofl/sharetechmono） | OFL 1.1 |
| spincycle_3d_ot.otf | Bungee Shade | David Jonathan Ross，github.com/google/fonts（ofl/bungeeshade） | OFL 1.1 |
| TwemojiMozilla.ttf | 不带：用系统字体，表情由 macOS 的 Apple Color Emoji 补上 | | |

换成替代字体的原因：

- 8-bit Operator+（OFL）：原作者的 DeviantArt 页面已经不在了，取不到原作者发布的文件。
- Monofur（随附说明即可再分发）：原作者的网站早已关闭。
- Atami：许可证禁止再分发。
- Alcubierre、Cursed Timer ULiL、opensticks、Spin Cycle 3D：只写了"免费商用"，没有允许再分发。
- Lazer84、summer85：版权声明为 All Rights Reserved。
- Kust：没有找到许可证。
