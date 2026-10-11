import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Environment(AppModel.self) private var app
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @Query private var unreadArticles: [Article]
    @Query(filter: #Predicate<Article> { $0.isStarred }) private var starred: [Article]
    @Query(filter: #Predicate<Article> { $0.savedAt != nil }) private var saved: [Article]
    @Query private var highlights: [Highlight]
    @Environment(\.modelContext) private var context
    @State private var sheet: Sheet?
    @State private var renameText = ""
    @State private var renamingFeed: Feed?
    @State private var renamingFolder: Folder?
    @State private var creatingFolder = false
    @State private var deletingFeed: Feed?

    enum Sheet: String, Identifiable {
        case addFeed, addLink, importOPML, settings
        var id: String { rawValue }
    }

    init(selection: Binding<SidebarItem?>) {
        _selection = selection
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.isRead == false })
        descriptor.propertiesToFetch = [\.feedID]
        _unreadArticles = Query(descriptor)
    }

    private var unreadByFeed: [UUID: Int] {
        Dictionary(grouping: unreadArticles, by: \.feedID).mapValues(\.count)
    }

    var body: some View {
        let counts = unreadByFeed
        List(selection: $selection) {
            Section {
                row("전체", icon: "tray.full", tint: .blue, count: unreadArticles.count).tag(SidebarItem.all)
                row("읽지 않음", icon: "circle.inset.filled", tint: .blue, count: unreadArticles.count).tag(SidebarItem.unread)
                row("나중에 읽기", icon: "clock.fill", tint: .teal, count: saved.count).tag(SidebarItem.saved)
                row("별표", icon: "star.fill", tint: .orange, count: starred.count).tag(SidebarItem.starred)
                row("하이라이트", icon: "highlighter", tint: .yellow, count: highlights.count).tag(SidebarItem.highlights)
            }

            if !folders.isEmpty {
                Section("폴더") {
                    ForEach(folders) { folder in
                        FolderRow(folder: folder, counts: counts, selection: $selection) { feed in
                            feedMenu(feed)
                        }
                        .contextMenu {
                            Button { renameText = folder.name; renamingFolder = folder } label: {
                                Label("이름 변경", systemImage: "pencil")
                            }
                            Button {
                                let all = !folder.sortedFeeds.allSatisfy(\.notifies)
                                Task { await app.setNotifies(all, for: folder.sortedFeeds, context: context) }
                            } label: {
                                Label(folder.sortedFeeds.allSatisfy(\.notifies) ? "폴더 새 글 알림 끄기" : "폴더 새 글 알림 켜기",
                                      systemImage: "bell")
                            }
                            Button(role: .destructive) { app.deleteFolder(folder, context: context) } label: {
                                Label("폴더 삭제 (피드는 유지)", systemImage: "folder.badge.minus")
                            }
                        }
                    }
                }
            }

            let loose = feeds.filter { $0.folder == nil }
            if !loose.isEmpty {
                Section("피드") {
                    ForEach(loose) { feed in
                        feedRow(feed, count: counts[feed.id] ?? 0)
                    }
                }
            }

            if feeds.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("구독이 없습니다", systemImage: "dot.radiowaves.up.forward")
                    } description: {
                        Text("+ 버튼으로 피드를 추가하거나 Feedly에서 가져오세요.")
                    }
                }
            }
        }
        .navigationTitle("내 RSS")
        .refreshable { await app.refreshAll() }
        #if DEBUG
        .task {
            if let name = DemoData.argument("-sheet") { sheet = Sheet(rawValue: name) }
        }
        #endif
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addFeed: AddFeedSheet()
            case .addLink: AddLinkSheet { selection = .saved }
            case .importOPML: ImportOPMLSheet()
            case .settings: SettingsView()
            }
        }
        .alert("이름 변경", isPresented: Binding(get: { renamingFeed != nil || renamingFolder != nil },
                                              set: { if !$0 { renamingFeed = nil; renamingFolder = nil } })) {
            TextField("이름", text: $renameText)
            Button("취소", role: .cancel) {}
            Button("저장") { rename() }
        }
        .alert("새 폴더", isPresented: $creatingFolder) {
            TextField("폴더 이름", text: $renameText)
            Button("취소", role: .cancel) {}
            Button("만들기") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                context.insert(Folder(name: name, sortOrder: folders.count))
                try? context.save()
            }
        }
        .confirmationDialog("'\(deletingFeed?.title ?? "")' 구독을 삭제할까요?",
                            isPresented: Binding(get: { deletingFeed != nil }, set: { if !$0 { deletingFeed = nil } }),
                            titleVisibility: .visible) {
            Button("구독 삭제", role: .destructive) {
                if let feed = deletingFeed {
                    if selection == .feed(feed.id) { selection = .all }
                    app.deleteFeed(feed, context: context)
                }
            }
        } message: {
            Text("별표하거나 하이라이트한 글은 남겨 둡니다.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("설정")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { sheet = .addFeed } label: { Label("피드 추가", systemImage: "plus") }
                    Button { sheet = .addLink } label: { Label("주소로 나중에 읽기 추가", systemImage: "clock.badge.plus") }
                    Button { sheet = .importOPML } label: {
                        Label("Feedly / OPML 가져오기", systemImage: "square.and.arrow.down")
                    }
                    Button { renameText = ""; creatingFolder = true } label: {
                        Label("새 폴더", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .status) {
                if app.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if app.isCaching {
                    Label("오프라인 저장 중", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ title: String, icon: String, tint: Color, count: Int) -> some View {
        HStack {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(tint) }
            Spacer()
            CountBadge(count: count)
        }
    }

    private func feedRow(_ feed: Feed, count: Int) -> some View {
        HStack {
            Label { Text(feed.title).lineLimit(1) } icon: { FeedIcon(feed: feed) }
            Spacer()
            CountBadge(count: count)
        }
        .tag(SidebarItem.feed(feed.id))
        .contextMenu { feedMenu(feed) }
    }

    @ViewBuilder
    private func feedMenu(_ feed: Feed) -> some View {
        Button { Task { await app.refresh(feedIDs: [feed.id]) } } label: {
            Label("새로고침", systemImage: "arrow.clockwise")
        }
        Button { renameText = feed.title; renamingFeed = feed } label: {
            Label("이름 변경", systemImage: "pencil")
        }
        Menu {
            Button("폴더 없음") { app.move(feed, to: nil, context: context) }
            ForEach(folders) { folder in
                Button(folder.name) { app.move(feed, to: folder, context: context) }
            }
        } label: {
            Label("폴더 이동", systemImage: "folder")
        }
        Toggle(isOn: Binding(get: { feed.notifies }, set: { on in
            Task { await app.setNotifies(on, for: [feed], context: context) }
        })) {
            Label("새 글 알림", systemImage: "bell")
        }
        Picker(selection: Binding(get: { feed.fullTextMode }, set: {
            feed.fullTextMode = $0
            feed.updatedAt = Date()
            try? context.save()
        })) {
            ForEach(FullTextMode.allCases) { Text($0.label).tag($0) }
        } label: {
            Label("전체 본문 가져오기", systemImage: "doc.text.magnifyingglass")
        }
        .pickerStyle(.menu)
        if let site = URL(string: feed.siteURL ?? "") {
            Link(destination: site) { Label("사이트 열기", systemImage: "safari") }
        }
        Divider()
        Button(role: .destructive) { deletingFeed = feed } label: {
            Label("구독 삭제", systemImage: "trash")
        }
    }

    private func rename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let feed = renamingFeed {
            feed.title = name
            feed.updatedAt = Date()
        } else if let folder = renamingFolder {
            folder.name = name
            folder.updatedAt = Date()
        }
        renamingFeed = nil
        renamingFolder = nil
        try? context.save()
    }

    struct FolderRow<Menu: View>: View {
        let folder: Folder
        let counts: [UUID: Int]
        @Binding var selection: SidebarItem?
        @ViewBuilder let feedMenu: (Feed) -> Menu
        @State private var expanded = true

        var body: some View {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(folder.sortedFeeds) { feed in
                    HStack {
                        Label { Text(feed.title).lineLimit(1) } icon: { FeedIcon(feed: feed) }
                        Spacer()
                        CountBadge(count: counts[feed.id] ?? 0)
                    }
                    .tag(SidebarItem.feed(feed.id))
                    .contextMenu { feedMenu(feed) }
                }
            } label: {
                HStack {
                    Label(folder.name, systemImage: "folder")
                    Spacer()
                    CountBadge(count: (folder.feeds ?? []).reduce(0) { $0 + (counts[$1.id] ?? 0) })
                }
                .tag(SidebarItem.folder(folder.id))
            }
        }
    }
}

struct CountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
