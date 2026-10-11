import Testing
import SwiftData
import Foundation
@testable import RSSReader

struct SiteRulesTests {
    @Test func geekNewsOriginalLinkAndComments() throws {
        let extras = try #require(SiteRules.extras(html: GeekNewsSample.html, baseURL: GeekNewsSample.url))
        #expect(extras.originalURL == GeekNewsSample.originalURL)
        #expect(extras.comments.count == 2)
        let first = try #require(extras.comments.first)
        #expect(first.author == "샘플봇")
        #expect(first.depth == 0)
        #expect(first.date != nil)
        #expect(first.html.contains("Hacker News 의견들"))
        #expect(first.html.contains("href=\"\(GeekNewsSample.hnURL)\""))
        #expect(!first.html.contains("class="))
        #expect(!first.html.contains("track()"))
        #expect(extras.comments[1].author == "읽는사람")
        #expect(extras.comments[1].depth == 1)
    }

    @Test func geekNewsBodyStillExtracted() throws {
        let r = try #require(try ContentExtractor.extract(html: GeekNewsSample.html, baseURL: GeekNewsSample.url))
        #expect(r.html.contains("OPML 파일로 내보낼 수"))
        #expect(!r.html.contains("Hacker News 의견들"))  // 댓글은 본문에 섞이지 않는다
    }

    @Test func otherSitesHaveNoExtras() {
        #expect(SiteRules.extras(html: "<html></html>", baseURL: URL(string: "https://example.com/a")!) == nil)
    }

    @Test(arguments: [
        ("GeekNews - 개발/기술/스타트업 뉴스 서비스", "GeekNews"),
        ("Ars Technica", "Ars Technica"),
        ("The Verge", "The Verge"),
        ("A - b", "A - b"),
        ("우아한형제들 기술블로그 | 우아한형제들", "우아한형제들 기술블로그"),
    ])
    func cleansFeedTitle(_ input: String, _ expected: String) {
        #expect(FeedTitle.clean(input) == expected)
    }
}

struct BrowserCheckTests {
    @Test func detectsGeekNewsCheckPage() {
        let html = "<!doctype html><html><head><title>브라우저 확인 | GeekNews</title></head><body>확인</body></html>"
        #expect(HTMLFetcher.isBrowserCheck(html, url: URL(string: "https://news.hada.io/topic?id=1")!))
        #expect(HTMLFetcher.isBrowserCheck("", url: URL(string: "https://news.hada.io/topic_browser_check?return=x")!))
        #expect(HTMLFetcher.isBrowserCheck("<html><head><title>Just a moment...</title>", url: URL(string: "https://x.com/a")!))
    }

    @Test func normalPagesAreNotChecks() throws {
        #expect(!HTMLFetcher.isBrowserCheck(GeekNewsSample.html, url: GeekNewsSample.url))
        #expect(!HTMLFetcher.isBrowserCheck("<html><head><title>블로그</title></head><body>글</body></html>",
                                            url: URL(string: "https://blog.example/p")!))
    }

    @Test func emptyExtrasKeepExistingComments() {
        let a = Article(key: "k", feedID: UUID(), feedTitle: "f", guid: "g", title: "t", link: "l",
                        author: nil, feedHTML: "", publishedAt: Date())
        a.apply(SiteExtras(originalURL: "https://o", comments: [ExtractedComment(author: "a", date: nil, depth: 0, html: "<p>c</p>")]))
        a.apply(SiteExtras())
        #expect(a.comments.count == 1)
        #expect(a.originalURL == "https://o")
    }
}

@MainActor
struct CaptureTests {
    func setup() throws -> (ModelContainer, Article) {
        let container = Persistence.makeContainer(inMemory: true)
        let a = Article(key: "gn", feedID: UUID(), feedTitle: "GeekNews", guid: "g", title: "RSS가 여전히 쓸모 있는 이유",
                        link: GeekNewsSample.url.absoluteString, author: nil, feedHTML: "<p>짧은 요약...</p>", publishedAt: Date())
        a.contentStatus = .failed
        container.mainContext.insert(a)
        try container.mainContext.save()
        UserDefaults.standard.set(false, forKey: AppSettingsKeys.cacheImages)
        return (container, a)
    }

    @Test func savesCapturedPageAsReaderContent() async throws {
        let (container, a) = try setup()
        defer { UserDefaults.standard.set(true, forKey: AppSettingsKeys.cacheImages) }
        let result = await FeedRefresher(modelContainer: container)
            .saveCaptured(html: GeekNewsSample.html, url: GeekNewsSample.url, key: "gn")
        #expect(result == .saved)
        #expect(a.contentStatus == .full)
        #expect(a.fullHTML?.contains("OPML 파일로 내보낼 수") == true)
        #expect(a.originalURL == GeekNewsSample.originalURL)
        #expect(!a.comments.isEmpty)
    }

    @Test func refusesBrowserCheckPage() async throws {
        let (container, a) = try setup()
        defer { UserDefaults.standard.set(true, forKey: AppSettingsKeys.cacheImages) }
        let result = await FeedRefresher(modelContainer: container).saveCaptured(
            html: "<html><head><title>브라우저 확인 | GeekNews</title></head></html>",
            url: URL(string: "https://news.hada.io/topic_browser_check?return=x")!, key: "gn")
        #expect(result == .blocked)
        #expect(a.contentStatus == .failed && a.fullHTML == nil)
    }
}
