import Foundation
import WallpaperFormats

/// 按 WE 的规则找场景用到的文件：先找场景包，再找 WE 自带素材目录（Windows 上的 wallpaper_engine/assets），
/// 都没有时用壁坞自带的兼容素材（见 `CompatAssets`）
struct SceneFiles: Sendable {
    let package: ScenePackage
    let assets: URL?

    /// 开发工具用：每从 WE 自带素材目录读到一个文件就回调一次（参数是相对素材目录的路径），
    /// 统计场景实际依赖哪些自带素材（`WallpaperTool asset-usage`）。App 里不设
    nonisolated(unsafe) static var assetReadObserver: ((String) -> Void)?
    /// 开发工具用：兼容素材怎么用（App 里永远是 `.fallback`）
    nonisolated(unsafe) static var compatMode: CompatAssetMode = .fallback
    /// 开发工具用：每用到一个兼容素材回调一次
    nonisolated(unsafe) static var compatReadObserver: ((String) -> Void)?

    func data(_ path: String) -> Data? {
        if let contents = package.contents(of: path) { return contents }
        let leavesFolder = path.split(separator: "/").contains("..")
        if !leavesFolder, let compat = preferredCompat(path) { return compat }
        // 带 `..` 的路径不去素材目录找：场景包是从网上下载的，不能让它读到素材目录外面（`<素材目录>/..` 就是主目录）
        if let assets, !leavesFolder {
            if let data = try? Data(contentsOf: assets.appendingPathComponent(path)) {
                Self.assetReadObserver?(path)
                return data
            }
            if let data = dataUnderEffectFolder(path, assets: assets) { return data }
        }
        if !leavesFolder, Self.compatMode != .off, let compat = CompatAssets.data(path) {
            Self.compatReadObserver?(path)
            return compat
        }
        // 作者本机上"引用自己项目文件夹"的写法：`../<项目文件夹>/particles/x.json`，包里对应的是 `particles/x.json`
        // （2439693800）。去掉前面的 `..` 和紧跟的那一级再在包里找；千万不能拿它去拼素材目录——
        // `<素材目录>/..` 就是用户的主目录
        if let local = Self.withoutParentFolder(path) {
            if let contents = package.contents(of: local) { return contents }
            return dataByDirectoryAndName(local)
        }
        // 精确路径和自带素材都找不到时才按文件名在包里找：放在前面的话，引用自带特效的
        // `materials/effects/blur.json` 会先撞上包里同名的工作坊文件（工作坊特效常照抄自带的文件名）
        return dataByDirectoryAndName(path)
    }

    /// 对照测试时兼容素材优先（App 里是 `.fallback`，不走这里）
    private func preferredCompat(_ path: String) -> Data? {
        switch Self.compatMode {
        case .fallback, .off: return nil
        case .preferCode: guard CompatAssets.isCode(path) else { return nil }
        case .preferAll: break
        }
        guard let data = CompatAssets.data(path) else { return nil }
        Self.compatReadObserver?(path)
        return data
    }

    /// `../<项目文件夹>/a/b.json` → `a/b.json`；不是这种写法时返回 nil
    static func withoutParentFolder(_ path: String) -> String? {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == ".." else { return nil }
        while parts.first == ".." { parts.removeFirst() }
        // 紧跟着的是作者本机的项目文件夹名；后面至少还要剩"目录 + 文件名"两级才算
        guard parts.count >= 3 else { return nil }
        parts.removeFirst()
        return parts.joined(separator: "/")
    }

    /// 脚本里的资源路径有时是作者打包前的本机路径（例如 `createLayer('models/bar.json')`），
    /// 而发布到创意工坊后同名文件被放进 `models/workshop/<编号>/`。原路径找不到时，在**场景包里**按
    /// "顶层目录 + 文件名"再找一次；多个同名文件时取路径最短、字典序最小的那个，保证结果稳定。
    /// （2350484035 / 2255543849 的可视化条就是这样：脚本写 `models/bar.json`，
    /// 包里实际是 `models/workshop/2115341179/bar.json`，找不到的话 63 根柱子一根也建不出来）
    /// 只在包里找：WE 自带素材有自己的布局规则（见 `dataUnderEffectFolder`），逐个目录遍历既慢又可能找错
    private func dataByDirectoryAndName(_ path: String) -> Data? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let directory = parts[0]
        let name = parts[parts.count - 1]
        let candidates = package.entries.map(\.name)
            .filter { $0.hasPrefix(directory + "/") && $0.hasSuffix("/" + name) }
            .sorted { ($0.count, $0) < ($1.count, $1) }
        for candidate in candidates {
            if let contents = package.contents(of: candidate) { return contents }
        }
        return nil
    }

    /// WE 自带素材的实际布局是 `effects/<特效名>/<原路径>`：场景里引用的是根路径
    /// （例如 `materials/effects/motionblur_accumulation.json`），而文件在
    /// `effects/motionblur/materials/effects/motionblur_accumulation.json`。
    /// 根路径和素材目录下都找不到时，到各个特效文件夹里再找一次
    private func dataUnderEffectFolder(_ path: String, assets: URL) -> Data? {
        guard path.hasPrefix("materials/") || path.hasPrefix("shaders/") else { return nil }
        let effects = assets.appendingPathComponent("effects", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: effects, includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)) else { continue }
            Self.assetReadObserver?("effects/\(folder.lastPathComponent)/\(path)")
            return data
        }
        return nil
    }

    func text(_ path: String) -> String? {
        data(path).map { String(decoding: $0, as: UTF8.self) }
    }

    func json(_ path: String) -> [String: Any]? {
        data(path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
