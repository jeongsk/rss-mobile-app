import Foundation
import SwiftData
import SwiftUI

/// 화면에서 쓰는 앱 전역 상태와 동작
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    private(set) var isRefreshing = false
    private(set) var isCaching = false
    var message: String?
    /// 이번 세션에 읽은 글 ("읽지 않은 글만" 목록에서 바로 사라지지 않도록 유지)
    var sessionReadKeys: Set<String> = []
    /// 하이라이트 목록에서 글을 열 때 스크롤할 하이라이트
    var pendingHighlightID: String?
    /// 글 목록에서 지금 검색 중인 말 (리더에서 일치하는 곳을 칠한다)
    var searchQuery = ""
    /// 알림을 눌러 열어야 할 글 (RootView 가 처리하면 비운다)
    var pendingArticleKey: String?
    private var refresherInstance: FeedRefresher?

    init(container: ModelContainer) {
        self.container = container
    }

    private func refresher() async -> FeedRefresher {
        if refresherInstance == nil { refresherInstance = FeedRefresher(modelContainer: container) }
        return refresherInstance!
    }

    func refreshAll(cache: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // 다른 기기에서 추가한 구독을 먼저 받아온 뒤 갱신한다
        await sync()
        let r = await refresher()
        let summary = await r.refreshAll()
        if !summary.failedFeeds.isEmpty {
            message = "갱신 실패: " + summary.failedFeeds.prefix(3).joined(separator: ", ")
                + (summary.failedFeeds.count > 3 ? " 외 \(summary.failedFeeds.count - 3)개" : "")
        }
        await sync()
        if cache { Task { await cachePending(limit: 60) } }
    }

    /// 동기화 폴더가 설정되어 있으면 동기화한다
    func sync() async {
        guard SyncManager.shared.isConfigured else { return }
        let r = await refresher()
        await SyncManager.shared.sync(using: r)
    }

    func refreshIfStale(minutes: Double = 15) async {
        let last = UserDefaults.standard.object(forKey: AppSettingsKeys.lastRefresh) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > minutes * 60 { await refreshAll() } else { await sync() }
    }

    func refresh(feedIDs: [UUID]) async {
        let r = await refresher()
        _ = await r.refresh(feedIDs: feedIDs)
        Task { await cachePending(limit: 30) }
    }

    func cachePending(limit: Int) async {
        guard !isCaching else { return }
        isCaching = true
        defer { isCaching = false }
        let r = await refresher()
        await r.cachePending(limit: limit)
    }

    func saveCaptured(html: String, url: URL, articleKey: String) async -> FeedRefresher.CaptureResult {
        let r = await refresher()
        return await r.saveCaptured(html: html, url: url, key: articleKey)
    }

    func refreshExtras(articleKey: String) async {
        let r = await refresher()
        await r.refreshExtras(key: articleKey)
    }

    func cache(articleKey: String, force: Bool = false) async {
        let r = await refresher()
        await r.cache(key: articleKey, force: force)
    }

    /// 붙여넣은 주소를 나중에 읽기에 담는다. 이미 있는 글이면 다시 담는다. 잘못된 주소면 nil.
    @discardableResult
    func addSavedLink(_ text: String, context: ModelContext) -> Article? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host() != nil else { return nil }
        let article = Article.savedLink(url: url)
        let key = article.key
        if let existing = try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first {
            existing.setSaved(true)
            try? context.save()
            return existing
        }
        article.setSaved(true)
        context.insert(article)
        try? context.save()
        Task { await cache(articleKey: key) }
        return article
    }

    /// 피드의 새 글 알림을 켜고 끈다. 켤 때 알림 권한이 없으면 요청하고, 거부되면 켜지 않는다.
    func setNotifies(_ on: Bool, for feeds: [Feed], context: ModelContext) async {
        if on {
            guard await NotificationService.requestAuthorization() else {
                message = "알림 권한이 꺼져 있습니다. 설정 앱의 이 앱 알림에서 허용해 주세요."
                return
            }
            UserDefaults.standard.set(true, forKey: AppSettingsKeys.notificationsEnabled)
        }
        for feed in feeds where feed.notifies != on {
            feed.notifies = on
            feed.updatedAt = Date()
        }
        try? context.save()
    }

    func backfillSearchText() async {
        let r = await refresher()
        await r.backfillSearchText()
    }

    func purge() async {
        let r = await refresher()
        await r.purgeOrphans()
        await r.purgeOld()
    }

    // MARK: - 구독 관리

    func addFeed(urlString: String, folder: Folder?, context: ModelContext) async throws -> Feed {
        let result = try await FeedDiscovery.discover(urlString)
        let normalized = Self.normalize(result.feedURL)
        let existing = try context.fetch(FetchDescriptor<Feed>())
        if let dup = existing.first(where: { Self.normalize($0.feedURL) == normalized }) {
            return dup
        }
        let feed = Feed(title: result.feed.title.isEmpty ? result.feedURL : FeedTitle.clean(result.feed.title),
                        feedURL: result.feedURL, siteURL: result.feed.siteURL, folder: folder)
        context.insert(feed)
        try context.save()
        await refresh(feedIDs: [feed.id])
        return feed
    }

    /// OPML(Feedly 내보내기) 가져오기. 반환값: (새 피드 수, 건너뛴 중복 수)
    func importOPML(_ doc: OPMLDocument, context: ModelContext) throws -> (added: Int, skipped: Int) {
        let feeds = try context.fetch(FetchDescriptor<Feed>())
        var known = Set(feeds.map { Self.normalize($0.feedURL) })
        var folders = Dictionary(try context.fetch(FetchDescriptor<Folder>()).map { ($0.name, $0) },
                                 uniquingKeysWith: { a, _ in a })
        var added = 0, skipped = 0

        func insert(_ f: OPMLFeed, folder: Folder?) {
            let key = Self.normalize(f.xmlURL)
            guard !known.contains(key) else { skipped += 1; return }
            known.insert(key)
            context.insert(Feed(title: f.title, feedURL: f.xmlURL, siteURL: f.htmlURL, folder: folder))
            added += 1
        }

        for (i, group) in doc.folders.enumerated() {
            let folder: Folder
            if let existing = folders[group.name] {
                folder = existing
            } else {
                folder = Folder(name: group.name, sortOrder: folders.count + i)
                context.insert(folder)
                folders[group.name] = folder
            }
            group.feeds.forEach { insert($0, folder: folder) }
        }
        doc.ungrouped.forEach { insert($0, folder: nil) }
        try context.save()
        return (added, skipped)
    }

    func exportOPML(context: ModelContext) throws -> URL {
        let folders = try context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)]))
        let loose = try context.fetch(FetchDescriptor<Feed>()).filter { $0.folder == nil }
        func map(_ f: Feed) -> OPMLFeed { OPMLFeed(title: f.title, xmlURL: f.feedURL, htmlURL: f.siteURL) }
        let xml = OPMLExporter.export(
            folders: folders.map { ($0.name, $0.sortedFeeds.map(map)) },
            ungrouped: loose.map(map))
        let url = FileManager.default.temporaryDirectory.appending(path: "subscriptions.opml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// iCloud 동기화로 생긴 중복 구독/폴더를 정리한다 (CloudKit 은 unique 제약을 지원하지 않음).
    func dedupe(context: ModelContext) {
        guard let feeds = try? context.fetch(FetchDescriptor<Feed>(sortBy: [SortDescriptor(\.addedAt)])),
              let folders = try? context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)]))
        else { return }
        var seenFolders: [String: Folder] = [:]
        for folder in folders {
            if let keep = seenFolders[folder.name] {
                for feed in folder.feeds ?? [] { feed.folder = keep }
                context.delete(folder)
            } else {
                seenFolders[folder.name] = folder
            }
        }
        var seenFeeds = Set<String>()
        for feed in feeds {
            if !seenFeeds.insert(Self.normalize(feed.feedURL)).inserted { context.delete(feed) }
        }
        try? context.save()
    }

    func deleteHighlight(_ highlight: Highlight, context: ModelContext) {
        context.insert(Tombstone.after(highlight.updatedAt, recordID: "highlight:\(highlight.id.uuidString)"))
        context.delete(highlight)
        try? context.save()
    }

    func deleteFeed(_ feed: Feed, context: ModelContext) {
        context.insert(Tombstone.after(feed.updatedAt, recordID: "feed:\(URLNormalizer.normalize(feed.feedURL))"))
        context.delete(feed)
        try? context.save()
        Task { await purge() }
    }

    /// 폴더만 삭제하고 안의 피드는 "폴더 없음"으로 옮긴다.
    func deleteFolder(_ folder: Folder, context: ModelContext) {
        for feed in folder.feeds ?? [] {
            feed.folder = nil
            feed.updatedAt = Date()
        }
        context.insert(Tombstone.after(folder.updatedAt, recordID: "folder:\(folder.name)"))
        context.delete(folder)
        try? context.save()
    }

    func move(_ feed: Feed, to folder: Folder?, context: ModelContext) {
        feed.folder = folder
        feed.updatedAt = Date()
        try? context.save()
    }

    static func normalize(_ url: String) -> String { URLNormalizer.normalize(url) }
}
