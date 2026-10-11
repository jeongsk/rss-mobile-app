import Foundation
import SwiftSoup

struct ExtractedContent: Sendable {
    var html: String
    var textLength: Int
    /// og:image / twitter:image
    var leadImage: String?
}

/// Readability 방식의 본문 추출기 (순수 Swift, 백그라운드에서도 동작)
///
/// 점수 계산·정규식·형제 병합 기준은 Mozilla Readability.js 를 참고해 고쳐 쓴 것이다.
/// Copyright (c) 2010 Arc90 Inc, Apache License 2.0 — THIRD_PARTY_NOTICES.md 참고.
/// https://github.com/mozilla/readability
enum ContentExtractor {
    private static let removeSelectors =
        "script, style, noscript, iframe, form, button, input, select, textarea, nav, footer, aside, svg, canvas, link, meta, template, dialog, [hidden], [aria-hidden=true]:not(img):not(figure)"

    private static let unlikely = try! NSRegularExpression(
        pattern: "-ad-|ad-break|agegate|banner|breadcrumb|combx|comment|community|cookie|cover-wrap|disqus|extra|gdpr|footer|header|legends|menu|modal|newsletter|pager|pagination|popup|promo|related|remark|replies|rss|share|shoutbox|sidebar|skyscraper|social|sponsor|subscribe|supplemental|tags|toolbar|yom-remote",
        options: .caseInsensitive)
    private static let maybe = try! NSRegularExpression(
        pattern: "and|article|body|column|content|main|post|entry|story|shadow",
        options: .caseInsensitive)
    private static let positive = try! NSRegularExpression(
        pattern: "article|body|content|entry|hentry|h-entry|main|page|post|text|blog|story",
        options: .caseInsensitive)
    private static let negative = try! NSRegularExpression(
        pattern: "-ad-|hidden|^hid$| hid$| hid |^hid |banner|combx|comment|com-|contact|foot|footer|footnote|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|tool|widget",
        options: .caseInsensitive)

    /// 본문 안의 작성자/날짜/광고/공유/구독 유도 블록 (짧은 블록만 제거)
    private static let noise = try! NSRegularExpression(
        pattern: "byline|timestamp|dateline|author|\\bbio\\b|native-ad|ad-rail|\\brail\\b|\\bcta\\b|cta--|newsletter|follow|recirc|share|subscribe|page-header|header-pattern|content-warning|(^|\\s)hidden(\\s|$)",
        options: .caseInsensitive)

    /// 사이트별 본문 컨테이너로 자주 쓰이는 선택자 (점수 계산보다 우선)
    private static let knownBodySelectors = [
        "[itemprop=articleBody]", "article .entry-content", ".entry-content", ".post-content",
        ".article-body", "#article-body", ".article-content", ".post-body", ".story-body",
        "#articleBodyContents", "#dic_area", "#newsct_article", ".tt_article_useless_p_margin",
        "#mArticle .article_view", ".se-main-container", "article",
    ]

    static func extract(html: String, baseURL: URL) throws -> ExtractedContent? {
        let doc = try SwiftSoup.parse(html, baseURL.absoluteString)
        guard let body = doc.body() else { return nil }
        let leadImage = try doc.select("meta[property=og:image], meta[name=twitter:image]").first()
            .map { try $0.absUrl("content") }.flatMap { $0.isEmpty ? nil : $0 }

        try body.select(removeSelectors).remove()
        var result = try findContent(body)
        result?.leadImage = leadImage
        return result
    }

    private static func findContent(_ body: Element) throws -> ExtractedContent? {

        // 1) 알려진 본문 컨테이너 (페이지 문단 텍스트의 절반 이상을 담고 있을 때만 신뢰)
        let totalParagraphText = try paragraphTextLength(body)
        for selector in knownBodySelectors {
            let matches = try body.select(selector)
            guard matches.size() == 1, let el = matches.first() else { continue }
            let len = try el.text().count
            let pLen = try paragraphTextLength(el)
            if len >= 300, Double(pLen) >= Double(totalParagraphText) * 0.5 {
                try clean(el)
                return try finish(el)
            }
        }

        // 2) 불필요한 블록 제거 후 점수 계산
        try removeUnlikely(body)
        guard let (top, scores) = try scoreCandidates(body) else { return nil }
        let container = try gatherSiblings(top, scores: scores)
        try clean(container)
        return try finish(container)
    }

    private static func paragraphTextLength(_ el: Element) throws -> Int {
        try el.select("p").array().reduce(0) { $0 + (try $1.text().count) }
    }

    private static func finish(_ el: Element) throws -> ExtractedContent? {
        try normalize(el)
        let text = try el.text()
        guard text.count >= 140 else { return nil }
        return ExtractedContent(html: try el.html(), textLength: text.count, leadImage: nil)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func classAndID(_ el: Element) -> String {
        ((try? el.className()) ?? "") + " " + el.id()
    }

    private static func removeUnlikely(_ root: Element) throws {
        for el in try root.select("*").array() {
            let tag = el.tagName()
            if ["body", "html", "article", "main", "a", "img", "figure", "p"].contains(tag) { continue }
            let ci = classAndID(el)
            guard ci.count > 1 else { continue }
            if matches(unlikely, ci) && !matches(maybe, ci) && el.parent() != nil {
                try el.remove()
            }
        }
    }

    private static func classWeight(_ el: Element) -> Double {
        var w = 0.0
        let cls = (try? el.className()) ?? ""
        let id = el.id()
        for s in [cls, id] where !s.isEmpty {
            if matches(negative, s) { w -= 25 }
            if matches(positive, s) { w += 25 }
        }
        return w
    }

    private static func baseScore(_ el: Element) -> Double {
        switch el.tagName() {
        case "div", "article", "section", "main": 5
        case "pre", "td", "blockquote": 3
        case "address", "ol", "ul", "dl", "dd", "dt", "li", "form": -3
        case "h1", "h2", "h3", "h4", "h5", "h6", "th": -5
        default: 0
        }
    }

    static func linkDensity(_ el: Element) throws -> Double {
        let total = try el.text().count
        guard total > 0 else { return 0 }
        var linkLen = 0
        for a in try el.select("a").array() { linkLen += try a.text().count }
        return Double(linkLen) / Double(total)
    }

    private static func scoreCandidates(_ root: Element) throws -> (Element, [ObjectIdentifier: Double])? {
        var scores: [ObjectIdentifier: (el: Element, score: Double)] = [:]

        func add(_ el: Element?, _ value: Double) {
            guard let el else { return }
            let key = ObjectIdentifier(el)
            if scores[key] == nil {
                scores[key] = (el, baseScore(el) + classWeight(el))
            }
            scores[key]!.score += value
        }

        let blockTags: Set<String> = ["p", "div", "section", "article", "blockquote", "pre", "table", "ul", "ol", "figure", "h1", "h2", "h3", "h4", "h5", "h6"]
        var paragraphs = try root.select("p, pre, td, blockquote").array()
        // 블록 자식이 없는 div는 문단으로 취급
        for div in try root.select("div").array()
        where !div.children().array().contains(where: { blockTags.contains($0.tagName()) }) {
            paragraphs.append(div)
        }

        for p in paragraphs {
            let text = try p.text()
            guard text.count >= 25 else { continue }
            var score = 1.0
            score += Double(text.filter { $0 == "," || $0 == "，" || $0 == "、" }.count)
            score += min(Double(text.count) / 100.0, 3.0)
            add(p.parent(), score)
            add(p.parent()?.parent(), score / 2)
            add(p.parent()?.parent()?.parent(), score / 3)
        }

        var best: (el: Element, score: Double)?
        for (_, entry) in scores {
            let final = entry.score * (1 - (try linkDensity(entry.el)))
            if best == nil || final > best!.score { best = (entry.el, final) }
            scores[ObjectIdentifier(entry.el)]!.score = final
        }
        guard let best else { return nil }
        return (best.el, scores.mapValues(\.score))
    }

    /// 최고 점수 노드의 형제 중 본문으로 보이는 것을 합친다.
    private static func gatherSiblings(_ top: Element, scores topScores: [ObjectIdentifier: Double]) throws -> Element {
        guard let parent = top.parent() else { return top }
        let topScore = topScores[ObjectIdentifier(top)] ?? 0
        let threshold = max(10, topScore * 0.2)
        let siblings = parent.children().array()
        guard siblings.count > 1 else { return top }

        let wrapper = try Element(Tag.valueOf("div"), "")
        for sib in siblings {
            var include = sib === top
            if !include, let s = topScores[ObjectIdentifier(sib)], s >= threshold { include = true }
            if !include, sib.tagName() == "p" {
                let text = try sib.text()
                let density = try linkDensity(sib)
                if text.count > 80 && density < 0.25 { include = true }
                else if text.count > 0 && text.count <= 80 && density == 0 && text.contains(". ") { include = true }
            }
            if include { try wrapper.appendChild(sib.copy() as! Element) }
        }
        return wrapper
    }

    /// 추출된 본문 안의 잔여 노이즈 제거
    private static func clean(_ el: Element) throws {
        try el.select(removeSelectors).remove()
        for node in try el.select("div, section, ul, ol, table").array() {
            let text = try node.text()
            let imgs = try node.select("img").size()
            if text.count < 200, imgs == 0, try linkDensity(node) > 0.5 { try node.remove() }
        }
        for node in try el.select("*").array() where node.parent() != nil && node !== el {
            let ci = classAndID(node)
            if ci.count > 1, matches(unlikely, ci), !matches(maybe, ci), try node.select("img").isEmpty() {
                try node.remove()
            }
        }
        for node in try el.select("*").array() where node.parent() != nil && node !== el {
            let ci = classAndID(node)
            if ci.count > 1, matches(noise, ci), try node.text().count < 400 {
                try node.remove()
            }
        }
        for p in try el.select("p, span, div").array()
        where try p.text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && p.select("img, video, picture, iframe").isEmpty() {
            try p.remove()
        }
    }

    /// 링크/이미지 URL 절대경로화, 지연 로딩 이미지 처리, 스타일 속성 제거
    static func normalize(_ el: Element) throws {
        for img in try el.select("img").array() {
            var src = ""
            for attr in ["data-src", "data-lazy-src", "data-original", "data-url", "src"] {
                let v = try img.absUrl(attr)
                if !v.isEmpty, !v.hasPrefix("data:") { src = v; break }
            }
            if src.isEmpty, let best = try bestFromSrcset(img) { src = best }
            if src.isEmpty {
                if try img.attr("src").hasPrefix("data:") == false { try img.remove() }
                continue
            }
            try img.attr("src", src)
            for a in ["srcset", "sizes", "data-src", "data-lazy-src", "data-original", "loading", "width", "height", "style"] {
                try img.removeAttr(a)
            }
        }
        // <picture> 의 <source> 는 원격 srcset 을 다시 끌어오므로 제거
        try el.select("picture source").remove()
        for a in try el.select("a[href]").array() {
            let abs = try a.absUrl("href")
            if !abs.isEmpty { try a.attr("href", abs) }
        }
        for node in try el.select("[style], [class], [id], [onclick], [onload], [onerror]").array() {
            for a in ["style", "class", "id", "onclick", "onload", "onerror"] { try node.removeAttr(a) }
        }
    }

    private static func bestFromSrcset(_ img: Element) throws -> String? {
        let srcset = try img.attr("srcset").isEmpty ? img.attr("data-srcset") : img.attr("srcset")
        guard !srcset.isEmpty else { return nil }
        let candidates = srcset.split(separator: ",").compactMap { part -> (String, Double)? in
            let comps = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let url = comps.first else { return nil }
            let w = comps.count > 1 ? Double(comps[1].dropLast()) ?? 1 : 1
            return (String(url), w)
        }
        guard let pick = candidates.filter({ $0.1 <= 1600 }).max(by: { $0.1 < $1.1 }) ?? candidates.first
        else { return nil }
        return URL(string: pick.0, relativeTo: URL(string: img.getBaseUri()))?.absoluteString
    }
}

enum ContentHeuristics {
    /// 본문의 첫 이미지 (썸네일 대체용)
    static func firstImage(in html: String, baseURL: String) -> String? {
        guard let doc = try? SwiftSoup.parseBodyFragment(html, baseURL),
              let imgs = try? doc.select("img").array() else { return nil }
        for img in imgs {
            for attr in ["data-src", "src"] {
                if let v = try? img.absUrl(attr), v.hasPrefix("http") { return v }
            }
        }
        return nil
    }

    private static let truncationMarkers = [
        "…", "...", "[…]", "[...]", "read more", "continue reading", "read the full",
        "더 보기", "더보기", "계속 읽기", "전체 보기", "원문 보기", "続きを読む",
    ]

    static func plainText(_ html: String) -> String {
        (try? SwiftSoup.parse(html).text()) ?? html
    }

    /// 페이지 제목: og:title, 없으면 <title>
    static func pageTitle(html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else { return nil }
        let og = (try? doc.select("meta[property=og:title]").first()?.attr("content")) ?? nil
        let raw = (og?.isEmpty == false ? og : (try? doc.title())) ?? ""
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// 피드 본문이 요약/발췌로 보이면 true
    static func looksTruncated(_ html: String) -> Bool {
        let text = plainText(html).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < 600 { return true }
        let tail = text.suffix(60).lowercased()
        return truncationMarkers.contains { tail.contains($0) }
    }
}

enum FetchError: Error, LocalizedError {
    /// 사이트가 봇 확인(브라우저 확인, Cloudflare 등) 페이지를 돌려줌
    case blockedByBrowserCheck

    var errorDescription: String? { "사이트가 브라우저 확인을 요구합니다." }
}

/// 같은 사이트에 요청을 몰아 보내지 않도록 사이트별로 최소 간격을 둔다
actor HostThrottle {
    static let shared = HostThrottle()
    private var nextAllowed: [String: Date] = [:]
    private let interval: TimeInterval = 1.0

    func wait(for host: String) async {
        let now = Date()
        let slot = max(now, nextAllowed[host] ?? now)
        nextAllowed[host] = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }
}

enum HTMLFetcher {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func fetch(_ url: URL, timeout: TimeInterval = 20) async throws -> (String, URL) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("ko-KR,ko;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let host = url.host() { await HostThrottle.shared.wait(for: host) }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 403 || http.statusCode == 503,
               isBrowserCheck(String(decoding: data.prefix(20000), as: UTF8.self), url: response.url ?? url) {
                throw FetchError.blockedByBrowserCheck
            }
            throw URLError(.badServerResponse)
        }
        let html = decode(data, encodingName: response.textEncodingName)
        let finalURL = response.url ?? url
        if isBrowserCheck(html, url: finalURL) { throw FetchError.blockedByBrowserCheck }
        return (html, finalURL)
    }

    /// 봇 확인 페이지인지 (본문으로 저장하면 안 된다)
    static func isBrowserCheck(_ html: String, url: URL) -> Bool {
        if url.path().lowercased().contains("browser_check") { return true }
        // 확인 페이지는 작다. 큰 정상 페이지가 우연히 같은 단어를 포함해도 막힌 것으로 보지 않는다.
        guard html.count < 60_000 else { return false }
        let head = html.prefix(4000).lowercased()
        let markers = ["<title>just a moment", "<title>브라우저 확인", "cf-chl-", "checking your browser"]
        return markers.contains { head.contains($0) }
    }

    /// HTTP 헤더 → <meta charset> → UTF-8 → EUC-KR 순서로 디코딩
    static func decode(_ data: Data, encodingName: String?) -> String {
        func encoding(named name: String) -> String.Encoding? {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        if let name = encodingName, let enc = encoding(named: name), let s = String(data: data, encoding: enc) {
            return s
        }
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if let range = head.range(of: #"charset=["']?([a-z0-9_\-]+)"#, options: .regularExpression) {
            let name = head[range].replacingOccurrences(of: #"charset=["']?"#, with: "", options: .regularExpression)
            if let enc = encoding(named: name), let s = String(data: data, encoding: enc) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let enc = encoding(named: "euc-kr"), let s = String(data: data, encoding: enc) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
