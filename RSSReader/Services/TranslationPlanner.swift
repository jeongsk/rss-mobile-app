import Foundation
import SwiftSoup

enum TranslationDisplay: String, CaseIterable, Identifiable, Sendable {
    case original, both, translated
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "원문만"
        case .both: "원문+번역"
        case .translated: "번역만"
        }
    }
}

/// 본문 HTML 을 문단 단위로 나눠 번역하고 다시 합친다.
enum TranslationPlanner {
    struct Block: Sendable, Equatable {
        let index: Int
        let text: String
    }

    private static let blockSelector = "p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption, td, th, dt, dd"

    private static func leafBlocks(_ root: Element) throws -> [Element] {
        try root.select(blockSelector).array().filter { el in
            // 다른 번역 블록을 포함하지 않는 가장 안쪽 블록만 선택 (select 는 자기 자신을 포함)
            (try? el.select(blockSelector).size()) == 1
        }
    }

    static func blocks(in html: String) -> [Block] {
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body(),
              let elements = try? leafBlocks(body) else { return [] }
        return elements.enumerated().compactMap { i, el in
            guard let text = try? el.text().trimmingCharacters(in: .whitespacesAndNewlines),
                  text.contains(where: \.isLetter) else { return nil }
            return Block(index: i, text: text)
        }
    }

    /// - both: 각 문단 안에 번역문을 덧붙인다 (`<span class="tr">`, CSS 로 블록 표시)
    /// - translated: 문단 텍스트를 번역문으로 바꾸고 이미지/영상은 유지한다 (문단 안 링크 서식은 사라짐)
    static func apply(_ translations: [Int: String], to html: String, display: TranslationDisplay) -> String {
        guard display != .original, !translations.isEmpty,
              let doc = try? SwiftSoup.parseBodyFragment(html), let body = doc.body(),
              let elements = try? leafBlocks(body) else { return html }
        for (i, el) in elements.enumerated() {
            guard let translated = translations[i] else { continue }
            switch display {
            case .both:
                if let span = try? el.appendElement("span") {
                    _ = try? span.addClass("tr").attr("lang", "ko").text(translated)
                }
            case .translated:
                let media = (try? el.select("img, picture, video, iframe").array()) ?? []
                _ = try? el.text(translated)
                for m in media { _ = try? el.appendChild(m) }
            case .original:
                break
            }
        }
        return (try? body.html()) ?? html
    }
}
