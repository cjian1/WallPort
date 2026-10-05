import Foundation

/// WE 自带字体的替代：许可证允许再分发的带原字体，其余换成外观相近的开源字体（来源和许可证见
/// App/CompatFonts/README.md）。字体文件放在 App/CompatFonts，打包时拷进 App 的 Contents/Resources；
/// 开发工具和测试从仓库里的同一个文件夹读
enum CompatFonts {
    /// WE 的字体路径 → App/CompatFonts 里的文件
    static let files: [String: String] = [
        "fonts/RobotoMono-Regular.ttf": "RobotoMono-Regular.ttf",
        "fonts/NotoSans-Regular.ttf": "NotoSans-Regular.ttf",
        "fonts/Blackout 2 AM.ttf": "Blackout-2AM.ttf",
        "fonts/Segment7Standard.otf": "Segment7Standard.otf",
        "fonts/8bitOperatorPlus8-Regular.ttf": "PixelifySans-wght.ttf",
        "fonts/Alcubierre.otf": "Quicksand-wght.ttf",
        "fonts/Atami-Regular.otf": "Poppins-SemiBold.ttf",
        "fonts/CursedTimerUlil-Aznm.ttf": "DSEG14Classic-Regular.ttf",
        "fonts/Lazer84.ttf": "Knewave-Regular.ttf",
        "fonts/summer85.ttf": "Knewave-Regular.ttf",
        "fonts/Monofur-PK7og.ttf": "VictorMono-wght.ttf",
        "fonts/kust.ttf": "PermanentMarker-Regular.ttf",
        "fonts/opensticks.ttf": "ShareTechMono-Regular.ttf",
        "fonts/spincycle_3d_ot.otf": "BungeeShade-Regular.ttf",
    ]

    /// 不带文件、用系统字体代替的（TwemojiMozilla 里只有表情，CoreText 自己会用 Apple Color Emoji 补上）
    static let systemSubstitutes: [String: String] = ["fonts/TwemojiMozilla.ttf": "Helvetica Neue"]

    static func data(_ path: String) -> Data? {
        guard let name = files[path], let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// App 里是 Contents/Resources/CompatFonts；开发工具、测试（可执行文件不在 .app 里）用仓库里的 App/CompatFonts
    static let directory: URL? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("CompatFonts", isDirectory: true),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("App/CompatFonts", isDirectory: true),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }()
}
