import Foundation
import SwiftSoup

/// 리더 화면용 HTML 문서를 만든다.
@MainActor
enum ReaderHTMLBuilder {
    static func build(title: String, feedTitle: String, author: String?, date: Date,
                      bodyHTML: String, baseURL: URL?, settings: ReaderSettings, fonts: FontStore,
                      subtitle: String? = nil, notice: String? = nil, bodyIsPrepared: Bool = false,
                      originalURL: String? = nil, comments: [ExtractedComment] = []) -> String {
        let body = bodyIsPrepared ? bodyHTML : prepareBody(bodyHTML, baseURL: baseURL, title: title)
        let p = settings.theme.palette

        var fontFace = ""
        let family: String
        switch settings.fontChoice {
        case "serif": family = "ui-serif, 'New York', Georgia, serif"
        case "rounded": family = "ui-rounded, -apple-system, sans-serif"
        case "mono": family = "ui-monospace, Menlo, monospace"
        case let choice where choice.hasPrefix("custom:"):
            let ps = String(choice.dropFirst("custom:".count))
            if let font = fonts.font(named: ps) {
                fontFace = fonts.fontFaceCSS(for: font)
                family = "'ReaderCustom', '\(ps)', -apple-system, sans-serif"
            } else {
                family = "-apple-system, 'Apple SD Gothic Neo', sans-serif"
            }
        default: family = "-apple-system, 'Apple SD Gothic Neo', sans-serif"
        }

        let systemDark = settings.theme == .system ? """
        @media (prefers-color-scheme: dark) {
          :root { --bg: #1c1c1e; --fg: #e5e5ea; --secondary: #98989f; --link: #5aa9ff; }
        }
        """ : ""

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let meta = [feedTitle, author, formatter.string(from: date)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .map(escape).joined(separator: " · ")
        let subtitleHTML = subtitle.map { "<div class=\"subtitle tr\">\(escape($0))</div>" } ?? ""
        let originalHTML = originalURL.flatMap(URL.init(string:)).map { url in
            "<a class=\"original\" href=\"\(escape(url.absoluteString))\">원문 기사 열기 · \(escape(url.host() ?? url.absoluteString)) ↗</a>"
        } ?? ""
        let commentsHTML = Self.commentsSection(comments)
        let noticeHTML = notice.map { "<div class=\"notice\">\(escape($0))</div>" } ?? ""

        return """
        <!doctype html>
        <html lang="ko"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        \(fontFace)
        :root { --bg: \(p.bg); --fg: \(p.fg); --secondary: \(p.secondary); --link: \(p.link);
                color-scheme: \(settings.theme == .system ? "light dark" : (settings.theme.colorScheme == .dark ? "dark" : "light")); }
        \(systemDark)
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; background: var(--bg); color: var(--fg);
               font-family: \(family); font-size: \(Int(settings.fontSize))px; line-height: \(settings.lineHeight);
               word-break: keep-all; overflow-wrap: anywhere; \(settings.justify ? "text-align: justify;" : "") }
        main { max-width: 720px; margin: 0 auto;
               padding: 16px max(\(Int(settings.margin))px, env(safe-area-inset-right)) 64px max(\(Int(settings.margin))px, env(safe-area-inset-left)); }
        h1.title { font-size: 1.45em; line-height: 1.3; margin: 0.4em 0 0.3em; text-align: left; }
        .meta { color: var(--secondary); font-size: 0.78em; margin-bottom: 1.6em; }
        .notice { color: var(--secondary); font-size: 0.78em; border: 1px solid color-mix(in srgb, var(--secondary) 40%, transparent);
                  border-radius: 8px; padding: 8px 12px; margin-bottom: 1.2em; }
        p, ul, ol, blockquote, pre, figure, table { margin: 0 0 \(settings.paragraphSpacing)em; }
        a { color: var(--link); text-decoration: none; }
        img, video, picture, iframe { max-width: 100%; height: auto; border-radius: 6px; display: block; margin: 0.6em auto; }
        figure { margin-left: 0; margin-right: 0; }
        figcaption { color: var(--secondary); font-size: 0.8em; text-align: center; }
        blockquote { border-left: 3px solid var(--secondary); margin-left: 0; padding-left: 1em; color: var(--secondary); }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.85em; }
        pre { overflow-x: auto; padding: 12px; border-radius: 8px; background: color-mix(in srgb, var(--fg) 7%, transparent); }
        table { display: block; overflow-x: auto; border-collapse: collapse; }
        td, th { border: 1px solid color-mix(in srgb, var(--secondary) 35%, transparent); padding: 4px 8px; }
        .tr { display: block; margin-top: 0.4em; padding-left: 0.7em; font-size: 0.94em;
              border-left: 3px solid color-mix(in srgb, var(--link) 55%, transparent);
              color: color-mix(in srgb, var(--fg) 82%, var(--link)); font-weight: normal; }
        .subtitle { font-size: 1.05em; margin: 0 0 0.6em; }
        /* iOS 는 링크·버튼이 아닌 요소의 탭에 click 을 보내지 않을 수 있어 pointer 로 표시한다 */
        mark.hl { color: inherit; border-radius: 3px; padding: 0 1px; -webkit-box-decoration-break: clone; cursor: pointer; }
        mark.hl-yellow { background: rgba(255, 214, 10, 0.42); }
        mark.hl-green { background: rgba(48, 209, 88, 0.35); }
        mark.hl-blue { background: rgba(100, 210, 255, 0.40); }
        mark.hl-pink { background: rgba(255, 100, 130, 0.35); }
        mark.hl-purple { background: rgba(191, 90, 242, 0.32); }
        ::highlight(search) { background-color: rgba(255, 149, 0, 0.45); color: inherit; }
        ::highlight(tts) { background-color: color-mix(in srgb, var(--link) 22%, transparent); }
        mark.has-note { border-bottom: 2px dotted var(--link); }
        a.original { display: inline-block; margin: -0.8em 0 1.4em; font-size: 0.82em; font-weight: 600;
                     padding: 6px 12px; border-radius: 999px; background: color-mix(in srgb, var(--link) 12%, transparent); }
        section.comments { margin-top: 2.4em; border-top: 1px solid color-mix(in srgb, var(--secondary) 35%, transparent); padding-top: 1em; }
        section.comments summary { font-weight: 700; cursor: pointer; margin-bottom: 0.8em; }
        .comment { font-size: 0.9em; margin: 0 0 1em; padding-left: 10px;
                   border-left: 2px solid color-mix(in srgb, var(--secondary) 30%, transparent); }
        .comment .who { color: var(--secondary); font-size: 0.85em; margin-bottom: 0.2em; }
        .comment h6 { font-size: 0.95em; margin: 0 0 0.4em; }
        .comment ul { padding-left: 1.2em; }
        hr { border: 0; border-top: 1px solid color-mix(in srgb, var(--secondary) 35%, transparent); }
        </style></head>
        <body><main>
        <h1 class="title">\(escape(title))</h1>
        \(subtitleHTML)
        <div class="meta">\(meta)</div>
        \(originalHTML)
        \(noticeHTML)
        <article>\(body)</article>
        \(commentsHTML)
        </main></body></html>
        """
    }

    /// 상대 URL 정리 + 캐시된 이미지를 로컬 스킴으로 교체.
    /// 번역/하이라이트/TTS 는 모두 이 결과를 기준으로 문단 번호를 매긴다.
    static func prepareBody(_ html: String, baseURL: URL?, title: String = "") -> String {
        guard let doc = try? SwiftSoup.parseBodyFragment(html, baseURL?.absoluteString ?? ""),
              let body = doc.body() else { return html }
        do {
            try body.select("script, style, link, meta, form").remove()
            // 머리글에 이미 있는 제목과 같은 h1/h2 는 숨긴다
            let normalizedTitle = Self.normalizeText(title)
            for heading in try body.select("h1, h2").array().prefix(2)
            where Self.normalizeText(try heading.text()) == normalizedTitle {
                try heading.remove()
            }
            // 바로 이어서 반복되는 같은 문단 제거 (요약문이 본문에 중복되는 경우)
            var previous = ""
            for p in try body.select("p").array() {
                let text = Self.normalizeText(try p.text())
                if !text.isEmpty, text == previous, try p.select("img").isEmpty() { try p.remove() }
                previous = text
            }
            try ContentExtractor.normalize(body)
            var seenImages = Set<String>()
            for img in try body.select("img[src]").array() {
                let src = try img.attr("src")
                // 같은 이미지가 반복되면 (대표 이미지 + 갤러리 등) 한 번만 표시
                if !seenImages.insert(src).inserted { try img.remove(); continue }
                if ImageCache.isCached(src) {
                    try img.attr("src", ImageCache.localURL(for: src))
                }
            }
            return try body.html()
        } catch {
            return html
        }
    }

    /// 댓글 영역 (본문 <article> 밖에 두어 번역·하이라이트·TTS 대상에서 빠진다)
    static func commentsSection(_ comments: [ExtractedComment]) -> String {
        guard !comments.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 HH:mm"
        let items = comments.map { c in
            let who = [c.author, c.date.map(formatter.string(from:))].compactMap { $0?.isEmpty == false ? $0 : nil }
                .map(escape).joined(separator: " · ")
            return "<div class=\"comment\" style=\"margin-left: \(min(c.depth, 6) * 14)px\"><div class=\"who\">\(who)</div>\(c.html)</div>"
        }.joined(separator: "\n")
        return "<section class=\"comments\"><details open><summary>댓글 \(comments.count)개</summary>\(items)</details></section>"
    }

    static func normalizeText(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
