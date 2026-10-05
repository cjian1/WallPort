# 壁坞 WallPort

在 Mac 上播放兼容 Wallpaper Engine 的动态壁纸——场景、视频、网页三种都支持，壁纸显示在桌面图标下面。Apple 芯片原生。

[**下载最新版**](../../releases/latest) · [English](#english) · [隐私](#隐私) · [从源码构建](#从源码构建) · [MIT 许可证](LICENSE)

> **声明**：壁坞是独立开发的开源软件，**不是 Wallpaper Engine 的官方产品**，与 Wallpaper Engine、Steam、Valve 及其开发者没有关联。
> "Wallpaper Engine""Steam"是其各自权利人的商标。壁坞不提供、不托管任何壁纸，也不包含 Wallpaper Engine 的自带素材；
> 壁纸来自你自己的 Steam 创意工坊订阅，版权属于各自的作者。

## 功能

- 登录 Steam 后同步你在创意工坊订阅的壁纸，也能在 App 里直接浏览、订阅、下载
- 场景壁纸：图层、特效（Wallpaper Engine 的着色器在运行时翻译成 Metal）、粒子、木偶动画、文字和时钟、脚本、声音
- 每块屏幕放不同的壁纸，可以定时轮播；壁纸作者提供的设置（颜色、开关、滑块）可以直接调
- 省电：桌面被窗口挡住、用电池、机器发热时自动降帧或暂停；画面动得慢的场景自动降到 20 / 24 帧
- 锁屏、调度中心时系统壁纸同步成当前画面；退出时恢复你原来的壁纸
- 中文、英文界面

## 下载和安装

**系统要求**：macOS 14.6 或更新版本；Apple 芯片的 Mac（M1 及以后，**不支持 Intel 芯片**）；从创意工坊下载壁纸需要一个拥有 Wallpaper Engine 的 Steam 账号。
特效很多的场景壁纸在 4K 屏上会占 1 GB 左右内存，建议 16 GB 内存。

1. 在 [Releases](../../releases/latest) 下载 `WallPort-版本号.dmg`；
2. 打开 .dmg，把"壁坞"拖进"应用程序"文件夹，再从"应用程序"里打开（不要直接在 .dmg 里打开）；
3. 壁坞出现在屏幕右上角的菜单栏。按欢迎页的步骤：扫码登录 Steam →（可选）导入 Wallpaper Engine 自带素材 → 同步订阅。

**打开时提示"无法验证开发者"？** 没有用 Apple 开发者证书签名的版本会这样（Release 说明里会写这一版有没有经过苹果公证）。
确认是从本仓库的 Releases 下载的以后：打开"系统设置 → 隐私与安全性"，在页面下方找到壁坞，点"仍要打开"。
也可以核对下载的文件：`shasum -a 256 -c WallPort-版本号.dmg.sha256`（校验文件在同一个 Release 里）。

**更新**：壁坞每天检查一次本仓库的最新 Release，有新版本会提示（菜单栏图标里可以关掉"自动检查更新"）。下载新的 .dmg，把新的壁坞拖进"应用程序"替换旧的，设置和壁纸都不受影响。

## 常见问题

**为什么要登录 Steam？安全吗？**
从创意工坊下载壁纸需要用你的 Steam 账号。推荐"扫码登录"：用手机上的 Steam 应用确认，不用在壁坞里输入密码。壁坞不保存密码，登录后的凭证加密存在你的 Mac 上，退出登录即删除。
**壁坞用的是自己实现的 Steam 客户端（不是 Steam 官方软件），Valve 有可能限制这样登录的账号，请自行判断。**

**"Wallpaper Engine 自带素材"是什么？必须导入吗？**
不必须。壁坞自带一套自己写的兼容素材，不导入也能放场景壁纸，只是部分粒子、光效的样子和原版不同。想和 Windows 上完全一样，可以把你电脑上 Wallpaper Engine 安装目录里的 `assets` 文件夹拷过来，在欢迎页或菜单栏图标里导入。

**能放哪些壁纸？**
场景、视频、网页三类。"应用程序"类壁纸是 Windows 程序，在 macOS 上没法运行。少数场景用到的效果还没实现（例如镜头视差），这些地方会和原版有差别。

**创意工坊里的"家长指导级""限制级"壁纸怎么看不到？**
浏览创意工坊时默认只显示大众级；第一次勾选这两级时需要确认你已年满 18 岁。

**怎么卸载？**
先退出壁坞（菜单栏图标 → 退出，会恢复原来的桌面壁纸），再把主目录里的 `WallPort` 文件夹和"应用程序"里的壁坞移到废纸篓。壁坞的所有文件都在 `~/WallPort` 里。

**出问题了怎么反馈？**
在 [Issues](../../issues) 里提。打开壁纸库，在"帮助 → 导出诊断信息…"导出一个 zip（会去掉 Steam 账户名和你的用户名）附上。
**请不要上传壁纸文件或 Wallpaper Engine 的素材**（它们有版权），写创意工坊编号就行。

## 隐私

壁坞**不收集任何个人信息，不向开发者发送任何数据**：没有统计、广告或自动上报。

- 设置、壁纸、登录凭证（加密）、缓存、日志都只存在你的 Mac 上的 `~/WallPort` 里；
- 会连接的只有：Steam（登录、订阅、下载、浏览创意工坊）、GitHub（每天检查一次新版本，可以关）、以及网页壁纸自己要访问的网站（可以在菜单里禁止网页壁纸联网）；
- 系统音频只在"跟着音乐律动"的壁纸播放时读取频谱，不录音、不保存；为了在桌面被挡住时暂停，会读取屏幕上窗口的位置（不读内容和标题）。

完整的[隐私政策](App/Legal/Privacy.html)和[使用条款](App/Legal/Terms.html)在 App 的"帮助"菜单和欢迎页里可以打开。

## 从源码构建

需要 macOS 14.6 以上、Apple 芯片和 Xcode（Swift 6）。着色器编译器 glslang、SPIRV-Cross 和 zstd 解压器的源码在 `Vendor/` 里随项目一起编译，不用另外装任何东西。

```bash
swift test                 # 运行测试
scripts/build-app.sh       # 打包成 App，装到 ~/WallPort/WallPort.app（会先退出正在运行的壁坞）
open ~/WallPort/WallPort.app
```

发布：`scripts/release.sh` 打包签名（有 Apple 开发者证书时顺带公证）生成 .dmg，`scripts/publish-github.sh` 发到 GitHub Releases，
用法见两个脚本开头的说明和 [docs/发布准备.md](docs/发布准备.md)。代码结构、开发工具、各模块的设计记录见 [docs/开发说明.md](docs/开发说明.md) 和 `docs/` 里的其它文档。

想参与开发，请先看 [CONTRIBUTING.md](CONTRIBUTING.md)：**不能提交 Wallpaper Engine 的任何素材，也不能参考 GPL / AGPL 许可的同类实现。**

## 许可证

壁坞的源代码按 [MIT 许可证](LICENSE) 提供。`Vendor/` 里的第三方代码（glslang、SPIRV-Cross、zstd、LZMA SDK）和 `App/CompatFonts/` 里的字体按各自的许可证提供，许可证文本在它们旁边，App 的"关于壁坞"窗口里也有。

---

## English

**WallPort** plays Wallpaper Engine–compatible live wallpapers on your Mac — scene, video and web wallpapers — right under your desktop icons. Native on Apple silicon.

> **Notice**: WallPort is independent open-source software. It is **not an official Wallpaper Engine product** and is not affiliated with Wallpaper Engine, Steam, Valve or their developers.
> "Wallpaper Engine" and "Steam" are trademarks of their respective owners. WallPort does not provide or host any wallpapers and does not include Wallpaper Engine's built-in assets;
> wallpapers come from your own Steam Workshop subscriptions and belong to their authors.

**Requirements**: macOS 14.6 or later, a Mac with Apple silicon (M1 or later; Intel Macs are not supported), and a Steam account that owns Wallpaper Engine to download from the Workshop.

**Install**: download `WallPort-<version>.dmg` from [Releases](../../releases/latest), drag WallPort into Applications and open it from there. It lives in the menu bar; the welcome window walks you through signing in to Steam (QR code recommended), optionally importing Wallpaper Engine's assets, and syncing your subscriptions.
If macOS says the developer cannot be verified (builds without an Apple Developer ID), open System Settings → Privacy & Security and click "Open Anyway" after making sure you downloaded it from this repository's Releases.

**Signing in to Steam**: WallPort uses its own implementation of the Steam client, not the official Steam app. Your password is never stored; signing in with the QR code means you never type it into WallPort. **Valve may restrict accounts that sign in through unofficial clients — decide for yourself.**

**Privacy**: WallPort collects nothing and sends nothing to its developer — no analytics, ads or automatic reports. Everything stays in `~/WallPort` on your Mac. It connects only to Steam, to GitHub (a daily update check you can turn off), and to whatever sites web wallpapers load (you can block that). See the full [Privacy Policy](App/Legal/Privacy.html) and [Terms of Use](App/Legal/Terms.html), also available from the app's Help menu.

**Uninstall**: quit WallPort (this restores your original desktop picture), then move `~/WallPort` and WallPort in Applications to the Trash.

**Problems**: open an [issue](../../issues) and attach the zip from Help → Export Diagnostics… (account and user names are removed). Please don't upload wallpaper files or Wallpaper Engine assets — the Workshop ID is enough.

**Building from source**: `swift test` and `scripts/build-app.sh` (Xcode with Swift 6, Apple silicon). Contributions are welcome — read [CONTRIBUTING.md](CONTRIBUTING.md) first: never commit Wallpaper Engine assets, and don't use GPL/AGPL implementations as references.

**License**: [MIT](LICENSE). Third-party code in `Vendor/` and fonts in `App/CompatFonts/` keep their own licenses.
