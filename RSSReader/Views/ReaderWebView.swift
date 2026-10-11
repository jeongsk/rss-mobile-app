import SwiftUI
import WebKit

struct SelectionInfo: Decodable, Sendable {
    let quote: String
    let prefix: String
    let suffix: String
}

/// 웹뷰에 넘기는 하이라이트 정보
struct HighlightPayload: Equatable, Sendable {
    let id: String
    let quote: String
    let prefix: String
    let suffix: String
    let color: String
    let hasNote: Bool

    init(_ h: Highlight) {
        id = h.id.uuidString
        quote = h.quote
        prefix = h.prefix
        suffix = h.suffix
        color = h.colorRaw
        hasNote = !h.note.isEmpty
    }

    var dictionary: [String: Any] {
        ["id": id, "quote": quote, "prefix": prefix, "suffix": suffix, "color": color, "note": hasNote]
    }
}

/// 선택 메뉴에 "하이라이트/메모"를 추가한 WKWebView
final class ReaderWKWebView: WKWebView {
    var onHighlightMenu: ((_ withNote: Bool) -> Void)?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard onHighlightMenu != nil else { return }
        let highlight = UIAction(title: "하이라이트", image: UIImage(systemName: "highlighter")) { [weak self] _ in
            self?.onHighlightMenu?(false)
        }
        let note = UIAction(title: "메모", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
            self?.onHighlightMenu?(true)
        }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [highlight, note]),
                            atStartOfMenu: .standardEdit)
    }
}

/// 리더 본문 표시용 WKWebView. 페이지 스크립트는 끄고, 앱 스크립트는 별도 content world 에서 실행한다.
struct ReaderWebView: UIViewRepresentable {
    static let world = WKContentWorld.world(name: "reader")
    static let script: String = {
        guard let url = Bundle.main.url(forResource: "reader", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    let html: String
    let baseURL: URL?
    var highlights: [HighlightPayload] = []
    var scrollToHighlightID: String?
    /// 일치하는 곳을 칠할 검색어 (빈 문자열이면 칠하지 않음)
    var searchTerm = ""
    /// 지금 읽는 문장 (번호, 문장)
    var ttsSentence: (index: Int, text: String)?
    var onCreateHighlight: ((SelectionInfo, _ withNote: Bool) -> Void)?
    var onTapHighlight: ((String) -> Void)?
    var onReady: ((WKWebView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(CachedImageSchemeHandler(), forURLScheme: ImageCache.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.dataDetectorTypes = []
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
        controller.add(WeakMessageHandler(context.coordinator), contentWorld: Self.world, name: "highlight")

        let webView = ReaderWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.webView = webView
        webView.onHighlightMenu = { [weak coordinator = context.coordinator] withNote in
            coordinator?.createHighlight(withNote: withNote)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.lastHTML != html {
            let isReload = coordinator.lastHTML != nil
            coordinator.lastHTML = html
            coordinator.loaded = false
            // 스타일 변경으로 다시 그릴 때 읽던 위치를 유지한다
            if isReload {
                let sv = webView.scrollView
                let max = sv.contentSize.height - sv.bounds.height
                coordinator.restoreRatio = max > 0 ? sv.contentOffset.y / max : 0
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        } else if coordinator.loaded {
            if coordinator.appliedHighlights != highlights { coordinator.syncHighlights() }
            coordinator.syncSearch()
            coordinator.markSpeech()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReaderWebView?
        weak var webView: WKWebView?
        var lastHTML: String?
        var restoreRatio: CGFloat?
        var loaded = false
        var appliedHighlights: [HighlightPayload] = []
        private var appliedSearch: String?
        private var scrolledToHighlight: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            appliedSearch = nil
            syncHighlights()
            syncSearch()
            lastSpeechIndex = nil
            markSpeech()
            parent?.onReady?(webView)
            guard let ratio = restoreRatio else { return }
            restoreRatio = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let sv = webView.scrollView
                let max = sv.contentSize.height - sv.bounds.height
                if max > 0 { sv.setContentOffset(CGPoint(x: 0, y: max * ratio), animated: false) }
            }
        }

        func syncHighlights() {
            guard let webView, let parent else { return }
            let list = parent.highlights
            appliedHighlights = list
            let target = parent.scrollToHighlightID
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "return window.__reader.syncHighlights(list)",
                    arguments: ["list": list.map(\.dictionary)], in: nil, contentWorld: ReaderWebView.world)
                if let target, target != scrolledToHighlight {
                    scrolledToHighlight = target
                    _ = try? await webView.callAsyncJavaScript(
                        "window.__reader.scrollToHighlight(id)", arguments: ["id": target],
                        in: nil, contentWorld: ReaderWebView.world)
                }
            }
        }

        func syncSearch() {
            guard let webView, let parent else { return }
            let term = parent.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term != (appliedSearch ?? "") || (appliedSearch == nil && !term.isEmpty) else { return }
            // 하이라이트로 열었을 때는 그 위치를 우선한다
            let scroll = appliedSearch == nil && parent.scrollToHighlightID == nil
            appliedSearch = term
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    term.isEmpty ? "window.__reader.findClear()" : "return window.__reader.find(term, scroll)",
                    arguments: term.isEmpty ? [:] : ["term": term, "scroll": scroll],
                    in: nil, contentWorld: ReaderWebView.world)
            }
        }

        private var lastSpeechIndex: Int?

        func markSpeech() {
            guard let webView else { return }
            guard let sentence = parent?.ttsSentence else {
                if lastSpeechIndex != nil {
                    lastSpeechIndex = nil
                    webView.evaluateJavaScript("window.__reader.ttsReset()", in: nil, in: ReaderWebView.world) { _ in }
                }
                return
            }
            guard sentence.index != lastSpeechIndex else { return }
            // 뒤로 건너뛰었거나 처음이면 검색 위치를 처음으로 되돌린다
            let reset = lastSpeechIndex.map { sentence.index < $0 } ?? true
            lastSpeechIndex = sentence.index
            Task { @MainActor in
                if reset {
                    _ = try? await webView.callAsyncJavaScript("window.__reader.ttsReset()", arguments: [:],
                                                               in: nil, contentWorld: ReaderWebView.world)
                }
                _ = try? await webView.callAsyncJavaScript("return window.__reader.ttsMark(s)", arguments: ["s": sentence.text],
                                                           in: nil, contentWorld: ReaderWebView.world)
            }
        }

        func createHighlight(withNote: Bool) {
            guard let webView else { return }
            Task { @MainActor in
                guard let result = try? await webView.callAsyncJavaScript(
                    "return window.__reader.selection()", arguments: [:], in: nil, contentWorld: ReaderWebView.world),
                    let dict = result as? [String: Any],
                    let data = try? JSONSerialization.data(withJSONObject: dict),
                    let info = try? JSONDecoder().decode(SelectionInfo.self, from: data)
                else { return }
                _ = try? await webView.callAsyncJavaScript(
                    "window.__reader.clearSelection()", arguments: [:], in: nil, contentWorld: ReaderWebView.world)
                parent?.onCreateHighlight?(info, withNote)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "highlight", let id = message.body as? String {
                parent?.onTapHighlight?(id)
            }
        }
    }
}

/// WKUserContentController 가 핸들러를 강하게 잡아 생기는 순환 참조 방지
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
