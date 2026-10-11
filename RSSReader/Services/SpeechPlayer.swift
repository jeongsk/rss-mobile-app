import Foundation
import AVFoundation
import MediaPlayer
import NaturalLanguage
import SwiftData

/// 읽어줄 문장
struct SpeechSentence: Equatable, Sendable {
    let text: String
    let language: String
}

enum SpeechText {
    /// 정리된 본문 HTML 을 문장 단위로 나눈다.
    /// - useTranslation: 번역문이 있는 문단은 번역문(한국어)으로 읽는다.
    static func sentences(title: String, preparedHTML: String, language: String,
                          translations: [Int: String] = [:], translatedTitle: String? = nil,
                          useTranslation: Bool = false) -> [SpeechSentence] {
        var out: [SpeechSentence] = []
        func add(_ text: String, _ lang: String) {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if s.contains(where: \.isLetter) { out.append(SpeechSentence(text: s, language: lang)) }
                return true
            }
        }
        if useTranslation, let translatedTitle { add(translatedTitle, "ko") } else { add(title, language) }
        for block in TranslationPlanner.blocks(in: preparedHTML) {
            if useTranslation, let tr = translations[block.index] {
                add(tr, "ko")
            } else {
                add(block.text, language)
            }
        }
        return out
    }
}

/// TTS 재생기. 문장 단위로 읽고, 재생 목록(여러 글 연속 듣기)과 잠금 화면 제어를 지원한다.
@MainActor
@Observable
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechPlayer()

    private(set) var articleKey: String?
    private(set) var articleTitle = ""
    private(set) var feedTitle = ""
    private(set) var sentences: [SpeechSentence] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    /// 다음에 읽을 글들 (article key)
    private(set) var queue: [String] = []

    var rate: Double = UserDefaults.standard.object(forKey: "tts.rate") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(rate, forKey: "tts.rate"); restartCurrentSentence() }
    }
    var readTranslation: Bool = UserDefaults.standard.bool(forKey: "tts.readTranslation") {
        didSet { UserDefaults.standard.set(readTranslation, forKey: "tts.readTranslation") }
    }

    var currentSentence: SpeechSentence? { sentences.indices.contains(index) ? sentences[index] : nil }
    var isActive: Bool { articleKey != nil }
    var progress: Double { sentences.isEmpty ? 0 : Double(index) / Double(sentences.count) }

    private let synthesizer = AVSpeechSynthesizer()
    private var container: ModelContainer?
    /// 문장을 건너뛸 때 이전 발화의 didCancel 이 다음 문장으로 넘어가지 않도록 세대 번호를 둔다
    private var generation = 0
    private var utteranceGeneration: [ObjectIdentifier: Int] = [:]

    private override init() {
        super.init()
        synthesizer.delegate = self
        setupRemoteCommands()
    }

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - 음성

    static func voiceKey(_ language: String) -> String { "tts.voice." + String(language.prefix(2)) }

    /// 언어별로 사용자가 고른 음성, 없으면 가장 품질 좋은 음성
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey(language)),
           let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices(for: language).first
    }

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    // MARK: - 재생 제어

    /// 글 읽기 시작. queue 가 있으면 끝난 뒤 이어서 읽는다.
    func play(_ article: Article, queue: [String] = [], from start: Int = 0) {
        let prepared = ReaderHTMLBuilder.prepareBody(article.bestHTML, baseURL: URL(string: article.link), title: article.title)
        let language = article.languageCode ?? LanguageDetector.detect(article.snippet) ?? "ko"
        let useTranslation = readTranslation && !article.translations.isEmpty
        sentences = SpeechText.sentences(title: article.title, preparedHTML: prepared, language: language,
                                         translations: article.translations, translatedTitle: article.translatedTitle,
                                         useTranslation: useTranslation)
        articleKey = article.key
        articleTitle = article.title
        feedTitle = article.feedTitle
        self.queue = queue.filter { $0 != article.key }
        index = min(start, max(0, sentences.count - 1))
        activateSession()
        speakCurrent()
    }

    func togglePause() {
        if isPlaying {
            synthesizer.pauseSpeaking(at: .word)
            isPlaying = false
        } else if synthesizer.isPaused {
            activateSession()
            synthesizer.continueSpeaking()
            isPlaying = true
        } else {
            activateSession()
            speakCurrent()
        }
        updateNowPlaying()
    }

    func skip(by delta: Int) {
        guard !sentences.isEmpty else { return }
        index = max(0, min(sentences.count - 1, index + delta))
        speakCurrent()
    }

    func stop() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        articleKey = nil
        sentences = []
        queue = []
        index = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func nextArticle() {
        guard let container, let nextKey = queue.first else { stop(); return }
        let context = container.mainContext
        guard let next = try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == nextKey })).first
        else { queue.removeFirst(); nextArticle(); return }
        next.setRead(true)
        play(next, queue: Array(queue.dropFirst()))
    }

    private func restartCurrentSentence() {
        if isPlaying { speakCurrent() }
    }

    private func speakCurrent() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        guard let sentence = currentSentence else { finishedArticle(); return }
        let utterance = AVSpeechUtterance(string: sentence.text)
        utterance.voice = Self.voice(for: sentence.language)
        // rate 1.0 = 기본 속도
        utterance.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate,
                                       Double(AVSpeechUtteranceMinimumSpeechRate)),
                                   Double(AVSpeechUtteranceMaximumSpeechRate)))
        utterance.postUtteranceDelay = 0.05
        utteranceGeneration[ObjectIdentifier(utterance)] = generation
        synthesizer.speak(utterance)
        isPlaying = true
        updateNowPlaying()
    }

    private func finishedArticle() {
        isPlaying = false
        if queue.isEmpty { stop() } else { nextArticle() }
    }

    private func utteranceDidFinish(_ id: ObjectIdentifier) {
        let gen = utteranceGeneration.removeValue(forKey: id)
        guard gen == generation, isPlaying else { return }
        index += 1
        if index < sentences.count { speakCurrent() } else { finishedArticle() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceDidFinish(id) }
    }

    // MARK: - 오디오 세션 / 잠금 화면

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func updateNowPlaying() {
        guard isActive else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: articleTitle,
            MPMediaItemPropertyArtist: feedTitle,
            MPMediaItemPropertyPlaybackDuration: Double(sentences.count),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(index),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            MainActor.assumeIsolated { if !SpeechPlayer.shared.isPlaying { SpeechPlayer.shared.togglePause() } }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { if SpeechPlayer.shared.isPlaying { SpeechPlayer.shared.togglePause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { SpeechPlayer.shared.togglePause() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { SpeechPlayer.shared.nextArticle() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [1]
        center.skipForwardCommand.addTarget { _ in
            MainActor.assumeIsolated { SpeechPlayer.shared.skip(by: 3) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [1]
        center.skipBackwardCommand.addTarget { _ in
            MainActor.assumeIsolated { SpeechPlayer.shared.skip(by: -3) }
            return .success
        }
    }
}
