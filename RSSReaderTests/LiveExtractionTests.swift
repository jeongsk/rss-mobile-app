import Testing
import Foundation
@testable import RSSReader

/// 실제 사이트 추출 품질 점검 (네트워크 필요).
/// 실행: TEST_RUNNER_LIVE_TESTS=1 ./test.sh -only-testing:RSSReaderTests/LiveExtractionTests
struct LiveExtractionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_TESTS"] != nil), arguments: [
        "https://www.theverge.com/rss/index.xml",
        "https://feeds.arstechnica.com/arstechnica/index",
        "https://toss.tech/rss.xml",
        "https://techblog.woowahan.com/feed/",
        "https://blog.cloudflare.com/rss/",
    ])
    func extract(_ feedURL: String) async throws {
        let feed = try await FeedFetcher.fetch(feedURL)
        let item = try #require(feed.items.first)
        let (html, final) = try await HTMLFetcher.fetch(URL(string: item.link)!)
        let r = try ContentExtractor.extract(html: html, baseURL: final)
        let text = r.map { ContentHeuristics.plainText($0.html) } ?? "nil"
        let feedText = ContentHeuristics.plainText(item.html)
        print("### \(feedURL)\nfeed=\(feedText.count) extracted=\(r?.textLength ?? 0) truncated=\(ContentHeuristics.looksTruncated(item.html))\nHEAD: \(text.prefix(300))\nTAIL: \(text.suffix(200))\n")
    }
}
