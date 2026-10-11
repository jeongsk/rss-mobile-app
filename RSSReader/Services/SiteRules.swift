import Foundation
import SwiftSoup

/// 원문 페이지에서 본문 외에 추가로 가져오는 정보
struct ExtractedComment: Codable, Sendable, Equatable {
    var author: String
    var date: Date?
    /// 답글 깊이 (0 = 최상위)
    var depth: Int
    var html: String
}

struct SiteExtras: Sendable, Equatable {
    /// 다른 글을 소개하는 사이트(GeekNews 등)의 원래 기사 주소
    var originalURL: String?
    var comments: [ExtractedComment] = []
}

/// 사이트별 추출 규칙. 해당 사이트가 아니면 nil.
enum SiteRules {
    static func supportsExtras(_ link: String) -> Bool {
        guard let host = URL(string: link)?.host()?.lowercased() else { return false }
        return host == "news.hada.io"
    }

    static func extras(html: String, baseURL: URL) -> SiteExtras? {
        guard supportsExtras(baseURL.absoluteString),
              let doc = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return nil }
        return try? geekNews(doc)
    }

    /// GeekNews (news.hada.io/topic?id=…)
    private static func geekNews(_ doc: Document) throws -> SiteExtras {
        var extras = SiteExtras()
        if let link = try doc.select(".topictitle a.topic-title-link").first() {
            let href = try link.absUrl("href")
            if href.hasPrefix("http"), URL(string: href)?.host() != "news.hada.io" { extras.originalURL = href }
        }
        let iso = ISO8601DateFormatter()
        for row in try doc.select("#comment_thread .comment_row").array() {
            guard let contents = try row.select(".comment_contents").first() else { continue }
            try contents.select("script, style, form, button").remove()
            try ContentExtractor.normalize(contents)
            let body = try contents.html().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let author = try row.select(".commentinfo a[href^=/@]").first()?.text() ?? ""
            let date = try row.select(".commentinfo time[datetime]").first()
                .flatMap { iso.date(from: try $0.attr("datetime")) }
            let style = try row.attr("style")
            let depth = style.range(of: #"--depth:\s*(\d+)"#, options: .regularExpression)
                .flatMap { Int(style[$0].filter(\.isNumber)) } ?? 0
            extras.comments.append(ExtractedComment(author: author, date: date, depth: depth, html: body))
        }
        return extras
    }
}

enum FeedTitle {
    /// "GeekNews - 개발/기술/스타트업 뉴스 서비스" → "GeekNews"
    /// 사이트 이름 뒤에 붙은 긴 부제를 뗀다. 앞부분이 너무 짧거나 길면 그대로 둔다.
    static func clean(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" - ", " – ", " — ", " | ", " :: "] {
            guard let range = trimmed.range(of: separator) else { continue }
            let head = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if head.count >= 2, head.count <= 30 { return head }
        }
        return trimmed
    }
}
