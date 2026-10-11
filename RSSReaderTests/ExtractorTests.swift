import Testing
import Foundation
@testable import RSSReader

struct ExtractorTests {
    let para = String(repeating: "This is a sentence of the real article body, with some commas, and words. ", count: 4)

    @Test func extractsMainContentAndDropsChrome() throws {
        let html = """
        <html><head><title>t</title><script>var x=1</script></head><body>
          <header class="site-header"><a href="/">Home</a><a href="/about">About</a></header>
          <nav><ul><li><a href="/a">A</a></li><li><a href="/b">B</a></li></ul></nav>
          <div class="layout">
            <div class="sidebar"><p>\(para)</p></div>
            <div class="story">
              <h1>Title</h1>
              <p>\(para)</p>
              <p>\(para)</p>
              <figure><img data-src="/img/photo.jpg" src="data:image/gif;base64,R0lGOD"></figure>
              <p>Link to <a href="/other">other page</a>. \(para)</p>
              <div class="share-buttons"><a href="#">Tweet</a><a href="#">Share</a></div>
            </div>
            <div class="comments"><p>\(para)</p></div>
          </div>
          <footer><p>Copyright</p></footer>
        </body></html>
        """
        let result = try #require(try ContentExtractor.extract(html: html, baseURL: URL(string: "https://ex.com/posts/1")!))
        #expect(result.html.contains("https://ex.com/img/photo.jpg"))
        #expect(result.html.contains("href=\"https://ex.com/other\""))
        #expect(!result.html.contains("Tweet"))
        #expect(!result.html.contains("Home"))
        #expect(!result.html.contains("Copyright"))
        #expect(!result.html.contains("<script"))
        #expect(result.textLength > 900 && result.textLength < 1400)
    }

    @Test func prefersKnownContainer() throws {
        let html = """
        <body><div class="x"><p>\(para)</p></div>
        <div class="entry-content"><p>\(para)</p><p>\(para)</p><img srcset="/s.jpg 300w, /m.jpg 800w, /l.jpg 2400w"></div></body>
        """
        let result = try #require(try ContentExtractor.extract(html: html, baseURL: URL(string: "https://ex.com/")!))
        #expect(result.html.contains("https://ex.com/m.jpg"))
        #expect(!result.html.contains("srcset"))
        #expect(result.textLength < 700)
    }

    @Test func truncationHeuristic() {
        #expect(ContentHeuristics.looksTruncated("<p>Short teaser…</p>"))
        let long = "<p>" + String(repeating: "word ", count: 300) + "</p>"
        #expect(!ContentHeuristics.looksTruncated(long))
        #expect(ContentHeuristics.looksTruncated("<p>" + String(repeating: "word ", count: 300) + " Continue reading</p>"))
    }

    @Test func decodesEUCKR() {
        let cf = CFStringConvertIANACharSetNameToEncoding("euc-kr" as CFString)
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        let data = "<html><head><meta charset=\"euc-kr\"></head><body>안녕하세요</body></html>".data(using: enc)!
        #expect(HTMLFetcher.decode(data, encodingName: nil).contains("안녕하세요"))
    }
}
