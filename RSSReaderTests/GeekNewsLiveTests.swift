import Testing
import Foundation
@testable import RSSReader

/// GeekNews(news.hada.io) 피드 점검 (네트워크 필요)
/// 실행: TEST_RUNNER_LIVE_TESTS=1 ./test.sh -only-testing:RSSReaderTests/GeekNewsLiveTests
struct GeekNewsLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_TESTS"] != nil))
    func discoversFeedFromSiteAddress() async throws {
        let result = try await FeedDiscovery.discover("news.hada.io")
        print("GN discover → \(result.feedURL) (\(result.feed.items.count) items)")
        #expect(result.feed.items.count > 10)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_TESTS"] != nil))
    func geekNews() async throws {
        let feed = try await FeedFetcher.fetch("https://news.hada.io/rss/news")
        print("GN title=\(feed.title) site=\(feed.siteURL ?? "nil") items=\(feed.items.count)")
        #expect(feed.items.count > 10)
        #expect(feed.items.allSatisfy { $0.published != nil && !$0.link.isEmpty && !$0.title.isEmpty })

        var truncated = 0
        for (i, item) in feed.items.enumerated() {
            let text = ContentHeuristics.plainText(item.html)
            let isTrunc = ContentHeuristics.looksTruncated(item.html)
            if isTrunc { truncated += 1 }
            if i < 3 || isTrunc && truncated <= 3 {
                print("GN item[\(i)] \(item.title) | author=\(item.author ?? "nil") | len=\(text.count) truncated=\(isTrunc) | img=\(item.imageURL ?? "nil")")
                print("GN   tail: \(text.suffix(80))")
            }
        }
        print("GN truncated=\(truncated)/\(feed.items.count)")

        // 짧은 글 하나는 실제로 원문(토픽 페이지)에서 추출해 본다
        if let item = feed.items.first(where: { ContentHeuristics.looksTruncated($0.html) }) ?? feed.items.first {
            let (html, final) = try await HTMLFetcher.fetch(URL(string: item.link)!)
            let r = try ContentExtractor.extract(html: html, baseURL: final)
            let text = r.map { ContentHeuristics.plainText($0.html) } ?? "nil"
            print("GN extract \(item.link) feedLen=\(ContentHeuristics.plainText(item.html).count) extracted=\(r?.textLength ?? 0)")
            print("GN   HEAD: \(text.prefix(300))")
            print("GN   TAIL: \(text.suffix(300))")
        }
    }
}

struct GeekNewsExtrasLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_TESTS"] != nil))
    func extrasFromLivePage() async throws {
        let (html, final) = try await HTMLFetcher.fetch(URL(string: "https://news.hada.io/topic?id=34811")!)
        let extras = SiteRules.extras(html: html, baseURL: final)
        print("GNX final=\(final) len=\(html.count) hasTopictitle=\(html.contains("topic-title-link")) hasComment=\(html.contains("comment_row"))")
        print("GNX original=\(extras?.originalURL ?? "nil") comments=\(extras?.comments.count ?? -1)")
        if let i = html.range(of: "topictitle") { print("GNX snippet: \(html[i.lowerBound...].prefix(300))") }
        #expect(extras?.originalURL != nil)
    }
}
