import CoreGraphics

/// 显示器配置变化后，窗口集合需要做的调整。
public struct DisplayChanges: Equatable, Sendable {
    public var added: [DisplaySnapshot] = []
    /// 分辨率、缩放、排列位置或名称变了，窗口保留、只调整尺寸
    public var updated: [DisplaySnapshot] = []
    public var removed: [CGDirectDisplayID] = []

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
}

/// 比较前后两次显示器快照，算出要新建、调整和销毁哪些窗口。
///
/// 以 CGDirectDisplayID 作为身份：同一块显示器拔掉再插回来会拿回同一个 ID，
/// 所以热插拔之后窗口能对上原来的显示器，而不是按屏幕顺序错位。
public enum DisplayReconciler {
    public static func changes(from old: [DisplaySnapshot], to new: [DisplaySnapshot]) -> DisplayChanges {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<CGDirectDisplayID>()
        var result = DisplayChanges()

        for display in new where seen.insert(display.id).inserted {
            if let before = previous[display.id] {
                if before != display { result.updated.append(display) }
            } else {
                result.added.append(display)
            }
        }
        result.removed = previous.keys.filter { !seen.contains($0) }.sorted()
        return result
    }
}
