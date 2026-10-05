import AppKit
import DesktopHost
import SwiftUI

/// 欢迎页上随时会变的状态（登录、素材、壁纸文件夹），选完素材、登录完马上刷新
@MainActor
final class WelcomeModel: ObservableObject {
    @Published var hasAssets: Bool
    @Published var isImportingAssets = false
    @Published var libraryFolderCount: Int

    init(hasAssets: Bool, libraryFolderCount: Int) {
        self.hasAssets = hasAssets
        self.libraryFolderCount = libraryFolderCount
    }
}

/// 第一次运行时的小引导：登录 Steam →（可选）导入 WE 自带素材 → 同步订阅。之后可以从菜单重新打开。
@MainActor
final class WelcomeWindowController: NSWindowController {
    init(
        model: WelcomeModel, workshop: WorkshopModel, onSignIn: @escaping () -> Void,
        onChooseAssets: @escaping () -> Void, onAddLibraryFolder: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void
    ) {
        let hosting = NSHostingController(
            rootView: WelcomeView(
                model: model, workshop: workshop, onSignIn: onSignIn, onChooseAssets: onChooseAssets,
                onAddLibraryFolder: onAddLibraryFolder, onOpenLibrary: onOpenLibrary))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "欢迎使用\(MainMenu.appName)")
        window.styleMask = [.titled, .closable]
        // 高度按内容算：写死的高度装不下时底部的按钮会被切掉（原来的 360 就不够）
        window.setContentSize(hosting.view.fittingSize)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    @ObservedObject var workshop: WorkshopModel
    let onSignIn: () -> Void
    let onChooseAssets: () -> Void
    let onAddLibraryFolder: () -> Void
    let onOpenLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("壁坞 WallPort")
                .font(.largeTitle.bold())
            Text("播放兼容 Wallpaper Engine 的动态壁纸（场景、视频、网页），壁纸显示在桌面图标下面。")
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            step(
                "1. 登录 Steam",
                "壁坞从 Steam 创意工坊下载你订阅的壁纸，账号需要拥有 Wallpaper Engine。推荐用手机上的 Steam App 扫码登录，不用在这里输入密码。"
            ) {
                if workshop.isLoggedIn {
                    Label("已登录 \(workshop.accountName ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("登录 Steam…", action: onSignIn)
                }
            }
            step(
                "2. Wallpaper Engine 自带素材（自动）",
                "登录以后，壁坞会用你的账号从 Steam 下载 Wallpaper Engine 的自带素材（账号拥有 Wallpaper Engine 就行，约 85 MB），场景壁纸就和原版一样。下好之前、或者没登录时，用壁坞自带的兼容素材，部分粒子、光效的样子和原版不同。也可以手动选从 Windows 上拷来的 assets 文件夹。"
            ) {
                if let progress = workshop.engineAssetsProgress {
                    ProgressView(value: progress).frame(width: 160)
                    Text("正在从 Steam 下载…\(Int(progress * 100))%").foregroundStyle(.secondary).monospacedDigit()
                } else if model.isImportingAssets {
                    ProgressView().controlSize(.small)
                    Text("正在拷贝…").foregroundStyle(.secondary)
                } else {
                    Button("选择 assets 文件夹…", action: onChooseAssets)
                    Text(model.hasAssets ? "已就绪" : workshop.isLoggedIn ? "现在用壁坞自带的兼容素材" : "登录后自动下载")
                        .foregroundStyle(.secondary)
                }
            }
            step(
                "3. 同步订阅",
                "登录后在壁纸库底部点「同步订阅」，你在 Steam 上订阅的壁纸会下载到这台 Mac。也可以添加自己电脑上的壁纸文件夹。"
            ) {
                Button("添加壁纸文件夹…", action: onAddLibraryFolder)
                Text(model.libraryFolderCount > 0 ? "壁纸库里有 \(model.libraryFolderCount) 个文件夹" : "")
                    .foregroundStyle(.secondary)
            }
            Text("第一次播放跟着音乐律动的壁纸时，系统会询问是否允许录制系统音频：只读取声音的频谱，不录音、不保存。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 和 WE / Steam 的关系、条款：第一次打开就看得到
            VStack(alignment: .leading, spacing: 4) {
                Text("\(MainMenu.appName)是独立开发的软件，不是 Wallpaper Engine 或 Steam 的官方产品，不提供、不托管任何壁纸。使用即表示你同意使用条款。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("使用条款") { PublisherInfo.open(.terms) }
                    Button("隐私政策") { PublisherInfo.open(.privacy) }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            Divider()
            HStack {
                Button("打开壁纸库", action: onOpenLibrary).keyboardShortcut(.defaultAction)
                Spacer()
                Text("壁坞的所有文件都在 ~/WallPort 里；这个窗口可以从菜单栏的「首次使用提示」再打开")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(
        _ title: LocalizedStringKey, _ detail: LocalizedStringKey, @ViewBuilder controls: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).fixedSize(horizontal: false, vertical: true)
            HStack { controls() }
        }
    }
}
