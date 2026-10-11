import SwiftUI
import SwiftData

enum SidebarItem: Hashable, Codable {
    case all, unread, saved, starred, highlights
    case folder(UUID)
    case feed(UUID)

    /// 레이아웃 등 화면별 설정을 저장할 때 쓰는 키
    var storageKey: String {
        switch self {
        case .all: "all"
        case .unread: "unread"
        case .saved: "saved"
        case .starred: "starred"
        case .highlights: "highlights"
        case .folder(let id): "folder.\(id.uuidString)"
        case .feed(let id): "feed.\(id.uuidString)"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var sidebarSelection: SidebarItem? = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-sidebar") { return nil }
        if args.contains("-highlights") { return .highlights }
        if args.contains("-saved") { return .saved }
        if let id = DemoData.argument("-feedID").flatMap(UUID.init) { return .feed(id) }
        return .all
    }()
    @State private var articleSelection: PersistentIdentifier?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// 선택한 글이 그 사이 삭제됐으면(구독 삭제, 보관 기간 정리 등) nil.
    /// 삭제된 모델의 속성을 읽으면 SwiftData 가 앱을 종료시키므로 반드시 다시 조회한다.
    private func existingArticle(_ id: PersistentIdentifier) -> Article? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        guard let article = try? context.fetch(descriptor).first, !article.isDeleted else { return nil }
        return article
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } content: {
            if sidebarSelection == .highlights {
                HighlightListView(selection: $articleSelection)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 520)
            } else if let scope = sidebarSelection {
                ArticleListContainer(scope: scope, selection: $articleSelection)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 520)
            } else {
                ContentUnavailableView("구독을 선택하세요", systemImage: "list.bullet")
            }
        } detail: {
            if let id = articleSelection, let article = existingArticle(id) {
                ReaderView(article: article)
                    .id(id)
            } else {
                ContentUnavailableView("읽을 글을 선택하세요", systemImage: "doc.text")
            }
        }
        .overlay(alignment: .bottom) { MiniPlayer() }
        .animation(.spring(duration: 0.3), value: SpeechPlayer.shared.isActive)
        .onChange(of: sidebarSelection) { articleSelection = nil }
        .onChange(of: app.pendingArticleKey, initial: true) { _, key in
            guard let key else { return }
            app.pendingArticleKey = nil
            openArticle(key: key)
        }
        #if DEBUG
        .task {
            // 캡처 자동화: -openFirst 로 첫 글을 연다
            guard ProcessInfo.processInfo.arguments.contains("-openFirst") else { return }
            for _ in 0..<60 {
                var d = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
                d.fetchLimit = 1
                if let first = try? context.fetch(d).first {
                    articleSelection = first.persistentModelID
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await app.refreshIfStale() }
            case .background:
                BackgroundTasks.scheduleAll()
                Task { await NotificationService.updateBadge(context) }
                // 앱을 닫을 때 내 변경 사항을 동기화 폴더에 써 둔다
                let task = UIApplication.shared.beginBackgroundTask()
                Task {
                    await app.sync()
                    UIApplication.shared.endBackgroundTask(task)
                }
            default:
                break
            }
        }
        .alert("알림", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) {
            Button("확인") { app.message = nil }
        } message: {
            Text(app.message ?? "")
        }
    }

    /// 알림에서 온 글을 연다. 그 글이 목록에 있도록 "전체"로 옮긴 뒤 선택한다.
    private func openArticle(key: String) {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let article = try? context.fetch(descriptor).first else { return }
        let id = article.persistentModelID
        if sidebarSelection != .all { sidebarSelection = .all }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            articleSelection = id
        }
    }
}
