import AppKit
import SwiftUI
import WallpaperLibrary

struct WorkshopAuthorLink: View {
    @ObservedObject var model: WorkshopModel
    let steamID: String

    var body: some View {
        Button(model.authorName(for: steamID) ?? steamID) {
            let knownName = model.authorNames[steamID]
            Task { await model.openAuthor(steamID, name: knownName) }
        }
        .buttonStyle(.link)
        .help(String(localized: "查看这个作者的其他作品"))
        .task(id: steamID) { await model.loadAuthorName(steamID) }
    }
}

struct WorkshopAuthorSheetHost: ViewModifier {
    @ObservedObject var model: WorkshopModel
    let library: LibraryModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.selectedAuthor },
            set: { if $0 == nil { model.closeAuthor() } }
        )) { _ in
            WorkshopAuthorSheet(model: model, library: library)
        }
    }
}

struct WorkshopAuthorSheet: View {
    @ObservedObject var model: WorkshopModel
    let library: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                works
                    .frame(minWidth: 600, maxWidth: .infinity)
                Divider()
                WorkshopItemPanel(model: model, library: library)
                    .frame(width: 340)
            }
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 600, idealHeight: 720)
    }

    @ViewBuilder
    private var header: some View {
        if let author = model.selectedAuthor {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(author.name).font(.title2.bold())
                    Text(String(localized: "作者的其他创意工坊作品"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "打开作者主页")) {
                    NSWorkspace.shared.open(author.profileURL)
                }
                Button(String(localized: "关闭")) { model.closeAuthor() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var works: some View {
        if model.authorWorks.isEmpty, model.isLoadingAuthorWorks {
            VStack(spacing: 10) {
                ProgressView()
                Text(String(localized: "正在读取作者作品…")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.authorWorks.isEmpty, let error = model.authorWorksError {
            VStack(spacing: 10) {
                Text(String(localized: "读取作者作品失败：\(error)"))
                    .foregroundStyle(.secondary)
                Button(String(localized: "重试")) {
                    Task { await model.retryAuthorWorks() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.authorWorks.isEmpty {
            Text(String(localized: "这个作者没有其他公开作品。"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)],
                    spacing: 18
                ) {
                    ForEach(model.authorWorks) { item in
                        WorkshopCard(
                            item: item, isSelected: model.selectedID == item.id,
                            isLocal: model.isLocal(item.id),
                            isSubscribed: model.subscribedIDs.contains(item.id),
                            state: model.state(of: item.id), progress: model.progress[item.id])
                        .onTapGesture { model.selectedID = item.id }
                        .onAppear {
                            if item.id == model.authorWorks.last?.id {
                                Task { await model.loadMoreAuthorWorks() }
                            }
                        }
                    }
                }
                .padding(16)
                if model.isLoadingAuthorWorks {
                    ProgressView().padding(.bottom, 16)
                } else if let error = model.authorWorksError {
                    HStack {
                        Text(String(localized: "读取作者作品失败：\(error)"))
                            .font(.caption).foregroundStyle(.red)
                        Button(String(localized: "重试")) {
                            Task { await model.retryAuthorWorks() }
                        }
                        .controlSize(.small)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }
}
