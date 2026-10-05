import DesktopHost
import Foundation

/// 用户在设置里关掉的场景内容（粒子、文字、特效；键的写法见 WallpaperFormats 的 `SceneElements`），
/// 按项目文件夹分开存在 UserDefaults 里
public final class HiddenElementStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "hiddenSceneElements"

    public init(defaults: UserDefaults = AppFolder.settings) {
        self.defaults = defaults
    }

    private func storageKey(_ folder: URL) -> String { folder.standardizedFileURL.path }

    public func hidden(for folder: URL) -> Set<String> {
        let all = defaults.dictionary(forKey: key) ?? [:]
        return Set(all[storageKey(folder)] as? [String] ?? [])
    }

    public func setHidden(_ isHidden: Bool, element: String, in folder: URL) {
        var elements = hidden(for: folder)
        if isHidden { elements.insert(element) } else { elements.remove(element) }
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[storageKey(folder)] = elements.isEmpty ? nil : elements.sorted()
        defaults.set(all, forKey: key)
    }

    public func reset(_ folder: URL) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[storageKey(folder)] = nil
        defaults.set(all, forKey: key)
    }
}
