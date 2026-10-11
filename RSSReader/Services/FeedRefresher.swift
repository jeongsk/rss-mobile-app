import Foundation
import SwiftData
import NaturalLanguage

struct FeedSnapshot: Sendable {
    let id: UUID
    let url: String
    let title: String
}

/// 이번 갱신에서 새로 들어온 글 (알림 후보)
struct NewArticle: Sendable, Equatable {
    var key: String
    var feedID: UUID
    var feedTitle: String
    var title: String
    var publishedAt: Date
}

struct RefreshSummary: Sendable {
    var newArticles = 0
    /// 처음 받은 피드(기존 글이 하나도 없던 피드)의 글은 알림 후보에서 뺀다
    var newItems: [NewArticle] = []
    var failedFeeds: [String] = []
}

enum FeedFetcher {
    static func fetch(_ urlString: String) async throws -> ParsedFeed {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(HTMLFetcher.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8",
                     forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try FeedParser.parse(data)
    }
}

enum LanguageDetector {
    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.dominantLanguage?.rawValue
    }

    static func isKorean(_ code: String?) -> Bool {
        code?.hasPrefix("ko") == true
    }
}

enum AppSettingsKeys {
    static let cacheImages = "cacheImages"
    static let retentionDays = "retentionDays"
    static let backgroundRefresh = "backgroundRefresh"
    /// 처음 열어 읽으면 나중에 읽기에서 뺀다
    static let autoRemoveSaved = "autoRemoveSaved"
    /// 새 글 알림 마스터 스위치 (기기별, 동기화하지 않음)
    static let notificationsEnabled = "notificationsEnabled"
    /// 앱 아이콘에 읽지 않은 글 수를 표시
    static let notifyBadge = "notifyBadge"
    static let lastRefresh = "lastRefresh"
}

/// 피드 갱신과 오프라인 캐시를 담당한다.
///
/// DB 쓰기는 모두 메인 컨텍스트 하나에서 한다. SwiftData 는 저장할 때 객체의 모든 속성을 쓰고,
/// 메인 컨텍스트는 다른 컨텍스트의 저장을 바로 반영하지 않는다. 그래서 두 컨텍스트가 같은 글을 고치면
/// 나중에 저장한 쪽이 다른 쪽 변경(별표·읽음 또는 본문)을 지운다.
/// 네트워크, 본문 추출, 파일 입출력처럼 무거운 일만 메인 스레드 밖에서 한다.
@MainActor
final class FeedRefresher {
    let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private func freshContext() -> ModelContext {
        modelContainer.mainContext
    }

    /// 모든 피드를 갱신한다.
    func refreshAll() async -> RefreshSummary {
        let ctx = freshContext()
        let feeds = (try? ctx.fetch(FetchDescriptor<Feed>())) ?? []
        let snapshots = feeds.map { FeedSnapshot(id: $0.id, url: $0.feedURL, title: $0.title) }
        let summary = await refresh(snapshots, ctx: ctx)
        UserDefaults.standard.set(Date(), forKey: AppSettingsKeys.lastRefresh)
        return summary
    }

    func refresh(feedIDs: [UUID]) async -> RefreshSummary {
        let ctx = freshContext()
        let feeds = (try? ctx.fetch(FetchDescriptor<Feed>(predicate: #Predicate { feedIDs.contains($0.id) }))) ?? []
        return await refresh(feeds.map { FeedSnapshot(id: $0.id, url: $0.feedURL, title: $0.title) }, ctx: ctx)
    }

    private func refresh(_ snapshots: [FeedSnapshot], ctx: ModelContext) async -> RefreshSummary {
        var summary = RefreshSummary()
        let results = await withTaskGroup(of: (FeedSnapshot, Result<ParsedFeed, any Error>).self) { group in
            var iterator = snapshots.makeIterator()
            var out: [(FeedSnapshot, Result<ParsedFeed, any Error>)] = []
            func addNext() {
                guard let snap = iterator.next() else { return }
                group.addTask {
                    do { return (snap, .success(try await FeedFetcher.fetch(snap.url))) }
                    catch { return (snap, .failure(error)) }
                }
            }
            for _ in 0..<6 { addNext() }
            while let result = await group.next() {
                out.append(result)
                addNext()
            }
            return out
        }

        for (snap, result) in results {
            switch result {
            case .success(let parsed):
                let (added, items) = ingest(parsed, into: snap, ctx: ctx)
                summary.newArticles += added
                summary.newItems += items
            case .failure:
                summary.failedFeeds.append(snap.title)
            }
        }
        try? ctx.save()
        await NotificationService.deliver(summary.newItems, context: ctx)
        return summary
    }

    private func ingest(_ parsed: ParsedFeed, into snap: FeedSnapshot, ctx: ModelContext) -> (added: Int, items: [NewArticle]) {
        let feedID = snap.id
        let existing = (try? ctx.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.feedID == feedID }))) ?? []
        var keys = Set(existing.map(\.key))

        // 피드 제목이 비어 있었다면 채운다
        if let feed = try? ctx.fetch(FetchDescriptor<Feed>(predicate: #Predicate { $0.id == feedID })).first {
            if feed.title.isEmpty || feed.title == feed.feedURL, !parsed.title.isEmpty { feed.title = FeedTitle.clean(parsed.title) }
            if feed.siteURL == nil { feed.siteURL = parsed.siteURL }
        }

        var added = 0
        var items: [NewArticle] = []
        let isFirstFetch = existing.isEmpty
        let retention = retentionCutoff()
        for item in parsed.items {
            let key = Article.makeKey(feedURL: snap.url, guid: item.guid)
            guard !keys.contains(key) else { continue }
            let published = item.published ?? Date()
            if let retention, published < retention { continue }
            let article = Article(
                key: key, feedID: feedID,
                feedTitle: parsed.title.isEmpty ? snap.title : (snap.title.isEmpty ? parsed.title : snap.title),
                guid: item.guid, title: item.title, link: item.link, author: item.author,
                feedHTML: item.html, publishedAt: min(published, Date()),
                imageURL: item.imageURL ?? ContentHeuristics.firstImage(in: item.html, baseURL: item.link))
            ctx.insert(article)
            keys.insert(key)
            added += 1
            if !isFirstFetch {
                items.append(NewArticle(key: key, feedID: feedID, feedTitle: article.feedTitle,
                                        title: article.title, publishedAt: article.publishedAt))
            }
        }
        return (added, items)
    }

    private func retentionCutoff() -> Date? {
        let days = UserDefaults.standard.integer(forKey: AppSettingsKeys.retentionDays)
        guard days > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }

    // MARK: - 오프라인 캐시

    /// 아직 캐시되지 않은 글의 전체 본문/이미지를 저장한다. 최신 글부터 처리한다.
    @discardableResult
    func cachePending(limit: Int, until deadline: Date? = nil) async -> Int {
        let ctx = freshContext()
        let pending = ContentStatus.pending.rawValue
        // 나중에 읽기에 담은 글을 먼저 저장한다
        var savedFirst = FetchDescriptor<Article>(
            predicate: #Predicate { $0.savedAt != nil && ($0.contentStatusRaw == pending || $0.imagesCached == false) },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        savedFirst.fetchLimit = limit
        var articles = (try? ctx.fetch(savedFirst)) ?? []
        if articles.count < limit {
            var descriptor = FetchDescriptor<Article>(
                predicate: #Predicate { $0.savedAt == nil && ($0.contentStatusRaw == pending || $0.imagesCached == false) },
                sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            descriptor.fetchLimit = limit - articles.count
            articles += (try? ctx.fetch(descriptor)) ?? []
        }
        var done = 0
        for article in articles {
            if Task.isCancelled { break }
            if let deadline, Date() > deadline { break }
            await cache(article, ctx: ctx)
            done += 1
            if done % 5 == 0 { try? ctx.save() }
        }
        try? ctx.save()
        return done
    }

    /// 특정 글을 즉시 캐시한다 (리더에서 열 때).
    func cache(key: String, force: Bool = false) async {
        let ctx = freshContext()
        guard let article = try? ctx.fetch(
            FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first else { return }
        if force { article.contentStatus = .pending }
        await cache(article, ctx: ctx)
        try? ctx.save()
    }

    private func cache(_ article: Article, ctx: ModelContext) async {
        if article.contentStatus == .pending {
            let feedID = article.feedID
            let mode = (try? ctx.fetch(FetchDescriptor<Feed>(predicate: #Predicate { $0.id == feedID })).first)?
                .fullTextMode ?? (article.isSavedLink ? .always : .automatic)
            let feedHTML = article.feedHTML
            let needsFull = switch mode {
            case .always: true
            case .never: false
            case .automatic: ContentHeuristics.looksTruncated(feedHTML)
            }
            if needsFull, let url = URL(string: article.link) {
                do {
                    let (html, finalURL) = try await HTMLFetcher.fetch(url)
                    // 본문 추출(HTML 파싱)은 메인 스레드 밖에서
                    let (extracted, feedLength, extras, pageTitle) = await Task.detached(priority: .utility) {
                        (try? ContentExtractor.extract(html: html, baseURL: finalURL),
                         ContentHeuristics.plainText(feedHTML).count,
                         SiteRules.extras(html: html, baseURL: finalURL),
                         ContentHeuristics.pageTitle(html: html))
                    }.value
                    if article.isSavedLink, article.title == article.link, let pageTitle { article.title = pageTitle }
                    if let extras { article.apply(extras) }
                    if let extracted, extracted.textLength > Int(Double(feedLength) * 1.1) {
                        article.fullHTML = extracted.html
                        article.contentStatus = .full
                        article.translationsJSON = nil
                        if article.imageURL == nil {
                            article.imageURL = extracted.leadImage
                                ?? ContentHeuristics.firstImage(in: extracted.html, baseURL: finalURL.absoluteString)
                        }
                    } else {
                        article.contentStatus = .failed
                    }
                } catch {
                    // 네트워크 오류는 다음 기회에 재시도할 수 있도록 pending 유지
                    if (error as? URLError)?.code == .notConnectedToInternet { return }
                    article.contentStatus = .failed
                }
            } else {
                article.contentStatus = .feedOnly
            }
            if article.languageCode == nil {
                let text = article.title + " " + ContentHeuristics.plainText(article.bestHTML)
                article.languageCode = LanguageDetector.detect(text)
            }
            article.refreshSearchText()
        }

        if !article.imagesCached {
            if UserDefaults.standard.object(forKey: AppSettingsKeys.cacheImages) as? Bool ?? true {
                var urls = ImageCache.imageURLs(in: article.bestHTML)
                if let thumb = article.imageURL, !urls.contains(thumb) { urls.insert(thumb, at: 0) }
                await ImageCache.download(urls)
            }
            article.imagesCached = true
        }
    }

    /// 검색용 평문이 없는 기존 글을 채운다 (업데이트 직후 한 번). 한 번에 많이 처리하지 않고 틈틈이 양보한다.
    func backfillSearchText() async {
        let ctx = freshContext()
        while !Task.isCancelled {
            var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.searchText == "" })
            descriptor.fetchLimit = 100
            guard let batch = try? ctx.fetch(descriptor), !batch.isEmpty else { return }
            for a in batch { a.refreshSearchText() }
            try? ctx.save()
            await Task.yield()
        }
    }

    enum CaptureResult: Equatable { case saved, notFound, blocked, missing }

    /// 사용자가 앱 안 브라우저에서 연 페이지를 리더 본문으로 저장한다.
    /// 브라우저 확인을 사용자가 직접 통과한 페이지이므로 사이트 정책을 우회하지 않는다.
    func saveCaptured(html: String, url: URL, key: String) async -> CaptureResult {
        let ctx = freshContext()
        guard let article = try? ctx.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first
        else { return .missing }
        if HTMLFetcher.isBrowserCheck(html, url: url) { return .blocked }
        let (extracted, extras) = await Task.detached(priority: .userInitiated) {
            (try? ContentExtractor.extract(html: html, baseURL: url), SiteRules.extras(html: html, baseURL: url))
        }.value
        if let extras { article.apply(extras) }
        guard let extracted else { try? ctx.save(); return .notFound }
        article.fullHTML = extracted.html
        article.contentStatus = .full
        article.translationsJSON = nil
        article.translatedTitle = nil
        if article.imageURL == nil {
            article.imageURL = extracted.leadImage ?? ContentHeuristics.firstImage(in: extracted.html, baseURL: url.absoluteString)
        }
        article.imagesCached = false
        try? ctx.save()
        // 이미지도 오프라인용으로 저장
        await cache(article, ctx: ctx)
        try? ctx.save()
        return .saved
    }

    /// 원문 링크·댓글만 다시 가져온다 (댓글은 시간이 지나며 늘어난다)
    func refreshExtras(key: String) async {
        let ctx = freshContext()
        guard let article = try? ctx.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first,
              SiteRules.supportsExtras(article.link), let url = URL(string: article.link) else { return }
        // 실패해도 30분 동안은 다시 시도하지 않는다 (막힌 사이트에 요청을 반복하지 않도록)
        article.extrasFetchedAt = Date()
        guard let (html, finalURL) = try? await HTMLFetcher.fetch(url) else { try? ctx.save(); return }
        let extras = await Task.detached(priority: .utility) { SiteRules.extras(html: html, baseURL: finalURL) }.value
        guard let extras else { return }
        article.apply(extras)
        try? ctx.save()
    }

    // MARK: - 정리

    /// 보관 기간이 지난 (별표·나중에 읽기 아닌) 글을 삭제한다.
    func purgeOld() {
        guard let cutoff = retentionCutoff() else { return }
        let ctx = freshContext()
        let highlighted = Set(((try? ctx.fetch(FetchDescriptor<Highlight>())) ?? []).map(\.articleKey))
        let old = (try? ctx.fetch(FetchDescriptor<Article>(
            predicate: #Predicate { $0.publishedAt < cutoff && $0.isStarred == false && $0.savedAt == nil }))) ?? []
        for article in old where !highlighted.contains(article.key) {
            ctx.delete(article)
        }
        try? ctx.save()
    }

    /// 구독이 삭제된 피드의 글을 정리한다.
    func purgeOrphans() {
        let ctx = freshContext()
        let feedIDs = Set(((try? ctx.fetch(FetchDescriptor<Feed>())) ?? []).map(\.id))
        let articles = (try? ctx.fetch(FetchDescriptor<Article>())) ?? []
        let highlighted = Set(((try? ctx.fetch(FetchDescriptor<Highlight>())) ?? []).map(\.articleKey))
        for a in articles where !feedIDs.contains(a.feedID) && !a.isStarred && !a.isSaved && !highlighted.contains(a.key) {
            ctx.delete(a)
        }
        try? ctx.save()
    }
}
