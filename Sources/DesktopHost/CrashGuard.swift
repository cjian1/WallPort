import Foundation

/// 防"一张坏壁纸让壁坞反复崩"：载入场景前记一笔，载入完、平稳跑过一阵再擦掉；正常退出时全部擦掉。
/// 壁坞要是在这期间崩了，下次启动时还记着的那几张先不载入——开机自启会恢复上次的壁纸，不拦的话会一直崩下去。
/// 记在文件里（每次改动都整个重写），进程崩了也不会丢
///
/// 每次载入单独记一笔（`begin` 给回一个凭据，`end` 按凭据擦）：同一张壁纸重建、或者同时放在两块屏幕上时，
/// 先载入的那次到时擦掉的只是它自己那笔，后载入的照样记着
public final class CrashGuard {
    private let file: URL
    /// 凭据 → 正在载入的壁纸
    private var loading: [UUID: String] = [:]
    /// 上次退出时还记着的（多半是让壁坞崩掉的那几张）。读一次就从文件里清掉，下下次不再拦
    public let suspects: Set<String>

    public init(file: URL) {
        self.file = file
        let data = try? Data(contentsOf: file)
        suspects = Set(data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        if !suspects.isEmpty { try? FileManager.default.removeItem(at: file) }
    }

    @discardableResult
    public func begin(_ key: String) -> UUID {
        let token = UUID()
        let before = Set(loading.values)
        loading[token] = key
        if !before.contains(key) { save() }
        return token
    }

    /// 擦掉这次载入的那笔（重复调用没关系）
    public func end(_ token: UUID) {
        guard let key = loading.removeValue(forKey: token) else { return }
        if !loading.values.contains(key) { save() }
    }

    /// 正常退出
    public func clear() {
        loading = [:]
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        if loading.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Set(loading.values).sorted()).write(to: file, options: .atomic)
    }
}
