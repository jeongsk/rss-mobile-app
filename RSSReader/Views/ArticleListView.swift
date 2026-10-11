import SwiftUI
import SwiftData

enum ListLayout: String, CaseIterable, Identifiable {
    case list, magazine, grid, titles
    var id: String { rawValue }
    var label: String {
        switch self {
        case .list: "리스트"
        case .magazine: "매거진"
        case .grid: "그리드"
        case .titles: "제목만"
        }
    }
    var icon: String {
        switch self {
        case .list: "list.bullet.below.rectangle"
        case .magazine: "rectangle.grid.1x2"
        case .grid: "square.grid.2x2"
        case .titles: "list.bullet"
        }
    }
}

/// 화면(스코프)별 레이아웃과 "읽지 않은 글만" 설정을 기억하고 목록을 만든다.
struct ArticleListContainer: View {
    let scope: SidebarItem
    @Binding var selection: PersistentIdentifier?
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var folders: [Folder]
    @Query private var feeds: [Feed]
    @AppStorage("listLayouts") private var layoutsJSON = "{}"
    @AppStorage("unreadOnly") private var unreadOnly = false
    @State private var confirmMarkAll = false
    #if DEBUG
    @State private var searchText = DemoData.argument("-search") ?? ""
    #else
    @State private var searchText = ""
    #endif
    @State private var searchScope = SearchScope.current

    enum SearchScope: String, CaseIterable, Identifiable {
        case current = "현재 화면", everything = "전체 글"
        var id: String { rawValue }
    }

    private var layouts: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(layoutsJSON.utf8))) ?? [:]
    }

    /// 피드는 기기마다 id 가 달라 주소로 저장해야 다른 기기와 레이아웃이 맞춰진다
    private var layoutKey: String {
        if case .feed(let id) = scope, let feed = feeds.first(where: { $0.id == id }) {
            return "feed." + URLNormalizer.normalize(feed.feedURL)
        }
        return scope.storageKey
    }

    private var layout: ListLayout {
        ListLayout(rawValue: layouts[layoutKey] ?? layouts["default"] ?? "") ?? .list
    }

    private func setLayout(_ value: ListLayout) {
        var map = layouts
        map[layoutKey] = value.rawValue
        map["default"] = value.rawValue
        layoutsJSON = String(decoding: (try? JSONEncoder().encode(map)) ?? Data(), as: UTF8.self)
    }

    private var title: String {
        switch scope {
        case .all: "전체"
        case .unread: "읽지 않음"
        case .saved: "나중에 읽기"
        case .starred: "별표"
        case .highlights: "하이라이트"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "폴더"
        case .feed(let id): feeds.first { $0.id == id }?.title ?? "피드"
        }
    }

    private var feedIDs: [UUID] {
        switch scope {
        case .folder(let id): (folders.first { $0.id == id }?.feeds ?? []).map(\.id)
        case .feed(let id): [id]
        default: []
        }
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    /// 검색 중이고 "전체 글" 범위를 골랐는가
    private var widened: Bool { isSearching && searchScope == .everything }

    private var query: ArticleQuery {
        var q = ArticleQuery(search: searchText)
        guard !widened else { return q }
        switch scope {
        case .all: q.unreadOnly = unreadOnly && !isSearching
        case .unread: q.unreadOnly = true
        case .saved: q.savedOnly = true
        case .starred, .highlights: q.starredOnly = true
        case .folder, .feed:
            q.feedIDs = feedIDs
            q.unreadOnly = unreadOnly && !isSearching
        }
        // 읽지 않음 / 나중에 읽기 화면은 방금 읽은 글을 화면을 떠날 때까지 남겨 둔다
        q.keepVisible = app.sessionReadKeys
        return q
    }

    var body: some View {
        ArticleListView(query: query, savedFirst: scope == .saved && !widened, layout: layout, selection: $selection)
            .navigationTitle(title)
            .onChange(of: searchText, initial: true) { app.searchQuery = searchText.trimmingCharacters(in: .whitespaces) }
            .searchable(text: $searchText, prompt: "제목·본문 검색")
            .searchScopes($searchScope) {
                if scope != .all {
                    ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("레이아웃", selection: Binding(get: { layout }, set: setLayout)) {
                            ForEach(ListLayout.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                        }
                        if scope != .unread && scope != .starred && scope != .saved {
                            Toggle(isOn: $unreadOnly) { Label("읽지 않은 글만", systemImage: "circle.inset.filled") }
                        }
                        Divider()
                        Button { listenUnread() } label: {
                            Label("읽지 않은 글 연속 듣기", systemImage: "headphones")
                        }
                        Button { confirmMarkAll = true } label: {
                            Label("모두 읽음으로 표시", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: layout.icon)
                    }
                }
            }
            .confirmationDialog("'\(title)'의 글을 모두 읽음으로 표시할까요?", isPresented: $confirmMarkAll,
                                titleVisibility: .visible) {
                Button("모두 읽음") { markAllRead() }
            }
            .onChange(of: scope) {
                app.sessionReadKeys.removeAll()
                searchText = ""
                searchScope = .current
            }
    }

    /// 이 목록의 읽지 않은 글을 최신순으로 이어서 읽는다
    private func listenUnread() {
        let ids = feedIDs
        var descriptor: FetchDescriptor<Article> = switch scope {
        case .folder, .feed: FetchDescriptor(predicate: #Predicate { $0.isRead == false && ids.contains($0.feedID) })
        case .starred: FetchDescriptor(predicate: #Predicate { $0.isStarred })
        case .saved: FetchDescriptor(predicate: #Predicate { $0.savedAt != nil && $0.isRead == false })
        default: FetchDescriptor(predicate: #Predicate { $0.isRead == false })
        }
        descriptor.sortBy = [SortDescriptor(\.publishedAt, order: .reverse)]
        descriptor.fetchLimit = 50
        let articles = (try? context.fetch(descriptor)) ?? []
        guard let first = articles.first else { app.message = "읽지 않은 글이 없습니다."; return }
        first.setRead(true)
        SpeechPlayer.shared.play(first, queue: articles.dropFirst().map(\.key))
    }

    private func markAllRead() {
        let ids = feedIDs
        let descriptor: FetchDescriptor<Article> = switch scope {
        case .folder, .feed: FetchDescriptor(predicate: #Predicate { $0.isRead == false && ids.contains($0.feedID) })
        case .starred: FetchDescriptor(predicate: #Predicate { $0.isRead == false && $0.isStarred })
        case .saved: FetchDescriptor(predicate: #Predicate { $0.isRead == false && $0.savedAt != nil })
        default: FetchDescriptor(predicate: #Predicate { $0.isRead == false })
        }
        for article in (try? context.fetch(descriptor)) ?? [] { article.setRead(true) }
        try? context.save()
    }
}

struct ArticleListView: View {
    let layout: ListLayout
    @Binding var selection: PersistentIdentifier?
    @Query private var articles: [Article]
    @Query private var feeds: [Feed]
    @Query private var highlightMatches: [Highlight]
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    private let isSavedScope: Bool
    private let isSearching: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(query: ArticleQuery, savedFirst: Bool, layout: ListLayout, selection: Binding<PersistentIdentifier?>) {
        self.layout = layout
        isSavedScope = savedFirst
        isSearching = !query.search.trimmingCharacters(in: .whitespaces).isEmpty
        _selection = selection
        let order = savedFirst ? SortDescriptor(\Article.savedAt, order: .reverse)
                               : SortDescriptor(\Article.publishedAt, order: .reverse)
        var descriptor = FetchDescriptor<Article>(predicate: query.predicate, sortBy: [order])
        descriptor.fetchLimit = 1000
        // 목록에 필요 없는 큰 본문 컬럼(본문, 검색용 평문)은 읽지 않는다
        descriptor.propertiesToFetch = [\.key, \.feedID, \.feedTitle, \.title, \.snippet, \.imageURL,
                                        \.publishedAt, \.isRead, \.isStarred, \.contentStatusRaw,
                                        \.imagesCached, \.link, \.translatedTitle, \.savedAt]
        _articles = Query(descriptor)
        let q = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        var hd = FetchDescriptor<Highlight>(
            predicate: #Predicate { !q.isEmpty && ($0.quote.localizedStandardContains(q) || $0.note.localizedStandardContains(q)) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        hd.fetchLimit = 20
        _highlightMatches = Query(hd)
    }

    private var feedsByID: [UUID: Feed] {
        Dictionary(feeds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        Group {
            if articles.isEmpty && highlightMatches.isEmpty {
                if isSearching {
                    ContentUnavailableView.search
                } else if isSavedScope {
                    ContentUnavailableView("나중에 읽을 글이 없습니다", systemImage: "clock",
                                           description: Text("글을 왼쪽으로 밀거나 길게 눌러 담아 두세요."))
                } else {
                    ContentUnavailableView("글이 없습니다", systemImage: "tray",
                                           description: Text("아래로 당겨 새로고침하세요."))
                }
            } else if layout == .grid && highlightMatches.isEmpty {
                grid
            } else {
                list
            }
        }
        .refreshable { await app.refreshAll() }
    }

    private var list: some View {
        let feedMap = feedsByID
        return List(selection: $selection) {
            if !highlightMatches.isEmpty {
                Section("하이라이트·메모") {
                    ForEach(highlightMatches) { h in
                        Button { open(h) } label: { HighlightRow(highlight: h) }
                            .buttonStyle(.plain)
                    }
                }
            }
            ForEach(articles) { article in
                Group {
                    switch layout {
                    case .magazine: MagazineCard(article: article, feed: feedMap[article.feedID])
                    case .titles: TitleRow(article: article, feed: feedMap[article.feedID])
                    default: ListRow(article: article, feed: feedMap[article.feedID])
                    }
                }
                .tag(article.persistentModelID)
                .listRowSeparator(layout == .magazine ? .hidden : .automatic)
                .articleActions(article)
            }
        }
        .listStyle(.plain)
    }

    /// 하이라이트가 있는 글을 열고 그 위치로 이동한다
    private func open(_ h: Highlight) {
        let key = h.articleKey
        if let article = try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first {
            app.pendingHighlightID = h.id.uuidString
            selection = article.persistentModelID
        } else if let url = URL(string: h.articleLink) {
            openURL(url)
        }
    }

    private var grid: some View {
        let feedMap = feedsByID
        let columns = [GridItem(.adaptive(minimum: sizeClass == .compact ? 150 : 220), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(articles) { article in
                    Button {
                        selection = article.persistentModelID
                    } label: {
                        GridCard(article: article, feed: feedMap[article.feedID],
                                 isSelected: selection == article.persistentModelID)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ArticleMenu(article: article) }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - 공통 동작

struct ArticleMenu: View {
    let article: Article
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { article.setRead(!article.isRead) } label: {
            Label(article.isRead ? "읽지 않음으로 표시" : "읽음으로 표시",
                  systemImage: article.isRead ? "circle.inset.filled" : "checkmark.circle")
        }
        Button { article.setStarred(!article.isStarred) } label: {
            Label(article.isStarred ? "별표 해제" : "별표", systemImage: article.isStarred ? "star.slash" : "star")
        }
        Button { article.setSaved(!article.isSaved) } label: {
            Label(article.isSaved ? "나중에 읽기 해제" : "나중에 읽기", systemImage: article.isSaved ? "clock.badge.xmark" : "clock")
        }
        if let url = URL(string: article.link) {
            Button { openURL(url) } label: { Label("Safari에서 열기", systemImage: "safari") }
            ShareLink(item: url) { Label("공유", systemImage: "square.and.arrow.up") }
        }
    }
}

extension View {
    func articleActions(_ article: Article) -> some View {
        self
            .swipeActions(edge: .leading) {
                Button { article.setRead(!article.isRead) } label: {
                    Label(article.isRead ? "안 읽음" : "읽음",
                          systemImage: article.isRead ? "circle.inset.filled" : "checkmark.circle")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing) {
                Button { article.setStarred(!article.isStarred) } label: {
                    Label("별표", systemImage: article.isStarred ? "star.slash" : "star")
                }
                .tint(.orange)
                Button { article.setSaved(!article.isSaved) } label: {
                    Label("나중에", systemImage: article.isSaved ? "clock.badge.xmark" : "clock")
                }
                .tint(.teal)
            }
            .contextMenu { ArticleMenu(article: article) }
    }
}
