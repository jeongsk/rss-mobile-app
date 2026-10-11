import Testing
import Foundation
import SwiftData
@testable import RSSReader

struct TranslationPlannerTests {
    let html = """
    <h2>Intro</h2>
    <p>Hello <a href="https://x">world</a>.</p>
    <ul><li><p>Nested item</p></li><li>Plain item</li></ul>
    <p><img src="https://x/a.jpg"> Photo caption</p>
    <p>   </p>
    """

    @Test func findsLeafBlocks() {
        let blocks = TranslationPlanner.blocks(in: html)
        #expect(blocks.map(\.text) == ["Intro", "Hello world.", "Nested item", "Plain item", "Photo caption"])
    }

    @Test func appliesBothMode() {
        let blocks = TranslationPlanner.blocks(in: html)
        let map = Dictionary(uniqueKeysWithValues: blocks.map { ($0.index, "번역:" + $0.text) })
        let out = TranslationPlanner.apply(map, to: html, display: .both)
        #expect(out.contains("<a href=\"https://x\">world</a>"))
        #expect(out.contains("<span class=\"tr\" lang=\"ko\">번역:Hello world.</span>"))
        #expect(out.components(separatedBy: "class=\"tr\"").count == 6)
    }

    @Test func appliesTranslatedModeKeepingImages() {
        let blocks = TranslationPlanner.blocks(in: html)
        let map = Dictionary(uniqueKeysWithValues: blocks.map { ($0.index, "번역") })
        let out = TranslationPlanner.apply(map, to: html, display: .translated)
        #expect(out.contains("https://x/a.jpg"))
        #expect(!out.contains("Hello"))
        #expect(TranslationPlanner.apply(map, to: html, display: .original) == html)
    }
}

struct ThumbnailTests {
    @Test func parsesMediaThumbnail() throws {
        let xml = """
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel><title>T</title>
        <item><title>A</title><link>https://e/a</link><media:thumbnail url="https://e/t.jpg"/></item>
        <item><title>B</title><link>https://e/b</link><enclosure url="https://e/audio.mp3" type="audio/mpeg"/>
          <media:content url="https://e/c.png" medium="image"/></item>
        <item><title>C</title><link>https://e/c</link><enclosure url="https://e/e.jpg" type="image/jpeg"/></item>
        </channel></rss>
        """
        let feed = try FeedParser.parse(Data(xml.utf8))
        #expect(feed.items.map(\.imageURL) == ["https://e/t.jpg", "https://e/c.png", "https://e/e.jpg"])
    }

    @Test func firstImageFallbackAndOGImage() throws {
        #expect(ContentHeuristics.firstImage(in: "<p>x<img src=\"/i.png\"></p>", baseURL: "https://e.com/p") == "https://e.com/i.png")
        let body = String(repeating: "<p>Body text sentence, with commas, and more words to read here.</p>", count: 8)
        let html = "<html><head><meta property=\"og:image\" content=\"/og.jpg\"></head><body><article>\(body)</article></body></html>"
        let r = try #require(try ContentExtractor.extract(html: html, baseURL: URL(string: "https://e.com/p")!))
        #expect(r.leadImage == "https://e.com/og.jpg")
    }
}

@MainActor
struct ArticleStateTests {
    @Test func stateChangesBumpTimestamp() {
        let a = Article(key: "k", feedID: UUID(), feedTitle: "f", guid: "g", title: "t", link: "l",
                        author: nil, feedHTML: "<p>Hi &amp; bye</p>", publishedAt: Date())
        #expect(a.snippet == "Hi & bye")
        #expect(a.stateUpdatedAt == .distantPast)
        a.setRead(true)
        #expect(a.isRead && a.stateUpdatedAt > .distantPast)
        a.translations = [0: "안녕", 3: "잘가"]
        #expect(a.translations == [0: "안녕", 3: "잘가"])
    }
}

@MainActor
struct SavedForLaterTests {
    @Test func saveToggleBumpsTimestampAndIsIdempotent() {
        let a = Article(key: "k", feedID: UUID(), feedTitle: "f", guid: "g", title: "t", link: "l",
                        author: nil, feedHTML: "", publishedAt: Date())
        #expect(!a.isSaved && a.savedAt == nil)
        a.setSaved(true)
        let first = a.savedAt
        #expect(a.isSaved && first != nil && a.stateUpdatedAt > .distantPast)
        a.setSaved(true)
        #expect(a.savedAt == first)
        a.setSaved(false)
        #expect(!a.isSaved && a.savedAt == nil)
    }
}

@MainActor
struct SavedLinkTests {
    @Test func addingLinkCreatesFeedlessSavedArticleOnce() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let app = AppModel(container: container)
        let ctx = container.mainContext
        let first = try #require(app.addSavedLink(" https://Example.com/post/ ", context: ctx))
        #expect(first.isSaved && first.isSavedLink && first.title == "https://Example.com/post/")
        first.setSaved(false)
        let again = try #require(app.addSavedLink("https://example.com/post", context: ctx))
        #expect(again === first && again.isSaved)
        #expect(try ctx.fetchCount(FetchDescriptor<Article>()) == 1)
        #expect(app.addSavedLink("not a url", context: ctx) == nil)
        #expect(app.addSavedLink("ftp://example.com/x", context: ctx) == nil)
    }

    @Test func pageTitlePrefersOpenGraph() {
        let html = "<html><head><title>Fallback</title><meta property=\"og:title\" content=\" OG 제목 \"></head></html>"
        #expect(ContentHeuristics.pageTitle(html: html) == "OG 제목")
        #expect(ContentHeuristics.pageTitle(html: "<title>Only</title>") == "Only")
        #expect(ContentHeuristics.pageTitle(html: "<p>x</p>") == nil)
    }
}

@MainActor
struct ArticleSearchTests {
    private func make(_ ctx: ModelContext, guid: String, title: String, html: String, feed: UUID = UUID(),
                      feedTitle: String = "피드", author: String? = nil) -> Article {
        let a = Article(key: "f|\(guid)", feedID: feed, feedTitle: feedTitle, guid: guid, title: title, link: "https://x/\(guid)",
                        author: author, feedHTML: html, publishedAt: Date())
        ctx.insert(a)
        return a
    }

    private func titles(_ ctx: ModelContext, _ q: ArticleQuery) throws -> Set<String> {
        Set(try ctx.fetch(FetchDescriptor<Article>(predicate: q.predicate)).map(\.title))
    }

    @Test func searchesTitleBodyFeedAuthorAndTranslatedTitle() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let ctx = container.mainContext
        defer { withExtendedLifetime(container) {} }
        make(ctx, guid: "1", title: "스위프트 동시성", html: "<p>액터와 <b>Sendable</b> 이야기</p>")
        make(ctx, guid: "2", title: "Other", html: "<script>var hidden='zzz'</script><p>Body about Rust</p>",
             feedTitle: "The Verge", author: "Kim")
        let t = make(ctx, guid: "3", title: "English only", html: "<p>x</p>")
        t.translatedTitle = "영어뿐인 글"
        t.refreshSearchText()
        try ctx.save()
        #expect(try titles(ctx, .init(search: "동시성")) == ["스위프트 동시성"])
        #expect(try titles(ctx, .init(search: "sendable")) == ["스위프트 동시성"])  // 본문, 대소문자 무시
        #expect(try titles(ctx, .init(search: "rust")) == ["Other"])
        #expect(try titles(ctx, .init(search: "verge")) == ["Other"])
        #expect(try titles(ctx, .init(search: "kim")) == ["Other"])
        #expect(try titles(ctx, .init(search: "영어뿐")) == ["English only"])
        #expect(try titles(ctx, .init(search: "zzz")).isEmpty)  // 스크립트 내용은 제외
        #expect(try titles(ctx, .init(search: "  ")).count == 3)
    }

    @Test func scopesCombineWithSearch() throws {
        let container = Persistence.makeContainer(inMemory: true)
        let ctx = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let feedA = UUID(), feedB = UUID()
        let a1 = make(ctx, guid: "a1", title: "A1 swift", html: "", feed: feedA)
        let a2 = make(ctx, guid: "a2", title: "A2 swift", html: "", feed: feedA)
        let b1 = make(ctx, guid: "b1", title: "B1 swift", html: "", feed: feedB)
        a2.setRead(true)
        b1.setStarred(true)
        a1.setSaved(true)
        try ctx.save()
        #expect(try titles(ctx, .init(feedIDs: [feedA], search: "swift")) == ["A1 swift", "A2 swift"])
        #expect(try titles(ctx, .init(feedIDs: [feedA], unreadOnly: true)) == ["A1 swift"])
        #expect(try titles(ctx, .init(starredOnly: true, search: "swift")) == ["B1 swift"])
        #expect(try titles(ctx, .init(savedOnly: true)) == ["A1 swift"])
        #expect(try titles(ctx, .init(unreadOnly: true)) == ["A1 swift", "B1 swift"])
        // 방금 읽은 글은 화면을 떠날 때까지 남는다
        #expect(try titles(ctx, .init(unreadOnly: true, keepVisible: [a2.key])).count == 3)
        // 검색 중에는 남겨 둔 글을 섞지 않는다
        #expect(try titles(ctx, .init(unreadOnly: true, keepVisible: [a2.key], search: "swift")) == ["A1 swift", "B1 swift"])
    }

    @Test func backfillFillsOnlyMissingSearchText() async throws {
        let container = Persistence.makeContainer(inMemory: true)
        let ctx = container.mainContext
        let old = make(ctx, guid: "old", title: "옛 글", html: "<p>본문 단어</p>")
        old.searchText = ""
        try ctx.save()
        await FeedRefresher(modelContainer: container).backfillSearchText()
        #expect(old.searchText.contains("본문 단어") && old.searchText.contains("옛 글"))
    }
}

struct NotificationPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(_ n: Int, feed: UUID, age: TimeInterval = 60) -> NewArticle {
        NewArticle(key: "k\(n)", feedID: feed, feedTitle: "피드 \(feed.uuidString.prefix(2))",
                   title: "글 \(n)", publishedAt: now.addingTimeInterval(-age - Double(n)))
    }

    @Test func onlyNotifyingFeedsFreshAndUnseen() {
        let a = UUID(), b = UUID()
        let plan = NotificationPlanner.plan(
            new: [item(1, feed: a), item(2, feed: b), item(3, feed: a, age: 25 * 3600), item(4, feed: a)],
            notifyFeedIDs: [a], alreadyNotified: ["k4"], now: now)
        #expect(plan.count == 1)
        #expect(plan[0].feedID == a && plan[0].total == 1 && plan[0].items.map(\.key) == ["k1"])
    }

    @Test func groupsAreNewestFirstAndCapped() {
        let feeds = (0..<7).map { _ in UUID() }
        var new: [NewArticle] = []
        for (i, f) in feeds.enumerated() { for j in 0..<5 { new.append(item(i * 10 + j, feed: f, age: Double(i) * 100)) } }
        let plan = NotificationPlanner.plan(new: new, notifyFeedIDs: Set(feeds), alreadyNotified: [], now: now)
        #expect(plan.count == NotificationPlanner.maxGroups)
        #expect(plan[0].feedID == feeds[0])  // 가장 최근 글이 있는 피드가 먼저
        #expect(plan.allSatisfy { $0.items.count == NotificationPlanner.maxTitles && $0.total == 5 })
        #expect(plan.allSatisfy { $0.keys.count == 5 })  // 기록에는 보여주지 않은 글도 포함
        let times = plan[0].items.map(\.publishedAt)
        #expect(times == times.sorted(by: >))
    }

    @Test func trimsOldestNotifiedKeys() {
        let keys = (0..<10).map(String.init)
        #expect(NotificationPlanner.trimmed(keys, limit: 4) == ["6", "7", "8", "9"])
        #expect(NotificationPlanner.trimmed(keys, limit: 50) == keys)
    }
}

@MainActor
struct NotificationActionTests {
    @Test func actionsUpdateArticleAndTapRequestsOpen() throws {
        let container = Persistence.makeContainer(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let ctx = container.mainContext
        let a = Article(key: "f|1", feedID: UUID(), feedTitle: "f", guid: "1", title: "t", link: "https://x/1",
                        author: nil, feedHTML: "", publishedAt: Date())
        ctx.insert(a)
        try ctx.save()
        let app = AppModel(container: container)
        let delegate = NotificationDelegate(app: app)

        delegate.handle(action: NotificationService.actionRead, key: a.key)
        #expect(a.isRead && !a.isSaved)
        delegate.handle(action: NotificationService.actionSave, key: a.key)
        #expect(a.isSaved)
        #expect(app.pendingArticleKey == nil)
        delegate.handle(action: "com.apple.UNNotificationDefaultActionIdentifier", key: a.key)
        #expect(app.pendingArticleKey == a.key)
        delegate.handle(action: NotificationService.actionRead, key: "missing")  // 없는 글은 무시
    }
}

@MainActor
struct HighlightExportTests {
    @Test func markdownGroupsByArticle() {
        let a = Highlight(articleKey: "k1", articleTitle: "글 A", articleLink: "https://a", feedTitle: "피드",
                          quote: "첫 문장\n둘째 줄", prefix: "", suffix: "")
        a.note = "메모"
        let b = Highlight(articleKey: "k1", articleTitle: "글 A", articleLink: "https://a", feedTitle: "피드",
                          quote: "또 다른", prefix: "", suffix: "")
        b.createdAt = a.createdAt.addingTimeInterval(10)
        let md = HighlightExport.markdown([b, a])
        #expect(md.components(separatedBy: "## [글 A](https://a)").count == 2)
        #expect(md.contains("> 첫 문장\n> 둘째 줄\n\n메모"))
        #expect(md.range(of: "첫 문장")!.lowerBound < md.range(of: "또 다른")!.lowerBound)
    }
}

struct SpeechTextTests {
    @Test func splitsSentencesAndUsesTranslation() {
        let html = "<p>First sentence here. Second one!</p><p>Third.</p>"
        let plain = SpeechText.sentences(title: "Title", preparedHTML: html, language: "en")
        #expect(plain.map(\.text) == ["Title", "First sentence here.", "Second one!", "Third."])
        let tr = SpeechText.sentences(title: "Title", preparedHTML: html, language: "en",
                                      translations: [0: "첫 문장입니다. 두 번째!"], translatedTitle: "제목",
                                      useTranslation: true)
        #expect(tr.map(\.text) == ["제목", "첫 문장입니다.", "두 번째!", "Third."])
        #expect(tr.map(\.language) == ["ko", "ko", "ko", "en"])
    }
}
