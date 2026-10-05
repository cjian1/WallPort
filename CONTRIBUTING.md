# 参与开发 / Contributing

欢迎提 Issue 和 Pull Request。壁坞要兼容 Wallpaper Engine 的壁纸，又必须和它保持法律上的独立，所以有几条**硬规矩**，比代码风格重要得多。

## 硬规矩

1. **不提交 Wallpaper Engine 的任何东西**：自带素材（着色器、材质、模型、贴图、粒子定义、字体）、创意工坊的壁纸（`.pkg`、`.tex`、`.mdl`、`scene.json`、`project.json`……）、
   截图里的壁纸画面都不行。`.gitignore` 已经挡住了常见的格式；测试用的夹具要自己写（放在 `Tests/Fixtures/`，见那里的例子）。
2. **不阅读、不参考 GPL / AGPL 许可的同类实现**（linux-wallpaperengine 等），也不要从它们复制代码。壁坞是 MIT 许可证，
   混进 GPL 代码会让整个项目没法按 MIT 发布。宽松许可（MIT、BSD、Apache-2.0）的项目可以参考，要在 `REFERENCES.md` 里注明。
3. **每个新的技术点都要在 [`REFERENCES.md`](REFERENCES.md) 里加一行**：日期、模块、技术点、依据（公开文档、对真实文件的观察、宽松许可的参考实现）。
   这是"独立实现"唯一能自证的材料。
4. **兼容素材（`Sources/SceneRenderer/Compat/`）只能自己写**：接口（路径、函数名、参数含义）要和 WE 一样，实现按公开的数学自己写，
   和原版的对照只在自己的机器上做（`WallpaperTool compat-check`），原版文件不进仓库。
5. **Steam 协议如实表明身份**：登录时报自己是 "WallPort (Mac)"，不冒充 Steam 官方客户端；不加绕过 Steam 限制（例如下载没订阅、没拥有的内容）的功能。

## 开发

- 构建和测试：`swift test`；打包：`scripts/build-app.sh`。更多见 [docs/开发说明.md](docs/开发说明.md)。
- 改了界面文字（`String(localized:)`、SwiftUI 的字面量）以后运行 `scripts/check-localization.sh`，在 `App/en.lproj/Localizable.strings` 里补上英文。
- 测试不能读写用户真正的 `~/WallPort`；需要文件夹时用临时目录。
- 提 Pull Request 前确认 `swift test` 全部通过；涉及渲染的改动最好附上改前改后的对比（用自己做的场景，或者只描述创意工坊编号）。

## 提 Issue

- 附上"帮助 → 导出诊断信息…"导出的 zip（已经去掉账号名和用户名），写清楚 macOS 版本、芯片型号、哪张壁纸（创意工坊编号）。
- **不要上传壁纸文件或 WE 素材**，有版权；也不要贴 `~/WallPort/Data` 里的任何文件（里面有登录凭证）。
- 安全问题（例如登录凭证可能泄露）请不要公开提 Issue，先在 GitHub 上用 "Report a vulnerability"（仓库的 Security 页）私下联系。

---

**In English, briefly**: contributions are welcome, with hard rules — never commit anything from Wallpaper Engine (assets, Workshop files, screenshots of wallpapers);
don't read or copy GPL/AGPL implementations such as linux-wallpaperengine (WallPort is MIT); record every new technique and its source in `REFERENCES.md`;
write compatibility assets yourself; keep the Steam client honest about its identity. Run `swift test` before opening a pull request, and run
`scripts/check-localization.sh` after changing UI text. When reporting issues, attach the diagnostics zip but never wallpaper files or anything from `~/WallPort/Data`;
report security problems privately via the repository's Security tab.
