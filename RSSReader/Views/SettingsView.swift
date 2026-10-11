import SwiftUI
import SwiftData
import AVFoundation

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var sync = SyncManager.shared
    @State private var settings = ReaderSettings.shared
    @State private var player = SpeechPlayer.shared
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var pickingFolder = false
    @State private var showStyle = false
    @State private var cacheSize: Int64 = 0
    @State private var confirmClear = false

    @AppStorage(AppSettingsKeys.retentionDays) private var retentionDays = 30
    @AppStorage(AppSettingsKeys.autoRemoveSaved) private var autoRemoveSaved = true
    @AppStorage(AppSettingsKeys.notificationsEnabled) private var notificationsEnabled = false
    @AppStorage(AppSettingsKeys.notifyBadge) private var notifyBadge = false
    @Query(filter: #Predicate<Feed> { $0.notifies }) private var notifyFeeds: [Feed]
    @AppStorage(AppSettingsKeys.cacheImages) private var cacheImages = true
    @AppStorage(AppSettingsKeys.backgroundRefresh) private var backgroundRefresh = true
    @AppStorage("autoTranslate") private var autoTranslate = false
    @AppStorage("translationDisplay") private var translationDisplay = TranslationDisplay.both.rawValue

    var body: some View {
        NavigationStack {
            Form {
                syncSection
                subscriptionSection
                notificationSection
                readingSection
                offlineSection
                speechSection
                aboutSection
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .sheet(isPresented: $importing) { ImportOPMLSheet() }
            .sheet(isPresented: $showStyle) { ReaderStylePanel(settings: settings) }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                guard let url = try? result.get() else { return }
                do {
                    try sync.setFolder(url)
                    // 두 번째 기기라면 OPML 을 다시 가져오기 전에 먼저 받아온다
                    Task { await app.sync() }
                } catch {
                    app.message = "폴더를 사용할 수 없습니다: \(error.localizedDescription)"
                }
            }
            .confirmationDialog("저장된 이미지를 모두 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("이미지 캐시 비우기", role: .destructive) {
                    ImageCache.clear()
                    cacheSize = ImageCache.totalSize()
                }
            } message: {
                Text("글 본문은 남고, 이미지는 다음에 열 때 다시 내려받습니다.")
            }
            .task {
                exportURL = try? app.exportOPML(context: context)
                cacheSize = ImageCache.totalSize()
            }
        }
    }

    // MARK: - 섹션

    private var syncSection: some View {
        Section {
            if let name = sync.folderName {
                LabeledContent("동기화 폴더", value: name)
                LabeledContent("마지막 동기화") {
                    if sync.isSyncing {
                        ProgressView()
                    } else if let last = sync.lastSync {
                        Text(last, format: .relative(presentation: .named))
                    } else {
                        Text("없음")
                    }
                }
                if let error = sync.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button { Task { await app.sync() } } label: {
                    Label("지금 동기화", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.isSyncing)
                Button { pickingFolder = true } label: { Label("다른 폴더 선택", systemImage: "folder") }
                Button("동기화 해제", role: .destructive) { sync.disconnect() }
            } else {
                Button { pickingFolder = true } label: {
                    Label("iCloud Drive 동기화 폴더 선택", systemImage: "icloud")
                }
            }
        } header: {
            Text("기기 간 동기화")
        } footer: {
            Text("아이폰과 아이패드에서 iCloud Drive의 같은 폴더(예: '내 RSS 동기화')를 한 번씩 선택하세요. 구독·폴더, 읽음·별표, 하이라이트·메모, 읽기 설정, 사용자 폰트가 맞춰집니다. 앱을 열거나 새로고침할 때, 앱을 닫을 때 동기화되며 실시간은 아닙니다. 글 본문 캐시는 기기마다 따로 저장합니다.")
        }
    }

    private var subscriptionSection: some View {
        Section("구독") {
            Button { importing = true } label: {
                Label("Feedly / OPML 가져오기", systemImage: "square.and.arrow.down")
            }
            if let exportURL {
                ShareLink(item: exportURL) { Label("OPML 내보내기", systemImage: "square.and.arrow.up") }
            }
            Toggle(isOn: $backgroundRefresh) {
                Label("백그라운드에서 새 글 받기", systemImage: "arrow.clockwise.circle")
            }
            .onChange(of: backgroundRefresh) { BackgroundTasks.scheduleAll() }
            Toggle(isOn: $autoRemoveSaved) {
                Label("읽으면 나중에 읽기에서 제거", systemImage: "clock.badge.checkmark")
            }
            if let last = UserDefaults.standard.object(forKey: AppSettingsKeys.lastRefresh) as? Date {
                LabeledContent("마지막 새로고침") { Text(last, format: .relative(presentation: .named)) }
            }
        }
    }

    private var notificationSection: some View {
        Section {
            Toggle(isOn: Binding(get: { notificationsEnabled }, set: { on in
                if on {
                    Task {
                        if await NotificationService.requestAuthorization() {
                            notificationsEnabled = true
                        } else {
                            notificationsEnabled = false
                            app.message = "알림 권한이 꺼져 있습니다. 설정 앱의 이 앱 알림에서 허용해 주세요."
                            NotificationService.openSystemSettings()
                        }
                    }
                } else {
                    notificationsEnabled = false
                }
            })) {
                Label("새 글 알림", systemImage: "bell.badge")
            }
            Toggle(isOn: $notifyBadge) {
                Label("앱 아이콘에 읽지 않은 글 수 표시", systemImage: "app.badge")
            }
            .onChange(of: notifyBadge) { Task { await NotificationService.updateBadge(context) } }
            let count = notifyFeeds.count
            LabeledContent("알림 받는 피드") { Text(count == 0 ? "없음" : "\(count)개") }
        } header: {
            Text("알림")
        } footer: {
            Text("피드나 폴더를 길게 눌러 '새 글 알림'을 켜세요. 앱을 열 때와 백그라운드 갱신이 돌 때 확인한 새 글만 알려 주며, 실시간 알림은 아닙니다.")
        }
    }

    private var readingSection: some View {
        Section {
            Button { showStyle = true } label: {
                LabeledContent {
                    Text("\(Int(settings.fontSize))pt · \(settings.theme.label)")
                } label: {
                    Label("읽기 스타일·글꼴", systemImage: "textformat.size")
                }
            }
            .tint(.primary)
            Picker(selection: $translationDisplay) {
                ForEach(TranslationDisplay.allCases) { Text($0.label).tag($0.rawValue) }
            } label: {
                Label("번역 표시", systemImage: "translate")
            }
            Toggle(isOn: $autoTranslate) {
                Label("외국어 글 자동 번역", systemImage: "globe")
            }
        } header: {
            Text("읽기")
        } footer: {
            Text("번역은 Apple 기기 내 번역을 사용합니다(무료). 처음 번역할 때 언어 모델을 내려받으며, 이후에는 오프라인에서도 번역됩니다. 설정 > 앱 > 번역에서 언어를 관리할 수 있습니다.")
        }
    }

    private var offlineSection: some View {
        Section {
            Toggle(isOn: $cacheImages) {
                Label("본문 이미지도 저장", systemImage: "photo.on.rectangle")
            }
            Picker(selection: $retentionDays) {
                Text("7일").tag(7)
                Text("30일").tag(30)
                Text("90일").tag(90)
                Text("1년").tag(365)
                Text("무제한").tag(0)
            } label: {
                Label("글 보관 기간", systemImage: "calendar")
            }
            .onChange(of: retentionDays) { Task { await app.purge() } }
            LabeledContent {
                Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
            } label: {
                Label("이미지 캐시", systemImage: "internaldrive")
            }
            Button { Task { await app.cachePending(limit: 500) } } label: {
                Label(app.isCaching ? "저장하는 중…" : "남은 글 모두 오프라인 저장", systemImage: "arrow.down.circle")
            }
            .disabled(app.isCaching)
            Button("이미지 캐시 비우기", role: .destructive) { confirmClear = true }
        } header: {
            Text("오프라인")
        } footer: {
            Text("새 글은 받는 즉시 전체 본문을 저장합니다. 보관 기간이 지난 글은 지우지만, 별표하거나 하이라이트한 글은 남겨 둡니다.")
        }
    }

    private var speechSection: some View {
        Section {
            Picker(selection: $player.rate) {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%.2gx", $0)).tag($0) }
            } label: {
                Label("읽기 속도", systemImage: "speedometer")
            }
            Toggle(isOn: $player.readTranslation) {
                Label("번역문이 있으면 번역문으로 읽기", systemImage: "character.bubble")
            }
            voicePicker(language: "ko", title: "한국어 음성")
            voicePicker(language: "en", title: "영어 음성")
        } header: {
            Text("읽어주기 (TTS)")
        } footer: {
            Text("더 자연스러운 음성은 설정 > 손쉬운 사용 > 읽기 및 말하기 콘텐츠 > 음성에서 '고품질' 음성을 내려받으면 여기에 나타납니다.")
        }
    }

    private func voicePicker(language: String, title: String) -> some View {
        let voices = SpeechPlayer.voices(for: language)
        return Picker(selection: Binding(
            get: { SpeechPlayer.voice(for: language)?.identifier ?? "" },
            set: { UserDefaults.standard.set($0, forKey: SpeechPlayer.voiceKey(language)) })) {
            ForEach(voices, id: \.identifier) { v in
                Text("\(v.name) · \(MiniPlayer.qualityLabel(v.quality))").tag(v.identifier)
            }
        } label: {
            Label(title, systemImage: "person.wave.2")
        }
    }

    private var aboutSection: some View {
        Section("정보") {
            LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
            LabeledContent("App Group (위젯 연결)") {
                Text(AppGroup.isUsable ? "사용 가능" : "사용 불가")
                    .foregroundStyle(AppGroup.isUsable ? .green : .red)
            }
            Link(destination: URL(string: "https://feedly.com/i/opml")!) {
                Label("Feedly OPML 내보내기 페이지", systemImage: "safari")
            }
        }
    }
}
