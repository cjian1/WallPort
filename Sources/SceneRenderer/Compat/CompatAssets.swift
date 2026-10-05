import Foundation

/// 壁坞自带的兼容素材：没有导入 WE 自带素材（或者导入的版本里缺这个文件）时，场景用到的公共头文件、
/// 粒子和泛光的着色器、内置图层模型、贴图、字体从这里取。
///
/// 代码和贴图全部是自己写、程序生成的；字体是按许可证再分发的开源字体（见 `CompatFonts`）。
/// 和 WE 一样的只有**接口**：文件路径、函数名、参数和它们的含义——不一样就读不了现有的壁纸。实现按公开的数学写，语义靠场景包里的用法和画面对照（`WallpaperTool compat-check`：
/// 同一个场景分别用 WE 原版和兼容版渲染、逐像素比较）确认；WE 的原版只在开发机上当对照，不进仓库、不进安装包。
/// 来源和做法见 docs/自带素材替代.md。
///
/// 代码以字符串内嵌、贴图在第一次用到时生成；只有字体是文件（App/CompatFonts，打包脚本拷进 .app——
/// SwiftPM 的资源包在手工打包的 .app 里找不到）
public enum CompatAssets {
    /// 素材路径（和 WE 的 assets 目录里一样，例如 `shaders/common.h`、`materials/util/white.tex`）→ 内容
    static func data(_ path: String) -> Data? {
        if let text = CompatShaders.files[path] ?? CompatModels.files[path] { return Data(text.utf8) }
        if let make = CompatTextures.generators[path] { return cache.value(for: path, make: make) }
        return CompatFonts.data(path)
    }

    /// 全部兼容素材的路径（诊断、测试用）
    static var paths: [String] {
        Array(CompatShaders.files.keys) + Array(CompatModels.files.keys) + Array(CompatTextures.generators.keys)
            + Array(CompatFonts.files.keys)
    }

    /// 是不是"代码"类（着色器、头文件、模型 JSON）。对照测试只换代码、贴图仍用 WE 原版时用它区分
    static func isCode(_ path: String) -> Bool {
        path.hasPrefix("shaders/") || path.hasPrefix("models/")
    }

    /// 开发工具用：兼容素材的全部路径、是不是代码类、内容
    public static var allPaths: [String] { paths }
    public static func contents(_ path: String) -> Data? { data(path) }
    public static func isCodePath(_ path: String) -> Bool { isCode(path) }

    private static let cache = GeneratedCache()

    /// 生成的贴图按路径缓存（多块屏幕、重建场景时不用每次重新生成）
    private final class GeneratedCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func value(for path: String, make: () -> Data) -> Data {
            if let cached = lock.withLock({ values[path] }) { return cached }
            let made = make()
            lock.withLock { values[path] = made }
            return made
        }
    }
}

/// 兼容素材怎么用：App 里永远是 `.fallback`；开发工具对照测试时可以让兼容版优先
public enum CompatAssetMode: Sendable {
    /// 场景包 → WE 自带素材 → 兼容素材
    case fallback
    /// 代码类（着色器、头文件、模型）先用兼容版，贴图仍按 WE 素材优先：检验自己写的代码和 WE 的画面是否一致
    case preferCode
    /// 兼容素材里有的一律用兼容版：看没有 WE 素材的用户看到的样子
    case preferAll
    /// 不用兼容素材（和以前一样）
    case off
}
