import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacWallpaperApp
import WallpaperLibrary

/// 壁纸库窗口的布局：在最小尺寸和默认尺寸下，所有按钮、选择器、输入框、文字都要完整落在自己那一栏里，
/// 不能超出窗口、不能跨过左右两栏之间的分隔线。
///
/// 用假项目（临时文件夹里的 project.json，没有预览图）、不加载缩略图、不联网、不碰用户的缓存和登录会话。
/// 位置从进程内的辅助功能树读（SwiftUI 自己画的按钮也在里面，不需要系统授权）。
/// 设置了 `LAYOUT_SNAPSHOT_DIR` 时顺便把窗口存成 PNG，方便人眼看。
@MainActor
@Suite(.serialized) struct LibraryLayoutTests {
    /// 窗口的两种尺寸：LibraryView 的最小尺寸、LibraryWindowController 的默认尺寸
    nonisolated static let sizes: [CGSize] = [CGSize(width: 880, height: 520), CGSize(width: 1200, height: 700)]
    /// 右侧栏的宽度（和 LibraryView 里的一致）
    static let panelWidth: CGFloat = 340

    private static func makeLibrary() throws -> (LibraryModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryLayoutTests-\(UUID().uuidString)", isDirectory: true)
        let kinds = ["scene", "video", "web", "scene", "video", "scene", "web", "scene"]
        for (index, kind) in kinds.enumerated() {
            // 文件夹名是数字：和创意工坊下载的一样（右侧栏会多出"在创意工坊中打开"按钮，最挤的情况）
            let folder = root.appendingPathComponent(String(3_000_000_000 + index), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = kind == "scene" ? "scene.json" : (kind == "video" ? "video.mp4" : "index.html")
            let json = #"{"title": "测试壁纸 \#(index + 1)：一个故意写得比较长、要换行的标题", "type": "\#(kind)", "file": "\#(file)", "contentrating": "Everyone"}"#
            try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        }
        let defaults = UserDefaults(suiteName: "LibraryLayoutTests")!
        defaults.set([root.path], forKey: "libraryFolders")
        let workshop = WorkshopModel(libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in })
        let model = LibraryModel(
            folderStore: LibraryFolderStore(defaults: defaults, fallback: root),
            onApply: { _, _ in }, overrides: { _ in [:] }, onPropertyChange: { _, _, _ in }, onPropertyReset: { _ in },
            hiddenElements: { _ in [] }, onElementChange: { _, _, _ in }, onDelete: { _ in }, onUnsubscribe: { _ in },
            onOpenInWorkshop: { _ in }, onUnsubscribeItem: { _ in }, workshop: workshop,
            detailsIndex: ProjectDetailsIndex(fileURL: root.appendingPathComponent("details.json")))
        model.showsThumbnails = false
        // 两块屏、名字比较长：右侧"设为…的壁纸"最长的情况
        model.displays = [.init(id: 1, name: "内建视网膜显示器"), .init(id: 2, name: "DELL U2723QE（外接显示器）")]
        model.selectedDisplay = 2
        return (model, root)
    }

    /// 等扫描完（在后台线程做）
    private static func waitForScan(_ model: LibraryModel) async {
        for _ in 0..<200 where model.projects.isEmpty || model.isScanning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct Element {
        let role: String
        let label: String
        /// 窗口内容坐标（原点左下）
        let frame: CGRect
        var name: String { "\(role)「\(label.prefix(30))」" }
    }

    /// 进程内的辅助功能树：每个按钮、菜单、勾选框、文字的位置
    private static func elements(in window: NSWindow) -> [Element] {
        var result: [Element] = []
        // SwiftUI 在测试进程里只给很少几个自己画的元素建辅助功能节点，读得到的是托管的 AppKit 控件
        //（分段选择器、输入框、菜单 / 分体按钮、滚动条）；SwiftUI 自己画的按钮和文字靠截图人眼看
        func attribute(_ node: NSObject, _ name: NSAccessibility.Attribute) -> Any? {
            node.accessibilityAttributeNames().contains(name) ? node.accessibilityAttributeValue(name) : nil
        }
        func visit(_ node: Any, depth: Int) {
            guard depth < 80, let node = node as? NSObject else { return }
            let role = attribute(node, .role) as? String ?? ""
            let label = [NSAccessibility.Attribute.description, .title, .value]
                .lazy.compactMap { attribute(node, $0) as? String }.first { !$0.isEmpty } ?? ""
            if let position = (attribute(node, .position) as? NSValue)?.pointValue,
               let size = (attribute(node, .size) as? NSValue)?.sizeValue, size.width > 0, size.height > 0,
               !["AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXList", "AXLayoutArea", "AXUnknown"].contains(role) {
                // 属性接口给的是屏幕坐标（原点左下）的左下角
                result.append(Element(role: role, label: label, frame: window.convertFromScreen(CGRect(origin: position, size: size))))
            }
            for child in attribute(node, .children) as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        if let view = window.contentView { visit(view, depth: 0) }
        return result
    }

    private static func host(_ root: some View, size: CGSize) -> NSWindow {
        // 无边框窗口：带标题栏的窗口排到前面时会被系统拉回屏幕里（会在用户屏幕上闪一下），无边框的不会
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(size)
        window.orderFrontRegardless()
        precondition(window.frame.minX < -10_000, "测试窗口被挪进了屏幕")
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private static func snapshot(_ window: NSWindow, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["LAYOUT_SNAPSHOT_DIR"],
              let view = window.contentView, let layer = view.layer
        else { return }
        // cacheDisplay 抓不到 SwiftUI 自己画的内容；直接把图层树画出来（窗口要先排进窗口服务器、提交一次）
        CATransaction.flush()
        let scale = 2
        let width = Int(view.bounds.width) * scale, height = Int(view.bounds.height) * scale
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // NSHostingView 是翻转坐标（原点在左上），CGContext 原点在左下
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 每个元素都在窗口里、不跨过左右两栏的分隔线
    private static func checkColumns(_ window: NSWindow, _ label: String) throws {
        let bounds = try #require(window.contentView).bounds
        let panelLeft = bounds.width - panelWidth
        for element in elements(in: window) {
            print("\(label)  \(element.name)  \(element.frame.integral)")
            let frame = element.frame.insetBy(dx: 0.5, dy: 0.5)
            #expect(frame.minX >= 0 && frame.maxX <= bounds.maxX && frame.minY >= 0 && frame.maxY <= bounds.maxY,
                    "\(label)：\(element.name) 超出窗口 \(element.frame.integral)")
            #expect(frame.minX >= panelLeft - 1 || frame.maxX <= panelLeft,
                    "\(label)：\(element.name) 跨过了左右两栏的分隔线（x=\(Int(panelLeft))）\(element.frame.integral)")
        }
    }

    /// `isCurrent`：选中的正是"设到"那块屏当前的壁纸（右侧栏换成"当前壁纸 + 设到其它显示器"）
    @Test(arguments: sizes, [false, true])
    func localLibraryFitsItsColumns(size: CGSize, isCurrent: Bool) async throws {
        let (model, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        model.rescan()
        await Self.waitForScan(model)
        let key = try #require(model.projects.first.map { LibraryModel.key($0.folder) })
        model.selectedKey = key
        if isCurrent { model.currentFolders = [2: key] }
        let window = Self.host(LibraryView(model: model, workshop: model.workshop), size: size)
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        let name = "\(Int(size.width))x\(Int(size.height))" + (isCurrent ? "-current" : "")
        Self.snapshot(window, name: "local-\(name)")
        try Self.checkColumns(window, "本机 \(name)")
    }

    /// 壁纸设置里的"声音""显示"两节放在 340 宽的右侧栏里：总开关关着时的提示、两种显示方式、位置滑块都不能撑宽
    @Test(arguments: [false, true])
    func playbackOptionsFitThePanel(fitsWhole: Bool) async throws {
        let options = WallpaperOptions(isMuted: false, volume: 0.6, fitsWhole: fitsWhole, position: 0.2)
        let view = Form {
            PlaybackOptionsSections(
                options: .constant(options),
                context: PlaybackOptionsContext(
                    hasAudio: true, playsAudio: false, crop: LibraryModel.Crop(axis: .vertical, visible: 0.46)))
        }
        .formStyle(.grouped)
        .frame(width: Self.panelWidth, height: 560)
        let window = Self.host(view, size: CGSize(width: Self.panelWidth, height: 560))
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        Self.snapshot(window, name: "playback-options" + (fitsWhole ? "-fit" : ""))
        for element in Self.elements(in: window) {
            let frame = element.frame.insetBy(dx: 0.5, dy: 0.5)
            #expect(frame.minX >= 0 && frame.maxX <= Self.panelWidth, "\(element.name) 超出右侧栏 \(element.frame.integral)")
        }
    }

    /// 底栏始终一行：好几项下载失败（内容服务器回 503 这种长原因）、几十个在等、暂停着，都不能把底栏撑高、挤出窗口
    @Test(arguments: [false, true])
    func statusBarStaysOneLine(paused: Bool) async throws {
        let workshop = WorkshopModel(libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in })
        let reason = "Steam 的内容服务器暂时忙不过来（cache1-lax1.steamcontent.com 返回 HTTP 503），过一会儿点「重试」"
        workshop.showQueueForLayoutTest(
            (0..<12).map { .init(id: "37851\(String(format: "%05d", $0))", state: .failed(reason)) }
                + (0..<30).map { .init(id: "36000\(String(format: "%05d", $0))", state: $0 == 0 && !paused ? .downloading : .waiting) },
            paused: paused)
        let size = CGSize(width: 880, height: 60)
        let window = Self.host(WorkshopStatusBar(model: workshop).frame(width: size.width), size: size)
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        Self.snapshot(window, name: "statusbar-\(paused ? "paused" : "downloading")")
        let bar = NSHostingView(rootView: WorkshopStatusBar(model: workshop).frame(width: size.width))
        #expect(bar.fittingSize.height <= 44, "底栏高了：\(bar.fittingSize.height)")
        // 测试进程里拿不到 SwiftUI 按钮的辅助功能信息，按钮齐不齐看截图（LAYOUT_SNAPSHOT_DIR）
        let bounds = try #require(window.contentView).bounds
        for element in Self.elements(in: window) {
            let frame = element.frame.insetBy(dx: 0.5, dy: 0.5)
            #expect(frame.minX >= 0 && frame.maxX <= bounds.maxX, "\(element.name) 超出窗口 \(element.frame.integral)")
        }
    }

    /// 欢迎页：按内容算高度，按钮不被切掉、不出窗口
    @Test func welcomeFitsItsContent() async throws {
        let workshop = WorkshopModel(libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in })
        let model = WelcomeModel(hasAssets: false, libraryFolderCount: 0)
        model.isImportingAssets = true
        let view = WelcomeView(
            model: model, workshop: workshop, onSignIn: {}, onChooseAssets: {}, onAddLibraryFolder: {}, onOpenLibrary: {})
        let size = NSHostingView(rootView: view).fittingSize
        #expect(size.width <= 600 && size.height < 760, "欢迎页太大：\(size)")
        let window = Self.host(view, size: size)
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(200))
        Self.snapshot(window, name: "welcome")
    }

    /// 登录框：扫码、账号密码和底下的说明（和 Valve 的关系、风险、隐私政策链接）都放得下，不出框
    @Test func loginSheetFitsItsContent() async throws {
        let workshop = WorkshopModel(libraryFolders: { [] }, onDownloaded: { _ in }, onUnsubscribed: { _ in })
        let view = SteamLoginSheet(model: workshop)
        let size = NSHostingView(rootView: view).fittingSize
        #expect(size.width <= 480 && size.height < 640, "登录框太大：\(size)")
        let window = Self.host(view, size: size)
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(200))
        Self.snapshot(window, name: "login")
    }

    /// 创意工坊页：LibraryView 切过去会连 Steam（activate），这里用同样的几个视图按同样的方式拼起来
    @Test(arguments: sizes)
    func workshopPageFitsItsColumns(size: CGSize) async throws {
        let (model, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let workshop = model.workshop
        let page = VStack(spacing: 0) {
            HStack {
                Picker("", selection: .constant(LibraryModel.Mode.workshop)) {
                    ForEach(LibraryModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10)
            HStack(spacing: 0) {
                WorkshopGallery(model: workshop, library: model)
                    .frame(minWidth: 520, maxWidth: .infinity)
                Divider()
                WorkshopItemPanel(model: workshop, library: model)
                    .frame(width: Self.panelWidth)
            }
            Divider()
            WorkshopStatusBar(model: workshop)
        }
        .frame(minWidth: 880, minHeight: 520)
        let window = Self.host(page, size: size)
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        let label = "工坊 \(Int(size.width))×\(Int(size.height))"
        Self.snapshot(window, name: "workshop-\(Int(size.width))x\(Int(size.height))")
        try Self.checkColumns(window, label)
    }
}
