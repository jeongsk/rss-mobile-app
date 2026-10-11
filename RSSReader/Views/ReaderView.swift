import SwiftUI
import SwiftData
import Translation

enum ReaderMode: String, CaseIterable, Identifiable {
    case reader, web
    var id: String { rawValue }
    var label: String { self == .reader ? "리더" : "웹" }
}

struct ReaderView: View {
    @Bindable var article: Article
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var settings = ReaderSettings.shared
    @State private var fonts = FontStore.shared
    @State private var network = NetworkMonitor.shared
    @State private var mode: ReaderMode = .reader
    @State private var loading = false
    @State private var showStyle = false
    @State private var webPage = WebPageController()
    @State private var capturing = false
    @State private var toast: String?
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translating = false
    @AppStorage("translationDisplay") private var displayRaw = TranslationDisplay.both.rawValue
    @AppStorage("autoTranslate") private var autoTranslate = false
    @AppStorage(AppSettingsKeys.autoRemoveSaved) private var autoRemoveSaved = true
    @AppStorage("highlightColor") private var highlightColorRaw = HighlightColor.yellow.rawValue
    @Query private var highlights: [Highlight]
    @State private var editing: EditingHighlight?
    @State private var player = SpeechPlayer.shared
    @State private var htmlCache = HTMLCache()

    /// 같은 입력이면 HTML 을 다시 만들지 않는다 (TTS 문장이 바뀔 때마다 본문을 다시 파싱하지 않도록)
    @MainActor
    final class HTMLCache {
        private var key = ""
        private var value = ""
        func get(_ key: String, build: () -> String) -> String {
            if key != self.key {
                value = build()
                self.key = key
            }
            return value
        }
    }

    struct EditingHighlight: Identifiable {
        let highlight: Highlight
        let focusNote: Bool
        var id: UUID { highlight.id }
    }

    init(article: Article) {
        self.article = article
        let key = article.key
        _highlights = Query(filter: #Predicate<Highlight> { $0.articleKey == key }, sort: \.createdAt)
    }

    private var display: TranslationDisplay {
        TranslationDisplay(rawValue: displayRaw) ?? .both
    }

    private var isForeign: Bool {
        guard let code = article.languageCode ?? LanguageDetector.detect(article.title + " " + article.snippet)
        else { return false }
        return !LanguageDetector.isKorean(code)
    }

    private var hasTranslation: Bool { !article.translations.isEmpty }

    /// 정리된 본문 (번역 문단 번호의 기준)
    private var preparedBody: String {
        ReaderHTMLBuilder.prepareBody(article.bestHTML, baseURL: URL(string: article.link), title: article.title)
    }

    private var html: String {
        let cacheKey = [
            article.key, String(article.bestHTML.count), String(article.contentStatusRaw),
            String(article.imagesCached), String(article.commentsJSON?.count ?? 0), article.originalURL ?? "-",
            article.translationsJSON.map { String($0.count) } ?? "-",
            article.translatedTitle ?? "-", displayRaw, settings.themeRaw, settings.fontChoice,
            "\(settings.fontSize)", "\(settings.lineHeight)", "\(settings.margin)",
            "\(settings.paragraphSpacing)", "\(settings.justify)", String(fonts.fonts.count),
        ].joined(separator: "|")
        return htmlCache.get(cacheKey) { buildHTML() }
    }

    private func buildHTML() -> String {
        let showTranslation = hasTranslation && display != .original
        let prepared = preparedBody
        let body = showTranslation
            ? TranslationPlanner.apply(article.translations, to: prepared, display: display)
            : prepared
        var title = article.title
        var subtitle: String?
        if showTranslation, let translated = article.translatedTitle {
            if display == .translated { title = translated } else { subtitle = translated }
        }
        var notice: String?
        if article.contentStatus == .failed {
            notice = "원문에서 전체 본문을 가져오지 못해 피드 내용만 표시합니다. 위쪽 나침반 버튼으로 원본 웹을 연 뒤 '이 페이지를 리더로 저장'을 누르면 본문을 저장할 수 있습니다."
        }
        return ReaderHTMLBuilder.build(
            title: title, feedTitle: article.feedTitle, author: article.author,
            date: article.publishedAt, bodyHTML: body, baseURL: URL(string: article.link),
            settings: settings, fonts: fonts, subtitle: subtitle, notice: notice, bodyIsPrepared: true,
            originalURL: article.originalURL, comments: article.comments)
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: toast)
            .sheet(isPresented: $showStyle) {
                ReaderStylePanel(settings: settings)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $editing) { item in
                HighlightEditor(highlight: item.highlight, onDelete: {
                    app.deleteHighlight(item.highlight, context: context)
                }, focusNote: item.focusNote)
                .presentationDetents([.medium, .large])
            }
            .onDisappear { app.pendingHighlightID = nil }
            .translationTask(translationConfig) { session in
                await translate(using: session)
            }
            .task(id: article.key) { await onOpen() }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .reader:
            ReaderWebView(html: html, baseURL: URL(string: article.link),
                          highlights: display == .translated && hasTranslation ? [] : highlights.map(HighlightPayload.init),
                          scrollToHighlightID: app.pendingHighlightID,
                          searchTerm: app.searchQuery,
                          ttsSentence: player.articleKey == article.key
                              ? player.currentSentence.map { (player.index, $0.text) } : nil,
                          onCreateHighlight: { info, withNote in addHighlight(info, withNote: withNote) },
                          onTapHighlight: { id in
                              if let h = highlights.first(where: { $0.id.uuidString == id }) {
                                  editing = EditingHighlight(highlight: h, focusNote: false)
                              }
                          },
                          onReady: { webView in
                              #if DEBUG
                              if ProcessInfo.processInfo.arguments.contains("-scrollToComments") {
                                  webView.evaluateJavaScript("document.querySelector('section.comments')?.scrollIntoView()",
                                                             in: nil, in: ReaderWebView.world) { _ in }
                              }
                              #endif
                          })
                .background(Color(hex: settings.theme.palette.bg).ignoresSafeArea())
                .overlay(alignment: .top) {
                    if loading || translating {
                        Label(translating ? "번역 중…" : "본문 가져오는 중…", systemImage: "arrow.down.circle")
                            .font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 8)
                    }
                }
        case .web:
            if let url = URL(string: article.link), network.isOnline {
                OriginalWebView(url: url, controller: webPage)
                    .overlay(alignment: .top) {
                        if webPage.progress < 1 { ProgressView(value: webPage.progress).progressViewStyle(.linear) }
                    }
            } else {
                ContentUnavailableView("오프라인입니다", systemImage: "wifi.slash",
                                       description: Text("원본 웹페이지는 인터넷에 연결되어 있을 때 볼 수 있습니다. 리더 보기는 오프라인에서도 됩니다."))
            }
        }
    }

    /// 지금 보고 있는 페이지가 이 글의 페이지인지 (다른 글로 이동했으면 저장하지 않는다)
    private var isOnArticlePage: Bool {
        guard let current = webPage.currentURL?.absoluteString else { return false }
        return URLNormalizer.normalize(current) == URLNormalizer.normalize(article.link)
    }

    @ViewBuilder
    private var captureButton: some View {
        let onPage = isOnArticlePage
        Button {
            Task { await capture() }
        } label: {
            Label(capturing ? "저장하는 중…" : (onPage ? "이 페이지를 리더로 저장" : "원래 글 페이지에서만 저장할 수 있어요"),
                  systemImage: onPage ? "square.and.arrow.down.on.square" : "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(!onPage || capturing || webPage.progress < 1)
    }

    private func capture() async {
        guard let page = await webPage.captureHTML() else { return }
        capturing = true
        defer { capturing = false }
        switch await app.saveCaptured(html: page.html, url: page.url, articleKey: article.key) {
        case .saved:
            mode = .reader
            showToast("본문을 저장했습니다. 이제 오프라인에서도 읽을 수 있어요.")
        case .blocked:
            showToast("아직 사이트 확인 화면입니다. 확인을 마친 뒤 다시 눌러 주세요.")
        case .notFound:
            showToast("이 페이지에서 본문을 찾지 못했습니다.")
        case .missing:
            break
        }
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == text { toast = nil }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if mode == .web, network.isOnline {
            // 웹페이지를 가리지 않도록 하단 툴바에 둔다
            ToolbarItem(placement: .bottomBar) { captureButton }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { mode = mode == .reader ? .web : .reader } label: {
                Image(systemName: mode == .reader ? "safari" : "doc.plaintext")
            }
            .accessibilityLabel(mode == .reader ? "원본 웹으로 보기" : "리더로 보기")
            if mode == .reader {
                if isForeign {
                    Menu {
                        Picker("번역 보기", selection: Binding(get: { display }, set: setDisplay)) {
                            ForEach(TranslationDisplay.allCases) { Text($0.label).tag($0) }
                        }
                        if hasTranslation {
                            Button { article.translations = [:]; article.translatedTitle = nil; article.refreshSearchText(); requestTranslation() } label: {
                                Label("다시 번역", systemImage: "arrow.clockwise")
                            }
                        }
                    } label: {
                        Image(systemName: hasTranslation && display != .original ? "translate" : "globe")
                            .symbolVariant(hasTranslation && display != .original ? .fill : .none)
                    } primaryAction: {
                        if hasTranslation {
                            setDisplay(display == .original ? .both : .original)
                        } else {
                            if display == .original { displayRaw = TranslationDisplay.both.rawValue }
                            requestTranslation()
                        }
                    }
                    .accessibilityLabel("번역")
                }
                Button {
                    if player.articleKey == article.key { player.togglePause() } else { player.play(article) }
                } label: {
                    Image(systemName: player.articleKey == article.key && player.isPlaying
                          ? "pause.circle" : "speaker.wave.2")
                }
                .accessibilityLabel("읽어주기")
                Button { showStyle = true } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("읽기 스타일")
            }
            Menu {
                Button { article.setStarred(!article.isStarred) } label: {
                    Label(article.isStarred ? "별표 해제" : "별표", systemImage: article.isStarred ? "star.slash" : "star")
                }
                Button { article.setSaved(!article.isSaved) } label: {
                    Label(article.isSaved ? "나중에 읽기 해제" : "나중에 읽기", systemImage: article.isSaved ? "clock.badge.xmark" : "clock")
                }
                if let original = article.originalURL.flatMap(URL.init(string:)) {
                    Button { openURL(original) } label: { Label("원문 기사 열기", systemImage: "arrow.up.right.square") }
                }
                if let url = URL(string: article.link) {
                    ShareLink(item: url) { Label("공유", systemImage: "square.and.arrow.up") }
                    Button { openURL(url) } label: { Label("Safari에서 열기", systemImage: "safari") }
                }
                Button { Task { await refetch() } } label: {
                    Label("원문에서 본문 다시 가져오기", systemImage: "arrow.down.doc")
                }
                Button { article.setRead(false) } label: {
                    Label("읽지 않음으로 표시", systemImage: "circle.inset.filled")
                }
            } label: {
                Image(systemName: article.isStarred ? "star.circle.fill" : "ellipsis")
            }
            .accessibilityLabel("더 보기")
        }
    }

    // MARK: - 동작

    private func onOpen() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-web") { mode = .web }
        if args.contains("-markFailed") { article.contentStatus = .failed }
        if args.contains("-style") { showStyle = true }
        if args.contains("-speak") { player.play(article) }
        if let path = DemoData.argument("-extrasFile"), let html = try? String(contentsOfFile: path, encoding: .utf8),
           let extras = SiteRules.extras(html: html, baseURL: URL(string: "https://news.hada.io/topic?id=34811")!) {
            article.apply(extras)
        }
        if args.contains("-demoHighlight"), highlights.isEmpty {
            let blocks = TranslationPlanner.blocks(in: preparedBody)
            for (i, block) in blocks.prefix(3).enumerated() where block.text.count > 30 {
                let words = block.text.split(separator: " ")
                let quote = words.prefix(8).joined(separator: " ")
                let h = Highlight(articleKey: article.key, articleTitle: article.title, articleLink: article.link,
                                  feedTitle: article.feedTitle, quote: quote, prefix: "", suffix: "",
                                  color: HighlightColor.allCases[i % 5])
                if i == 0 { h.note = "디버그용 메모 예시입니다." }
                context.insert(h)
            }
            try? context.save()
        }
        if args.contains("-fakeTranslate") {
            let blocks = TranslationPlanner.blocks(in: preparedBody)
            article.translations = Dictionary(uniqueKeysWithValues: blocks.map { ($0.index, "[번역 예시] " + $0.text) })
            article.translatedTitle = "[번역 예시] " + article.title
            if let d = DemoData.argument("-display") { displayRaw = d }
        }
        if args.contains("-translate") { displayRaw = TranslationDisplay.both.rawValue; requestTranslation() }
        #endif
        if !article.isRead {
            article.setRead(true)
            app.sessionReadKeys.insert(article.key)
            // 나중에 읽기 목록에서 처음 열어 읽은 글은 목록에서 뺀다 (이 화면을 떠날 때까지는 목록에 남아 있음)
            if article.isSaved, autoRemoveSaved { article.setSaved(false) }
        }
        if article.contentStatus == .pending || !article.imagesCached {
            loading = article.contentStatus == .pending
            await app.cache(articleKey: article.key)
            loading = false
        }
        if autoTranslate, isForeign, !hasTranslation { requestTranslation() }
        // 댓글은 계속 늘어나므로 30분이 지났으면 새로 받는다
        if SiteRules.supportsExtras(article.link), network.isOnline,
           Date().timeIntervalSince(article.extrasFetchedAt ?? .distantPast) > 30 * 60 {
            await app.refreshExtras(articleKey: article.key)
        }
    }

    private func addHighlight(_ info: SelectionInfo, withNote: Bool) {
        let h = Highlight(articleKey: article.key, articleTitle: article.title, articleLink: article.link,
                          feedTitle: article.feedTitle, quote: info.quote, prefix: info.prefix, suffix: info.suffix,
                          color: HighlightColor(rawValue: highlightColorRaw) ?? .yellow)
        context.insert(h)
        try? context.save()
        if withNote { editing = EditingHighlight(highlight: h, focusNote: true) }
    }

    private func refetch() async {
        loading = true
        await app.cache(articleKey: article.key, force: true)
        loading = false
    }

    private func setDisplay(_ value: TranslationDisplay) {
        displayRaw = value.rawValue
        if value != .original, !hasTranslation { requestTranslation() }
    }

    private func requestTranslation() {
        let source = article.languageCode.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: "ko")
        if translationConfig == nil || translationConfig?.source != source {
            translationConfig = TranslationSession.Configuration(source: source, target: target)
        } else {
            translationConfig?.invalidate()
        }
    }

    private func translate(using session: TranslationSession) async {
        translating = true
        defer { translating = false }
        let blocks = TranslationPlanner.blocks(in: preparedBody)
        var requests = blocks.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.index))
        }
        requests.append(TranslationSession.Request(sourceText: article.title, clientIdentifier: "title"))
        do {
            // TranslationSession 은 Sendable 표시가 없지만 이 클로저 안에서만 쓰이므로 안전하다
            nonisolated(unsafe) let unsafeSession = session
            nonisolated(unsafe) let unsafeRequests = requests
            let responses = try await unsafeSession.translations(from: unsafeRequests)
            var map: [Int: String] = [:]
            for response in responses {
                if response.clientIdentifier == "title" {
                    article.translatedTitle = response.targetText
                    article.refreshSearchText()
                } else if let id = response.clientIdentifier.flatMap(Int.init) {
                    map[id] = response.targetText
                }
            }
            article.translations = map
            try? context.save()
        } catch {
            app.message = "번역하지 못했습니다. 설정 > 앱 > 번역에서 언어를 내려받았는지 확인해 주세요.\n(\(error.localizedDescription))"
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
