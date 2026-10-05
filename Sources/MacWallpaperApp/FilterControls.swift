import DesktopHost
import SwiftUI
import WallpaperLibrary

/// 浏览创意工坊时看家长指导级 / 限制级的壁纸，要先确认年满 18 岁（只问一次，记在设置里）
enum AgeConfirmation {
    static let key = "confirmedAdultContent"

    static var isConfirmed: Bool {
        get { AppFolder.settings.bool(forKey: key) }
        set { AppFolder.settings.set(newValue, forKey: key) }
    }

    /// 没确认过时只留大众级（以前存下的筛选里勾了也不算）
    static func restricted(_ query: WorkshopQuery) -> WorkshopQuery {
        guard !isConfirmed else { return query }
        var query = query
        query.ratings = [WallpaperRating.everyone.rawValue]
        return query
    }
}

/// 分级：三个勾选框（大众级(G) / 家长指导级(PG-13) / 限制级/成人级(R-18)），勾几种出现几种，至少留一种。
/// `asksAge`：浏览创意工坊时，第一次勾家长指导级 / 限制级先确认年满 18 岁
struct RatingToggles: View {
    @Binding var ratings: Set<WallpaperRating>
    var asksAge = false
    /// 等用户确认年龄后才勾上的那一级
    @State private var pending: WallpaperRating?

    var body: some View {
        HStack(spacing: 10) {
            Text("分级").foregroundStyle(.secondary)
            ForEach(WallpaperRating.allCases) { rating in
                Toggle(rating.title, isOn: Binding(
                    get: { ratings.contains(rating) },
                    set: { isOn in
                        if isOn {
                            if asksAge, rating != .everyone, !AgeConfirmation.isConfirmed {
                                pending = rating
                            } else {
                                ratings.insert(rating)
                            }
                        } else if ratings.count > 1 {
                            ratings.remove(rating)
                        }
                    }))
                .toggleStyle(.checkbox)
            }
        }
        .fixedSize()
        .alert("确认你已年满 18 岁", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("我已年满 18 岁") {
                AgeConfirmation.isConfirmed = true
                if let pending { ratings.insert(pending) }
                pending = nil
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: {
            Text("家长指导级、限制级的壁纸可能含有不适合未成年人的内容。确认后才会显示这两级的壁纸和预览图。")
        }
    }
}

extension Binding where Value == Set<String> {
    /// 创意工坊那边分级用标签字符串存（Everyone / Questionable / Mature）
    var ratings: Binding<Set<WallpaperRating>> {
        Binding<Set<WallpaperRating>>(
            get: { Set(wrappedValue.compactMap(WallpaperRating.init(tag:))) },
            set: { wrappedValue = Set($0.map(\.rawValue)) })
    }
}

/// 分辨率：一排勾选框（放不下自动换行），勾几种出现几种；一个都不勾就是不限
struct ResolutionToggles: View {
    @Binding var resolutions: Set<WallpaperResolution>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("分辨率").foregroundStyle(.secondary)
            FlowLayout(spacing: 12, lineSpacing: 6) {
                ForEach(WallpaperResolution.allCases) { resolution in
                    Toggle(resolution.title, isOn: Binding(
                        get: { resolutions.contains(resolution) },
                        set: { isOn in
                            if isOn { resolutions.insert(resolution) } else { resolutions.remove(resolution) }
                        }))
                    .toggleStyle(.checkbox)
                }
                if !resolutions.isEmpty {
                    Button("不限") { resolutions = [] }.buttonStyle(.link)
                }
            }
        }
    }
}

/// 从左到右排，一行放不下就换行（勾选框多的时候用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 类型：全部 / 场景 / 视频 / 网页（创意工坊用标签字符串）
struct KindPicker: View {
    @Binding var kind: String?

    var body: some View {
        Picker("类型", selection: $kind) {
            Text("全部").tag(String?.none)
            Text("场景").tag(String?.some("Scene"))
            Text("视频").tag(String?.some("Video"))
            Text("网页").tag(String?.some("Web"))
        }
        .frame(width: 140)
    }
}
