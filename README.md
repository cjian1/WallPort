<div align="center">

<img src="App/AppIcon.svg" width="128" height="128" alt="壁坞 WallPort">

# 壁坞 WallPort

**在 Mac 上播放 Wallpaper Engine 的动态壁纸**

场景 · 视频 · 网页 &nbsp;｜&nbsp; Apple 芯片原生 &nbsp;｜&nbsp; 免费开源

<a href="../../releases/latest"><img src="https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD%E5%A3%81%E5%9D%9E-%E5%85%8D%E8%B4%B9%E5%BC%80%E6%BA%90-0ea5e9?style=for-the-badge&logo=apple&logoColor=white" height="40" alt="下载壁坞"></a>

<a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/cjian1/WallPort?style=flat-square&color=0ea5e9&label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC" alt="最新版本"></a>
<a href="../../releases"><img src="https://img.shields.io/github/downloads/cjian1/WallPort/total?style=flat-square&color=22c55e&label=%E4%B8%8B%E8%BD%BD%E6%AC%A1%E6%95%B0" alt="下载次数"></a>
<img src="https://img.shields.io/badge/macOS-14.6%2B-111827?style=flat-square&logo=apple&logoColor=white" alt="macOS 14.6+">
<img src="https://img.shields.io/badge/Apple%20%E8%8A%AF%E7%89%87-M1%2B-111827?style=flat-square" alt="Apple 芯片">
<a href="LICENSE"><img src="https://img.shields.io/github/license/cjian1/WallPort?style=flat-square&color=a855f7&label=%E8%AE%B8%E5%8F%AF%E8%AF%81" alt="MIT 许可证"></a>

[**English**](README.en.md) &nbsp;·&nbsp; [安装](#install) &nbsp;·&nbsp; [常见问题](#faq) &nbsp;·&nbsp; [隐私](#privacy) &nbsp;·&nbsp; [从源码构建](#build)

</div>

<br>

> [!IMPORTANT]
> 壁坞是独立开发的开源软件，**不是 Wallpaper Engine 的官方产品**，与 Wallpaper Engine、Steam、Valve 及其开发者没有关联。
> 壁坞不提供、不托管任何壁纸，也不包含 Wallpaper Engine 的素材——壁纸来自你自己的 Steam 创意工坊订阅，版权属于各自的作者。

## ✨ 功能

<table>
<tr>
<td width="50%" valign="top">

**🖼️ 三类壁纸都能放**<br>
场景壁纸的图层、特效、粒子、木偶动画、文字和时钟、脚本、声音，以及视频、网页壁纸。WE 的着色器在运行时翻译成 Metal。

</td>
<td width="50%" valign="top">

**🔄 同步你的订阅**<br>
扫码登录 Steam，你在创意工坊订阅的壁纸自动下载到这台 Mac；也能在 App 里直接浏览、订阅。

</td>
</tr>
<tr>
<td valign="top">

**🎨 和原版一样**<br>
登录后用你的账号从 Steam 下载 Wallpaper Engine 的自带素材，不用从 Windows 电脑拷文件。

</td>
<td valign="top">

**🖥️ 多屏和轮播**<br>
每块屏幕放不同的壁纸，可以定时轮播；壁纸作者提供的颜色、开关、滑块都能直接调。

</td>
</tr>
<tr>
<td valign="top">

**🔋 省电**<br>
桌面被窗口挡住、用电池、机器发热时自动降帧或暂停；画面动得慢的场景自动降到 20 / 24 帧。

</td>
<td valign="top">

**🌙 不打扰**<br>
住在菜单栏里；没设壁纸时保留你原来的桌面；锁屏时同步成当前画面，退出时恢复原样。

</td>
</tr>
</table>

## 📸 截图

<p align="center">
  <img src="docs/images/welcome.png" width="49%" alt="欢迎页：登录 Steam、自动下载素材、同步订阅">
  <img src="docs/images/login.png" width="49%" alt="登录：推荐扫码，不用输密码">
</p>

<a id="install"></a>
## 📥 下载和安装

- 💻 **系统**：macOS 14.6 或更新版本
- 🍎 **芯片**：Apple 芯片（M1 及以后），不支持 Intel 芯片
- 🎮 **账号**：从创意工坊下载壁纸需要一个拥有 Wallpaper Engine 的 Steam 账号
- 🧠 **内存**：建议 16 GB（特效很多的场景在 4K 屏上会占 1 GB 左右）

1. 在 [**Releases**](../../releases/latest) 下载 `WallPort-版本号.dmg`；
2. 打开 .dmg，把**壁坞**拖进「应用程序」，再从「应用程序」里打开（不要直接在 .dmg 里打开）；
3. 壁坞出现在屏幕右上角的菜单栏。按欢迎页的步骤：扫码登录 Steam → 自动下载素材 → 同步订阅，就能在壁纸库里挑壁纸了。

> [!TIP]
> **打开时提示"无法验证开发者"？** 没有用 Apple 开发者证书签名的版本会这样（每个版本的说明里会写有没有签名）。
> 确认是从本仓库的 Releases 下载的以后：打开「系统设置 → 隐私与安全性」，在页面下方找到壁坞，点「仍要打开」。
> 想核对文件没被改过：`shasum -a 256 -c WallPort-版本号.dmg.sha256`（校验文件在同一个 Release 里）。

**更新**：壁坞每天检查一次新版本，有了会提示（菜单栏里可以关掉"自动检查更新"）。下载新的 .dmg，把新的壁坞拖进「应用程序」替换旧的，设置和壁纸都不受影响。

<a id="faq"></a>
## ❓ 常见问题

<details>
<summary><b>为什么要登录 Steam？安全吗？</b></summary>
<br>

从创意工坊下载壁纸、下载 Wallpaper Engine 的自带素材，都要用你的 Steam 账号。推荐**扫码登录**：用手机上的 Steam 应用确认，不用在壁坞里输入密码。
壁坞不保存密码，登录后的凭证加密存在你的 Mac 上，退出登录即删除。

壁坞用的是自己实现的 Steam 客户端（不是 Steam 官方软件），Valve 有可能限制这样登录的账号，请自行判断。
</details>

<details>
<summary><b>"Wallpaper Engine 自带素材"是什么？要我自己弄吗？</b></summary>
<br>

不用。场景壁纸要用 Wallpaper Engine 自带的着色器、贴图这些素材。你登录以后，壁坞会用**你的** Steam 账号从 Steam 下载你已拥有的 Wallpaper Engine 里的这部分文件（约 85 MB，Wallpaper Engine 更新时自动更新），场景壁纸就和原版一样。

壁坞本身不带、不分发这些素材（它们是 Wallpaper Engine 的版权内容）。下好之前或者没登录时，用壁坞自己写的兼容素材，部分粒子、光效的样子和原版不同。
</details>

<details>
<summary><b>能放哪些壁纸？</b></summary>
<br>

场景、视频、网页三类。"应用程序"类壁纸是 Windows 程序，在 macOS 上没法运行。本机 329 个场景里 313 个（95%）判定为正常，剩下的是少数还没实现的效果（带 3D 相机的图层、HDR 泛光等），这些地方会和原版有差别；判定口径和缺什么见 [docs/M6-验收清单.md](docs/M6-验收清单.md)。
</details>

<details>
<summary><b>还没挑壁纸时桌面会变成什么样？</b></summary>
<br>

不会变。没设壁纸的屏幕保留你原来的桌面壁纸；也可以在菜单栏图标里给某块屏幕选「不放动态壁纸（用系统壁纸）」。
</details>

<details>
<summary><b>创意工坊里的"家长指导级""限制级"壁纸怎么看不到？</b></summary>
<br>

浏览创意工坊时默认只显示大众级；第一次勾选这两级时需要确认你已年满 18 岁。
</details>

<details>
<summary><b>怎么卸载？</b></summary>
<br>

先退出壁坞（菜单栏图标 → 退出，会恢复原来的桌面壁纸），再把主目录里的 `WallPort` 文件夹和「应用程序」里的壁坞移到废纸篓。壁坞的所有文件都在 `~/WallPort` 里。
</details>

<details>
<summary><b>出问题了怎么反馈？</b></summary>
<br>

在 [Issues](../../issues) 里提。打开壁纸库，在「帮助 → 导出诊断信息…」导出一个 zip（会去掉 Steam 账户名和你的用户名）附上。
**请不要上传壁纸文件或 Wallpaper Engine 的素材**（它们有版权），写创意工坊编号就行。
</details>

<a id="privacy"></a>
## 🔒 隐私

壁坞**不收集任何个人信息，不向开发者发送任何数据**——没有统计、没有广告、没有自动上报。

- 设置、壁纸、登录凭证（加密）、缓存、日志都只存在你 Mac 上的 `~/WallPort` 里；
- 会连接的只有 **Steam**（登录、订阅、下载壁纸和素材、浏览创意工坊）、**GitHub**（每天检查一次新版本，可以关），以及网页壁纸自己要访问的网站（可以在菜单里禁止网页壁纸联网）；
- 系统音频只在"跟着音乐律动"的壁纸播放时读取频谱，不录音、不保存；为了在桌面被挡住时暂停，会读取屏幕上窗口的位置（不读内容和标题）。

完整的[隐私政策](App/Legal/Privacy.html)和[使用条款](App/Legal/Terms.html)在 App 的「帮助」菜单和欢迎页里可以打开。

<a id="build"></a>
## 🛠️ 从源码构建

需要 macOS 14.6 以上、Apple 芯片和 Xcode（Swift 6）。着色器编译器 glslang、SPIRV-Cross 和 zstd 解压器的源码在 `Vendor/` 里随项目一起编译，不用另外装任何东西。

```bash
swift test                 # 运行测试
scripts/build-app.sh       # 打包成 App，装到 ~/WallPort/WallPort.app（会先退出正在运行的壁坞）
open ~/WallPort/WallPort.app
```

发布用 `scripts/release.sh` 打包签名（有 Apple 开发者证书时顺带公证），`scripts/publish-github.sh` 发到 GitHub Releases，
用法见两个脚本开头的说明和 [docs/发布准备.md](docs/发布准备.md)。代码结构、开发工具、各模块的设计记录见 [docs/开发说明.md](docs/开发说明.md)。

## 🤝 参与开发

欢迎提 Issue 和 Pull Request。动手之前请先看 [CONTRIBUTING.md](CONTRIBUTING.md)，有两条硬规矩：
**不能提交 Wallpaper Engine 的任何素材，也不能参考 GPL / AGPL 许可的同类实现**；每个新技术点要在 [REFERENCES.md](REFERENCES.md) 里写明来源。

## 📄 许可证

壁坞的源代码按 [MIT 许可证](LICENSE) 提供。`Vendor/` 里的第三方代码（glslang、SPIRV-Cross、zstd、LZMA SDK）和 `App/CompatFonts/` 里的字体按各自的许可证提供，许可证文本在它们旁边，App 的「关于壁坞」窗口里也有。

"Wallpaper Engine""Steam"是其各自权利人的商标。
