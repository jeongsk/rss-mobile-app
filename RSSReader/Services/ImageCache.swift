import Foundation
import CryptoKit
import SwiftSoup
import WebKit

/// 오프라인 읽기를 위한 본문 이미지 캐시.
/// 리더 화면에서는 캐시된 이미지의 src 를 `rssimg://` 로 바꿔 로컬 파일을 보여준다.
enum ImageCache {
    static let scheme = "rssimg"
    private static let maxBytes = 8 * 1024 * 1024

    static var directory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "ImageCache", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    static func key(for remote: String) -> String {
        SHA256.hash(data: Data(remote.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fileURL(forKey key: String) -> URL {
        directory.appending(path: key)
    }

    static func isCached(_ remote: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forKey: key(for: remote)).path)
    }

    static func localURL(for remote: String) -> String {
        "\(scheme)://img/\(key(for: remote))"
    }

    static func imageURLs(in html: String) -> [String] {
        guard let doc = try? SwiftSoup.parseBodyFragment(html) else { return [] }
        let srcs = (try? doc.select("img[src]").array().map { try $0.attr("src") }) ?? []
        var seen = Set<String>()
        return srcs.filter { $0.hasPrefix("http") && seen.insert($0).inserted }
    }

    /// 아직 캐시되지 않은 이미지를 내려받는다. 반환값: 새로 저장한 개수
    @discardableResult
    static func download(_ urls: [String], limit: Int = 40) async -> Int {
        let targets = Array(urls.filter { !isCached($0) }.prefix(limit))
        guard !targets.isEmpty else { return 0 }
        return await withTaskGroup(of: Bool.self) { group in
            var iterator = targets.makeIterator()
            var saved = 0
            for _ in 0..<min(4, targets.count) {
                if let next = iterator.next() { group.addTask { await downloadOne(next) } }
            }
            while let ok = await group.next() {
                if ok { saved += 1 }
                if Task.isCancelled { group.cancelAll(); break }
                if let next = iterator.next() { group.addTask { await downloadOne(next) } }
            }
            return saved
        }
    }

    private static func downloadOne(_ remote: String) async -> Bool {
        guard let url = URL(string: remote) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(HTMLFetcher.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= maxBytes
        else { return false }
        do {
            try data.write(to: fileURL(forKey: key(for: remote)), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func totalSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func mimeType(for data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] { return "image/avif" }
        if let head = String(data: data.prefix(256), encoding: .utf8), head.contains("<svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }
}

/// `rssimg://img/<key>` 요청을 로컬 캐시 파일로 응답한다.
final class CachedImageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              let data = try? Data(contentsOf: ImageCache.fileURL(forKey: url.lastPathComponent))
        else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(url: url, mimeType: ImageCache.mimeType(for: data),
                                   expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
