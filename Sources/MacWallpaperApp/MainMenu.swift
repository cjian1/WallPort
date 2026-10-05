import AppKit

/// 屏幕顶部的菜单栏（壁坞 / 文件 / 编辑 / 显示 / 前往 / 窗口 / 帮助）。
///
/// 壁坞平时是菜单栏应用（不占 Dock、没有这一排菜单）；打开壁纸库、欢迎这类窗口时临时切成普通应用，
/// 这排菜单才会出现（见 AppDelegate.presentAppWindow）。"编辑"菜单也让文本框里的 ⌘C / ⌘V 能用
@MainActor
enum MainMenu {
    /// 菜单里要用到的 App 动作
    struct Actions {
        let target: AnyObject
        let openLibrary: Selector
        let addLibraryFolder: Selector
        let showLocal: Selector
        let showWorkshop: Selector
        let showSubscriptions: Selector
        let signIn: Selector
        let showHelp: Selector
        let openLogs: Selector
        let exportDiagnostics: Selector
        let showPrivacy: Selector
        let showTerms: Selector
        let openWebsite: Selector
        let contactSupport: Selector
    }

    /// 菜单项的 target 是弱引用：这里留一份强引用（App 的 delegate 本来就活到退出，这样写编译器也看得明白）
    private static var installedActions: Actions?

    static func install(_ actions: Actions) {
        installedActions = actions
        let name = appName
        let main = NSMenu()

        let app = submenu(name, in: main)
        app.addItem(withTitle: String(localized: "关于\(name)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu(title: String(localized: "服务"))
        app.addItem(withTitle: String(localized: "服务"), action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "隐藏\(name)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: String(localized: "隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "退出\(name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(String(localized: "文件"), in: main)
        add(String(localized: "打开壁纸库"), actions.openLibrary, "l", to: file, target: actions.target)
        add(String(localized: "添加壁纸文件夹…"), actions.addLibraryFolder, "o", to: file, target: actions.target)
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(String(localized: "编辑"), in: main)
        edit.addItem(withTitle: String(localized: "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(String(localized: "显示"), in: main)
        add(String(localized: "本机壁纸"), actions.showLocal, "1", to: view, target: actions.target)
        add(String(localized: "Steam 创意工坊"), actions.showWorkshop, "2", to: view, target: actions.target)
        view.addItem(.separator())
        let fullScreen = view.addItem(
            withTitle: String(localized: "进入全屏幕"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let go = submenu(String(localized: "前往"), in: main)
        add(String(localized: "创意工坊"), actions.showWorkshop, "", to: go, target: actions.target)
        add(String(localized: "我的订阅"), actions.showSubscriptions, "", to: go, target: actions.target)
        go.addItem(.separator())
        add(String(localized: "登录 Steam…"), actions.signIn, "", to: go, target: actions.target)

        let window = submenu(String(localized: "窗口"), in: main)
        window.addItem(withTitle: String(localized: "最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: String(localized: "前置全部窗口"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(String(localized: "帮助"), in: main)
        add(String(localized: "\(name)使用说明"), actions.showHelp, "?", to: help, target: actions.target)
        add(String(localized: "打开日志文件夹"), actions.openLogs, "", to: help, target: actions.target)
        add(String(localized: "导出诊断信息…"), actions.exportDiagnostics, "", to: help, target: actions.target)
        help.addItem(.separator())
        add(String(localized: "隐私政策"), actions.showPrivacy, "", to: help, target: actions.target)
        add(String(localized: "使用条款"), actions.showTerms, "", to: help, target: actions.target)
        // 网站、反馈地址由发布脚本写进 Info.plist；开发版没有就不显示
        if PublisherInfo.websiteURL != nil {
            add(String(localized: "访问\(name)网站"), actions.openWebsite, "", to: help, target: actions.target)
        }
        if PublisherInfo.supportURL != nil {
            add(String(localized: "反馈问题…"), actions.contactSupport, "", to: help, target: actions.target)
        }
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    /// 界面上用的 App 名字（中文系统是"壁坞"，其它是"WallPort"，见 InfoPlist.strings）
    static var appName: String {
        Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? "壁坞"
    }

    private static func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        return submenu
    }

    private static func add(_ title: String, _ action: Selector, _ key: String, to menu: NSMenu, target: AnyObject) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
    }
}
