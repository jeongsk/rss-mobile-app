import Foundation
import SwiftSoup

/// 사이트 주소만 입력해도 RSS/Atom 주소를 찾아준다.
enum FeedDiscovery {
    struct Result: Sendable {
        let feedURL: String
        let feed: ParsedFeed
    }

    static func discover(_ input: String) async throws -> Result {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw) else { throw URLError(.badURL) }

        if let feed = try? await FeedFetcher.fetch(url.absoluteString) {
            return Result(feedURL: url.absoluteString, feed: feed)
        }

        var candidates: [String] = []
        if let (html, finalURL) = try? await HTMLFetcher.fetch(url),
           let doc = try? SwiftSoup.parse(html, finalURL.absoluteString) {
            let links = (try? doc.select("link[rel=alternate][href]").array()) ?? []
            for link in links {
                let type = ((try? link.attr("type")) ?? "").lowercased()
                if type.contains("rss") || type.contains("atom") || type.contains("xml"),
                   let href = try? link.absUrl("href"), !href.isEmpty {
                    candidates.append(href)
                }
            }
        }
        let root = "\(url.scheme ?? "https")://\(url.host() ?? "")"
        candidates += ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml", "/rss/"].map { root + $0 }

        for candidate in candidates {
            if let feed = try? await FeedFetcher.fetch(candidate) {
                return Result(feedURL: candidate, feed: feed)
            }
        }
        throw FeedParserError.notAFeed
    }
}
