import Foundation
import SwiftData

// 모든 모델은 나중에 CloudKit 으로 바꿀 수 있도록 CloudKit 제약을 지킨다:
// 속성은 기본값/옵셔널, unique 제약 없음, 관계는 옵셔널 + inverse.
// 동기화(iCloud Drive 폴더)는 updatedAt 기준 최신 값 우선으로 병합한다.

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""
    var sortOrder: Int = 0
    var updatedAt: Date = Date()
    @Relationship(deleteRule: .nullify, inverse: \Feed.folder)
    var feeds: [Feed]? = []

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }

    var sortedFeeds: [Feed] {
        (feeds ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

enum FullTextMode: Int, CaseIterable, Identifiable, Sendable {
    /// 피드 본문이 짧거나 잘려 있으면 원문에서 추출
    case automatic = 0
    /// 항상 원문에서 추출
    case always = 1
    /// 피드 본문만 사용
    case never = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .automatic: "자동"
        case .always: "항상"
        case .never: "사용 안 함"
        }
    }
}

@Model
final class Feed {
    var id: UUID = UUID()
    var title: String = ""
    var feedURL: String = ""
    var siteURL: String?
    var addedAt: Date = Date()
    var updatedAt: Date = Date()
    var fullTextModeRaw: Int = FullTextMode.automatic.rawValue
    /// 새 글이 올라오면 알림을 보낼지 (기본 꺼짐)
    var notifies: Bool = false
    var folder: Folder?

    init(title: String, feedURL: String, siteURL: String? = nil, folder: Folder? = nil) {
        self.title = title
        self.feedURL = feedURL
        self.siteURL = siteURL
        self.folder = folder
    }

    var fullTextMode: FullTextMode {
        get { FullTextMode(rawValue: fullTextModeRaw) ?? .automatic }
        set { fullTextModeRaw = newValue.rawValue }
    }

    /// 파비콘 (사이트 주소 기준)
    var iconURL: URL? {
        guard let host = URL(string: siteURL ?? feedURL)?.host() else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }
}

enum ContentStatus: Int, Sendable {
    /// 아직 원문 추출을 시도하지 않음
    case pending = 0
    /// 피드에 포함된 본문만 있음 (추출 불필요 판정)
    case feedOnly = 1
    /// 원문에서 전체 본문을 추출함
    case full = 2
    /// 추출 실패 → 피드 본문으로 표시
    case failed = 3
}

@Model
final class Article {
    /// 정규화한 피드 주소 + guid 기반의 안정 키 (기기마다 다른 feedID 를 쓰지 않아 기기 간 동일)
    var key: String = ""
    var feedID: UUID = UUID()
    var feedTitle: String = ""
    var guid: String = ""
    var title: String = ""
    var link: String = ""
    var author: String?
    /// 목록 썸네일/매거진 대표 이미지
    var imageURL: String?
    var feedHTML: String = ""
    /// 검색용 본문 평문 (태그 제거, 앞 2만 자). 목록 쿼리에서는 읽지 않는다.
    var searchText: String = ""
    /// 목록에 보여줄 짧은 요약 (평문)
    var snippet: String = ""
    var fullHTML: String?
    /// 소개 사이트(GeekNews 등)가 가리키는 원래 기사
    var originalURL: String?
    /// 원문 페이지의 댓글 ([ExtractedComment] JSON)
    var commentsJSON: String?
    var extrasFetchedAt: Date?
    var contentStatusRaw: Int = ContentStatus.pending.rawValue
    var imagesCached: Bool = false
    var languageCode: String?
    var translatedTitle: String?
    /// 문단 번호 → 번역문 (JSON). bestHTML 이 바뀌면 무효화한다.
    var translationsJSON: String?
    var publishedAt: Date = Date()
    var fetchedAt: Date = Date()
    var isRead: Bool = false
    var isStarred: Bool = false
    /// 나중에 읽기에 담은 시각 (nil 이면 담지 않은 글)
    var savedAt: Date?
    /// 읽음/별표/나중에 읽기 상태 변경 시각 (동기화 병합용)
    var stateUpdatedAt: Date = Date.distantPast

    init(key: String, feedID: UUID, feedTitle: String, guid: String, title: String, link: String,
         author: String?, feedHTML: String, publishedAt: Date, imageURL: String? = nil) {
        self.key = key
        self.feedID = feedID
        self.feedTitle = feedTitle
        self.guid = guid
        self.title = title
        self.link = link
        self.author = author
        self.feedHTML = feedHTML
        self.snippet = Article.makeSnippet(feedHTML)
        self.publishedAt = publishedAt
        self.imageURL = imageURL
        refreshSearchText()
    }

    var contentStatus: ContentStatus {
        get { ContentStatus(rawValue: contentStatusRaw) ?? .pending }
        set { contentStatusRaw = newValue.rawValue }
    }

    /// 리더에 표시할 본문 (전체 본문 우선)
    var bestHTML: String {
        if let fullHTML, !fullHTML.isEmpty { return fullHTML }
        return feedHTML
    }

    var isCachedOffline: Bool {
        contentStatus != .pending && imagesCached
    }

    var comments: [ExtractedComment] {
        guard let json = commentsJSON, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ExtractedComment].self, from: data)) ?? []
    }

    func apply(_ extras: SiteExtras) {
        if let url = extras.originalURL { originalURL = url }
        // 페이지 구조가 바뀌어 아무것도 못 찾았을 때 기존 댓글을 지우지 않는다
        if !extras.comments.isEmpty || extras.originalURL != nil {
            commentsJSON = (try? JSONEncoder().encode(extras.comments)).map { String(decoding: $0, as: UTF8.self) }
        }
        extrasFetchedAt = Date()
    }

    var translations: [Int: String] {
        get {
            guard let json = translationsJSON, let data = json.data(using: .utf8) else { return [:] }
            return (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
        }
        set {
            translationsJSON = newValue.isEmpty ? nil
                : (try? JSONEncoder().encode(newValue)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    func setRead(_ value: Bool) {
        guard isRead != value else { return }
        isRead = value
        stateUpdatedAt = Date()
    }

    func setStarred(_ value: Bool) {
        guard isStarred != value else { return }
        isStarred = value
        stateUpdatedAt = Date()
    }

    var isSaved: Bool { savedAt != nil }

    func setSaved(_ value: Bool) {
        guard isSaved != value else { return }
        savedAt = value ? Date() : nil
        stateUpdatedAt = Date()
    }

    /// 제목·번역 제목·피드 이름·저자·본문을 한 덩어리 평문으로 만든다.
    /// 제목 등이 바뀌었을 때도 다시 만들며, 비어 있지 않으므로 "아직 만들지 않음"(빈 문자열)과 구분된다.
    func refreshSearchText() {
        let header = [title, translatedTitle, feedTitle, author].compactMap { $0 }.joined(separator: " ")
        searchText = header + "\n" + Article.makeSearchText(bestHTML)
    }

    static func makeSearchText(_ html: String) -> String {
        let text = String(html.prefix(80_000))
            .replacingOccurrences(of: "(?s)<(script|style)[^>]*>.*?</\\1>", with: " ",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .decodingHTMLEntities()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(20_000))
    }

    static func makeSnippet(_ html: String) -> String {
        let text = String(html.prefix(4000))
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .decodingHTMLEntities()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(200))
    }

    /// 주소를 직접 붙여넣어 나중에 읽기에 담은 글은 피드 없이 이 가짜 피드 주소를 키에 쓴다
    static let savedLinkFeedURL = "saved-link"
    static let savedLinksFeedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    var isSavedLink: Bool { key.hasPrefix(Article.savedLinkFeedURL + "|") }

    /// 붙여넣은 주소를 글로 만든다. 본문과 제목은 원문에서 받아 채운다.
    static func savedLink(url: URL) -> Article {
        let link = url.absoluteString
        let a = Article(key: makeKey(feedURL: savedLinkFeedURL, guid: URLNormalizer.normalize(link)),
                        feedID: savedLinksFeedID, feedTitle: url.host() ?? "링크", guid: link,
                        title: link, link: link, author: nil, feedHTML: "", publishedAt: Date())
        return a
    }

    static func makeKey(feedURL: String, guid: String) -> String {
        "\(URLNormalizer.normalize(feedURL))|\(guid)"
    }
}

enum HighlightColor: String, CaseIterable, Identifiable, Sendable {
    case yellow, green, blue, pink, purple
    var id: String { rawValue }
    var hex: String {
        switch self {
        case .yellow: "#ffd60a"
        case .green: "#30d158"
        case .blue: "#64d2ff"
        case .pink: "#ff6482"
        case .purple: "#bf5af2"
        }
    }
}

/// 하이라이트 + 메모. 글 캐시가 지워져도 남도록 글 정보를 함께 저장한다.
/// 위치는 W3C TextQuoteSelector 방식(인용문 + 앞뒤 문맥)으로 저장해 본문이 다시 추출돼도 찾을 수 있다.
@Model
final class Highlight {
    var id: UUID = UUID()
    var articleKey: String = ""
    var articleTitle: String = ""
    var articleLink: String = ""
    var feedTitle: String = ""
    var quote: String = ""
    var prefix: String = ""
    var suffix: String = ""
    var colorRaw: String = HighlightColor.yellow.rawValue
    var note: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(articleKey: String, articleTitle: String, articleLink: String, feedTitle: String,
         quote: String, prefix: String, suffix: String, color: HighlightColor = .yellow) {
        self.articleKey = articleKey
        self.articleTitle = articleTitle
        self.articleLink = articleLink
        self.feedTitle = feedTitle
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.colorRaw = color.rawValue
    }

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }
}

/// 동기화용 삭제 기록. 기기 간 같은 대상을 가리키도록 자연 식별자를 쓴다:
/// "feed:<정규화한 주소>", "folder:<이름>", "highlight:<uuid>", "font:<파일 이름>"
@Model
final class Tombstone {
    var recordID: String = ""
    var deletedAt: Date = Date()

    init(recordID: String) {
        self.recordID = recordID
    }

    /// 삭제 시각이 대상의 마지막 수정 시각보다 늦도록 보장한다 (기기 시계가 조금 어긋나도 삭제가 이기게)
    static func after(_ updatedAt: Date, recordID: String) -> Tombstone {
        let t = Tombstone(recordID: recordID)
        t.deletedAt = max(Date(), updatedAt.addingTimeInterval(0.01))
        return t
    }
}

enum URLNormalizer {
    /// 피드 주소 비교용: 스킴, www, 끝의 / 를 무시한다
    static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - 컨테이너

enum Persistence {
    static let schema = Schema([Folder.self, Feed.self, Article.self, Highlight.self, Tombstone.self])

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let config = ModelConfiguration("RSSReader", schema: schema,
                                        isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer 생성 실패: \(error)")
        }
    }
}
