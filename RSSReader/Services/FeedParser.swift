import Foundation

struct ParsedFeed: Sendable {
    var title: String = ""
    var siteURL: String?
    var items: [ParsedItem] = []
}

struct ParsedItem: Sendable {
    var guid: String = ""
    var title: String = ""
    var link: String = ""
    var author: String?
    /// 본문 (content:encoded / atom:content 우선, 없으면 description / summary)
    var html: String = ""
    var published: Date?
    /// media:thumbnail / media:content / enclosure / itunes:image
    var imageURL: String?
}

enum FeedParserError: Error, LocalizedError {
    case invalidXML(String)
    case notAFeed

    var errorDescription: String? {
        switch self {
        case .invalidXML(let msg): "피드 XML을 해석할 수 없습니다: \(msg)"
        case .notAFeed: "RSS/Atom 피드가 아닙니다."
        }
    }
}

/// RSS 2.0, RSS 1.0(RDF), Atom 피드 파서
final class FeedParser: NSObject, XMLParserDelegate {
    private var feed = ParsedFeed()
    private var current: ParsedItem?
    private var currentContent: String?   // content:encoded, atom content
    private var currentSummary: String?   // description, summary
    private var text = ""
    private var stack: [String] = []
    private var isFeed = false
    private var isAtom = false

    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            if delegate.isFeed, !delegate.feed.items.isEmpty { return delegate.feed }
            throw FeedParserError.invalidXML(parser.parserError?.localizedDescription ?? "unknown")
        }
        guard delegate.isFeed else { throw FeedParserError.notAFeed }
        return delegate.feed
    }

    private var inItem: Bool { current != nil }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let el = name.lowercased()
        stack.append(el)
        text = ""

        switch el {
        case "rss", "rdf:rdf":
            isFeed = true
        case "feed":
            isFeed = true
            isAtom = true
        case "item", "entry":
            current = ParsedItem()
            currentContent = nil
            currentSummary = nil
        case "media:thumbnail", "itunes:image":
            if inItem, current?.imageURL == nil, let url = attributes["url"] ?? attributes["href"] {
                current?.imageURL = url
            }
        case "media:content", "enclosure":
            let type = attributes["type"] ?? ""
            let isImage = attributes["medium"] == "image" || type.hasPrefix("image/")
            if inItem, isImage, current?.imageURL == nil, let url = attributes["url"] {
                current?.imageURL = url
            }
        case "link" where isAtom:
            let rel = attributes["rel"] ?? "alternate"
            guard rel == "alternate", let href = attributes["href"] else { break }
            if inItem {
                if current?.link.isEmpty == true { current?.link = href }
            } else if feed.siteURL == nil {
                feed.siteURL = href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let el = name.lowercased()
        defer {
            if !stack.isEmpty { stack.removeLast() }
            text = ""
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""

        if inItem {
            switch el {
            case "item", "entry":
                if var item = current {
                    item.html = (currentContent?.isEmpty == false ? currentContent : currentSummary) ?? ""
                    if item.guid.isEmpty { item.guid = item.link.isEmpty ? item.title : item.link }
                    if item.title.isEmpty { item.title = "(제목 없음)" }
                    feed.items.append(item)
                }
                current = nil
            case "title":
                current?.title = value.decodingHTMLEntities()
            case "link" where !isAtom:
                current?.link = value
            case "guid", "id":
                current?.guid = value
            case "content:encoded", "content":
                currentContent = value
            case "description", "summary":
                currentSummary = value
            case "pubdate", "dc:date", "published", "updated", "a10:updated":
                if current?.published == nil || el == "published" || el == "pubdate" {
                    current?.published = DateParser.parse(value) ?? current?.published
                }
            case "author", "dc:creator":
                if !value.isEmpty { current?.author = value }
            case "name" where parent == "author":
                current?.author = value
            default:
                break
            }
            return
        }

        // 피드 메타데이터 (channel / feed 직속)
        switch el {
        case "title" where parent == "channel" || parent == "feed":
            if feed.title.isEmpty { feed.title = value.decodingHTMLEntities() }
        case "link" where !isAtom && parent == "channel":
            if feed.siteURL == nil, !value.isEmpty { feed.siteURL = value }
        default:
            break
        }
    }
}

enum DateParser {
    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
    ]

    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        // "UT", "Z" 같은 비표준 타임존 표기 보정
        var normalized = s.replacingOccurrences(of: " UT", with: " GMT")
        if normalized.hasSuffix(" Z") { normalized = String(normalized.dropLast()) + "GMT" }
        for format in rfc822Formats {
            f.dateFormat = format
            if let d = f.date(from: normalized) { return d }
        }
        return nil
    }
}

extension String {
    /// 제목 등 짧은 텍스트에 섞인 HTML 엔티티와 태그를 정리한다.
    func decodingHTMLEntities() -> String {
        guard contains("&") || contains("<") else { return self }
        var s = replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&#39;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
            "&lsquo;": "‘", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”",
        ]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }
        // 숫자 엔티티 (&#1234; / &#x1F600;)
        let pattern = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let code = UInt32(num, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result += String(Character(scalar))
            } else {
                result += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
