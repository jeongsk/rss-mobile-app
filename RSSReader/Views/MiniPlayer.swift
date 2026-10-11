import SwiftUI
import AVFoundation

/// 화면 하단 TTS 미니 플레이어
struct MiniPlayer: View {
    @State private var player = SpeechPlayer.shared

    private static let rates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        if player.isActive {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.articleTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(player.queue.isEmpty ? player.feedTitle : "\(player.feedTitle) · 다음 \(player.queue.count)개")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { player.skip(by: -1) } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("이전 문장")
                    Button { player.togglePause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    }
                    .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
                    Button { player.skip(by: 1) } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("다음 문장")
                    if !player.queue.isEmpty {
                        Button { player.nextArticle() } label: { Image(systemName: "forward.end.fill") }
                            .accessibilityLabel("다음 글")
                    }
                    optionsMenu
                    Button { player.stop() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("닫기")
                }
                .buttonStyle(.plain)
                ProgressView(value: player.progress).progressViewStyle(.linear).tint(.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .frame(maxWidth: 560)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("속도", selection: $player.rate) {
                ForEach(Self.rates, id: \.self) { Text(String(format: "%.2gx", $0)).tag($0) }
            }
            Toggle("번역문으로 읽기", isOn: $player.readTranslation)
            if let lang = player.currentSentence?.language {
                let voices = SpeechPlayer.voices(for: lang)
                if !voices.isEmpty {
                    Picker("음성", selection: Binding(
                        get: { SpeechPlayer.voice(for: lang)?.identifier ?? "" },
                        set: { UserDefaults.standard.set($0, forKey: SpeechPlayer.voiceKey(lang)) })) {
                        ForEach(voices, id: \.identifier) { v in
                            Text("\(v.name) · \(Self.qualityLabel(v.quality))").tag(v.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        } label: {
            Text(String(format: "%.2gx", player.rate)).font(.caption.monospacedDigit().bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .accessibilityLabel("읽기 설정")
    }

    static func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: "프리미엄"
        case .enhanced: "고품질"
        default: "기본"
        }
    }
}
