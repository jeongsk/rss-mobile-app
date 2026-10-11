import SwiftUI
import WebKit

/// 원본 웹 화면의 현재 상태와 페이지 HTML 가져오기
@MainActor
@Observable
final class WebPageController {
    fileprivate weak var webView: WKWebView?
    private(set) var currentURL: URL?
    var progress = 0.0

    fileprivate func update(from webView: WKWebView) {
        currentURL = webView.url
    }

    /// 사용자가 보고 있는 페이지의 HTML (브라우저 확인을 통과한 뒤의 실제 DOM)
    func captureHTML() async -> (html: String, url: URL)? {
        guard let webView, let url = webView.url,
              let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
        else { return nil }
        return (html, url)
    }
}

/// 원본 웹페이지 보기 (스크립트 허용, 쿠키는 기기에 남아 사이트 확인을 한 번만 하면 된다)
struct OriginalWebView: UIViewRepresentable {
    let url: URL
    let controller: WebPageController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = HTMLFetcher.userAgent
        webView.navigationDelegate = context.coordinator
        controller.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// 진행률은 탐색 단계로 근사한다 (KVO 대신 delegate 사용)
    final class Coordinator: NSObject, WKNavigationDelegate {
        let controller: WebPageController

        init(controller: WebPageController) { self.controller = controller }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { controller.progress = 0.15 }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            controller.progress = 0.6
            controller.update(from: webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.progress = 1
            controller.update(from: webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { controller.progress = 1 }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { controller.progress = 1 }
    }
}
