import Testing
import Foundation
@testable import RSSReader

struct FeedParserTests {
    @Test func parsesRSS2WithContentEncoded() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>Example &amp; Co</title>
            <link>https://example.com/</link>
            <item>
              <title>Hello &#8220;World&#8221;</title>
              <link>https://example.com/hello</link>
              <guid isPermaLink="false">abc-1</guid>
              <description>short summary</description>
              <content:encoded><![CDATA[<p>Full <b>body</b></p>]]></content:encoded>
              <dc:creator>Jane</dc:creator>
              <pubDate>Tue, 03 Jun 2025 09:39:21 +0000</pubDate>
            </item>
            <item>
              <title>Second</title>
              <link>https://example.com/second</link>
              <description><![CDATA[<p>Only summary</p>]]></description>
              <pubDate>Wed, 4 Jun 2025 10:00:00 GMT</pubDate>
            </item>
          </channel>
        </rss>
        """
        let feed = try FeedParser.parse(Data(xml.utf8))
        #expect(feed.title == "Example & Co")
        #expect(feed.siteURL == "https://example.com/")
        #expect(feed.items.count == 2)
        let first = feed.items[0]
        #expect(first.title == "Hello “World”")
        #expect(first.guid == "abc-1")
        #expect(first.html == "<p>Full <b>body</b></p>")
        #expect(first.author == "Jane")
        #expect(first.published == Date(timeIntervalSince1970: 1748943561))
        #expect(feed.items[1].html == "<p>Only summary</p>")
        #expect(feed.items[1].guid == "https://example.com/second")
        #expect(feed.items[1].published != nil)
    }

    @Test func parsesAtom() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Blog</title>
          <link href="https://atom.example/feed.xml" rel="self"/>
          <link href="https://atom.example/"/>
          <entry>
            <title type="html">Post &lt;1&gt;</title>
            <link rel="alternate" href="https://atom.example/p1"/>
            <id>tag:atom.example,2025:1</id>
            <published>2025-06-03T09:39:21.123Z</published>
            <updated>2025-06-05T00:00:00Z</updated>
            <author><name>Kim</name></author>
            <summary>sum</summary>
            <content type="html">&lt;p&gt;content&lt;/p&gt;</content>
          </entry>
        </feed>
        """
        let feed = try FeedParser.parse(Data(xml.utf8))
        #expect(feed.title == "Atom Blog")
        #expect(feed.siteURL == "https://atom.example/")
        let e = try #require(feed.items.first)
        #expect(e.link == "https://atom.example/p1")
        #expect(e.guid == "tag:atom.example,2025:1")
        #expect(e.html == "<p>content</p>")
        #expect(e.author == "Kim")
        let expected = Date(timeIntervalSince1970: 1748943561.123)
        #expect(abs(e.published!.timeIntervalSince(expected)) < 0.01)
    }

    @Test func parsesRDF() throws {
        let xml = """
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel><title>RDF</title><link>https://rdf.example</link></channel>
          <item><title>A</title><link>https://rdf.example/a</link><dc:date>2025-06-03T09:39:21+09:00</dc:date></item>
        </rdf:RDF>
        """
        let feed = try FeedParser.parse(Data(xml.utf8))
        #expect(feed.title == "RDF")
        #expect(feed.items.first?.published == Date(timeIntervalSince1970: 1748943561 - 9 * 3600))
    }

    @Test func rejectsHTML() {
        #expect(throws: (any Error).self) {
            try FeedParser.parse(Data("<html><body>hi</body></html>".utf8))
        }
    }

    @Test(arguments: [
        "Tue, 03 Jun 2025 09:39:21 GMT",
        "Tue, 03 Jun 2025 09:39:21 UT",
        "Tue, 03 Jun 2025 09:39:21 Z",
        "Tue, 3 Jun 2025 09:39:21 +0000",
        "2025-06-03T09:39:21Z",
        "2025-06-03T09:39:21.000+00:00",
    ])
    func parsesDates(_ raw: String) {
        #expect(DateParser.parse(raw) == Date(timeIntervalSince1970: 1748943561))
    }
}

struct OPMLParserTests {
    @Test func parsesFeedlyExport() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <head><title>Anpigon subscriptions in feedly Cloud</title></head>
          <body>
            <outline text="Tech" title="Tech">
              <outline type="rss" text="Hacker News" title="Hacker News" xmlUrl="https://news.ycombinator.com/rss" htmlUrl="https://news.ycombinator.com/"/>
              <outline type="rss" text="Swift" title="Swift" xmlUrl="https://swift.org/atom.xml" htmlUrl="https://swift.org"/>
            </outline>
            <outline text="뉴스" title="뉴스">
              <outline text="Sub" title="Sub">
                <outline type="rss" text="Nested" xmlUrl="https://nested.example/rss"/>
              </outline>
            </outline>
            <outline type="rss" text="Loose &amp; Free" xmlUrl="https://loose.example/feed"/>
          </body>
        </opml>
        """
        let doc = try OPMLParser.parse(Data(xml.utf8))
        #expect(doc.feedCount == 4)
        #expect(doc.folders.map(\.name) == ["Tech", "Sub"])
        #expect(doc.folders[0].feeds.map(\.title) == ["Hacker News", "Swift"])
        #expect(doc.folders[0].feeds[0].htmlURL == "https://news.ycombinator.com/")
        #expect(doc.ungrouped == [OPMLFeed(title: "Loose & Free", xmlURL: "https://loose.example/feed", htmlURL: nil)])
    }

    @Test func roundTripsExport() throws {
        let out = OPMLExporter.export(
            folders: [("A&B", [OPMLFeed(title: "F \"1\"", xmlURL: "https://x/rss?a=1&b=2", htmlURL: nil)])],
            ungrouped: [OPMLFeed(title: "G", xmlURL: "https://g/rss", htmlURL: "https://g")])
        let doc = try OPMLParser.parse(Data(out.utf8))
        #expect(doc.folders == [OPMLFolder(name: "A&B", feeds: [OPMLFeed(title: "F \"1\"", xmlURL: "https://x/rss?a=1&b=2", htmlURL: nil)])])
        #expect(doc.ungrouped.first?.htmlURL == "https://g")
    }
}
