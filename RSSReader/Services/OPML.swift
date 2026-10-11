import Foundation

struct OPMLFeed: Sendable, Equatable {
    var title: String
    var xmlURL: String
    var htmlURL: String?
}

struct OPMLFolder: Sendable, Equatable {
    var name: String
    var feeds: [OPMLFeed]
}

struct OPMLDocument: Sendable, Equatable {
    var folders: [OPMLFolder] = []
    var ungrouped: [OPMLFeed] = []

    var feedCount: Int { ungrouped.count + folders.reduce(0) { $0 + $1.feeds.count } }
}

/// OPML 파서. Feedly 내보내기(폴더 outline 안에 피드 outline) 형식을 지원한다.
/// 중첩 폴더는 가장 가까운 상위 폴더 이름으로 평탄화한다.
final class OPMLParser: NSObject, XMLParserDelegate {
    private var doc = OPMLDocument()
    private var folderStack: [String] = []
    /// outline 요소마다 폴더로 push 했는지 기록 (닫힐 때 pop 하기 위해)
    private var pushedStack: [Bool] = []
    private var folderIndex: [String: Int] = [:]

    static func parse(_ data: Data) throws -> OPMLDocument {
        let delegate = OPMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw FeedParserError.invalidXML(parser.parserError?.localizedDescription ?? "unknown")
        }
        return delegate.doc
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard name.lowercased() == "outline" else { return }
        let title = (attributes["title"] ?? attributes["text"] ?? "").decodingHTMLEntities()

        if let xmlURL = attributes["xmlUrl"] ?? attributes["xmlurl"], !xmlURL.isEmpty {
            let feed = OPMLFeed(title: title.isEmpty ? xmlURL : title,
                                xmlURL: xmlURL,
                                htmlURL: attributes["htmlUrl"] ?? attributes["htmlurl"])
            if let folder = folderStack.last {
                let idx: Int
                if let existing = folderIndex[folder] {
                    idx = existing
                } else {
                    doc.folders.append(OPMLFolder(name: folder, feeds: []))
                    idx = doc.folders.count - 1
                    folderIndex[folder] = idx
                }
                doc.folders[idx].feeds.append(feed)
            } else {
                doc.ungrouped.append(feed)
            }
            pushedStack.append(false)
        } else {
            folderStack.append(title.isEmpty ? "폴더" : title)
            pushedStack.append(true)
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard name.lowercased() == "outline", let pushed = pushedStack.popLast() else { return }
        if pushed { folderStack.removeLast() }
    }
}

enum OPMLExporter {
    static func export(folders: [(name: String, feeds: [OPMLFeed])], ungrouped: [OPMLFeed]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func line(_ f: OPMLFeed, indent: String) -> String {
            var s = "\(indent)<outline type=\"rss\" text=\"\(esc(f.title))\" title=\"\(esc(f.title))\" xmlUrl=\"\(esc(f.xmlURL))\""
            if let html = f.htmlURL { s += " htmlUrl=\"\(esc(html))\"" }
            return s + "/>"
        }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <head><title>내 RSS 구독</title></head>
          <body>

        """
        for folder in folders {
            out += "    <outline text=\"\(esc(folder.name))\" title=\"\(esc(folder.name))\">\n"
            for f in folder.feeds { out += line(f, indent: "      ") + "\n" }
            out += "    </outline>\n"
        }
        for f in ungrouped { out += line(f, indent: "    ") + "\n" }
        out += "  </body>\n</opml>\n"
        return out
    }
}
