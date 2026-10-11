#if DEBUG
import Foundation
import SwiftData

/// 시뮬레이터 확인용: `-demo` 실행 인자로 샘플 구독을 넣는다.
enum DemoData {
    static let opml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="1.0"><body>
      <outline text="Tech" title="Tech">
        <outline type="rss" text="The Verge" xmlUrl="https://www.theverge.com/rss/index.xml" htmlUrl="https://www.theverge.com"/>
        <outline type="rss" text="Ars Technica" xmlUrl="https://feeds.arstechnica.com/arstechnica/index" htmlUrl="https://arstechnica.com"/>
        <outline type="rss" text="Swift.org" xmlUrl="https://www.swift.org/atom.xml" htmlUrl="https://www.swift.org"/>
      </outline>
      <outline text="개발 블로그" title="개발 블로그">
        <outline type="rss" text="토스 기술 블로그" xmlUrl="https://toss.tech/rss.xml" htmlUrl="https://toss.tech"/>
        <outline type="rss" text="우아한형제들 기술블로그" xmlUrl="https://techblog.woowahan.com/feed/" htmlUrl="https://techblog.woowahan.com"/>
      </outline>
      <outline type="rss" text="Cloudflare Blog" xmlUrl="https://blog.cloudflare.com/rss/" htmlUrl="https://blog.cloudflare.com"/>
    </body></opml>
    """

    /// `-layout magazine` 같은 실행 인자 값
    static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func applyLaunchOptions() {
        if let theme = argument("-theme") { UserDefaults.standard.set(theme, forKey: "reader.theme") }
        if let font = argument("-font") { UserDefaults.standard.set(font, forKey: "reader.fontChoice") }
        if let layout = argument("-layout") {
            UserDefaults.standard.set("{\"default\":\"\(layout)\",\"all\":\"\(layout)\"}", forKey: "listLayouts")
        }
    }

    @MainActor
    static func applySyncFolder() {
        if let path = argument("-syncFolder") {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try? SyncManager.shared.setFolder(URL(fileURLWithPath: path))
        }
    }

    /// UI 테스트용: 링크가 없는 고정 글을 가장 최신 글로 넣는다
    @MainActor
    static func insertFixtureArticle(context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("-fixtureArticle") else { return }
        let key = "fixture|ui-test"
        let existing = try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key }))
        existing?.forEach { context.delete($0) }
        // 하이라이트 위치는 인용문 + 앞뒤 문맥으로 찾으므로 문장이 반복되지 않게 만든다
        let animals = ["fox", "owl", "cat", "bear", "wolf", "hare", "deer", "crow", "seal", "lynx"]
        let colors = ["red", "amber", "green", "teal", "blue", "violet", "gray", "ivory"]
        let html = (1...6).map { p in
            let sentences = (1...8).map { i in
                "Sentence \(p)-\(i): the \(colors[(p + i) % colors.count]) \(animals[(p * 3 + i) % animals.count]) crossed river number \(p * 10 + i) at dawn."
            }.joined(separator: " ")
            return "<p>\(sentences)</p>"
        }.joined()
        // 이전 실행에서 만든 하이라이트는 지운다
        try? context.delete(model: Highlight.self, where: #Predicate { $0.articleKey == key })
        // 구독 없는 글은 정리 작업이 지우므로 테스트용 구독을 붙인다
        let feedURL = "https://example.com/ui-test-feed"
        let feed = (try? context.fetch(FetchDescriptor<Feed>(predicate: #Predicate { $0.feedURL == feedURL })).first)
            ?? { let f = Feed(title: "UI 테스트", feedURL: feedURL); f.fullTextMode = .never; context.insert(f); return f }()
        let a = Article(key: key, feedID: feed.id, feedTitle: "UI 테스트", guid: "ui-test", title: "UI 테스트용 글",
                        link: "https://example.com/ui-test", author: nil, feedHTML: html,
                        publishedAt: Date().addingTimeInterval(3600))
        a.contentStatus = .feedOnly
        a.imagesCached = true
        a.languageCode = "en"
        context.insert(a)
        try? context.save()
    }

    @MainActor
    static func seedIfRequested(app: AppModel, context: ModelContext) async {
        if let url = argument("-addFeed") {
            do { _ = try await app.addFeed(urlString: url, folder: nil, context: context) }
            catch { print("[Demo] addFeed 실패: \(error)") }
            await app.cachePending(limit: 10)
        }
        guard ProcessInfo.processInfo.arguments.contains("-demo") else { return }
        let count = (try? context.fetchCount(FetchDescriptor<Feed>())) ?? 0
        if count == 0, let doc = try? OPMLParser.parse(Data(opml.utf8)) {
            _ = try? app.importOPML(doc, context: context)
            await app.refreshAll()
        }
        // -demoSaved: 최신 글 3개를 나중에 읽기에 담는다
        if ProcessInfo.processInfo.arguments.contains("-demoSaved") {
            var d = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            d.fetchLimit = 3
            for a in (try? context.fetch(d)) ?? [] { a.setSaved(true) }
            try? context.save()
        }
    }
}
#endif
