import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 폴더 선택: 없음 / 기존 폴더 / 새 폴더
struct FolderPicker: View {
    @Binding var folderID: UUID?
    @Binding var newFolderName: String
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    static let newFolderTag = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var body: some View {
        Picker("폴더", selection: $folderID) {
            Text("폴더 없음").tag(UUID?.none)
            ForEach(folders) { Text($0.name).tag(UUID?.some($0.id)) }
            Text("새 폴더…").tag(UUID?.some(Self.newFolderTag))
        }
        if folderID == Self.newFolderTag {
            TextField("새 폴더 이름", text: $newFolderName)
        }
    }

    @MainActor
    static func resolve(_ id: UUID?, newName: String, context: ModelContext) -> Folder? {
        guard let id else { return nil }
        if id == newFolderTag {
            let name = newName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let count = (try? context.fetchCount(FetchDescriptor<Folder>())) ?? 0
            let folder = Folder(name: name, sortOrder: count)
            context.insert(folder)
            return folder
        }
        return try? context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first
    }
}

struct AddFeedSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var folderID: UUID?
    @State private var newFolderName = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("사이트 또는 피드 주소", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                } footer: {
                    Text("블로그 주소만 입력해도 RSS/Atom 피드를 찾아 줍니다.")
                }
                Section { FolderPicker(folderID: $folderID, newFolderName: $newFolderName) }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("피드 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("추가", action: add).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func add() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let folder = FolderPicker.resolve(folderID, newName: newFolderName, context: context)
                _ = try await app.addFeed(urlString: url, folder: folder, context: context)
                dismiss()
            } catch {
                self.error = "피드를 찾지 못했습니다. 주소를 확인해 주세요."
            }
        }
    }
}

/// 주소를 붙여넣어 나중에 읽기에 담는다
struct AddLinkSheet: View {
    var onAdded: () -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("글 주소", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { url = first }
                    }
                } footer: {
                    Text("본문은 원문에서 받아 오프라인으로 저장합니다.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("나중에 읽기 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가", action: add).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        if app.addSavedLink(url, context: context) != nil {
            onAdded()
            dismiss()
        } else {
            error = "http 또는 https 로 시작하는 올바른 주소를 입력해 주세요."
        }
    }
}

struct ImportOPMLSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var picking = false
    @State private var document: OPMLDocument?
    @State private var result: (added: Int, skipped: Int)?
    @State private var error: String?

    static let opmlTypes: [UTType] = [UTType("org.opml.opml"), UTType(filenameExtension: "opml"), .xml]
        .compactMap { $0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Feedly에서 내보내기") {
                    Label("Feedly 웹사이트에 로그인한 뒤 OPML 내보내기 페이지에서 파일을 내려받으세요.",
                          systemImage: "1.circle")
                    Button {
                        openURL(URL(string: "https://feedly.com/i/opml")!)
                    } label: {
                        Label("Feedly OPML 내보내기 열기", systemImage: "safari")
                    }
                    Label("내려받은 .opml 파일을 아래에서 선택하세요.", systemImage: "2.circle")
                }

                Section {
                    Button { picking = true } label: {
                        Label("OPML 파일 선택", systemImage: "doc.badge.plus")
                    }
                }

                if let document {
                    Section("미리보기") {
                        LabeledContent("폴더", value: "\(document.folders.count)개")
                        LabeledContent("피드", value: "\(document.feedCount)개")
                        ForEach(document.folders, id: \.name) { folder in
                            DisclosureGroup("\(folder.name) (\(folder.feeds.count))") {
                                ForEach(folder.feeds, id: \.xmlURL) { Text($0.title).font(.subheadline) }
                            }
                        }
                        if !document.ungrouped.isEmpty {
                            DisclosureGroup("폴더 없음 (\(document.ungrouped.count))") {
                                ForEach(document.ungrouped, id: \.xmlURL) { Text($0.title).font(.subheadline) }
                            }
                        }
                    }
                    if let result {
                        Section {
                            Label("\(result.added)개를 추가했습니다" + (result.skipped > 0 ? " (중복 \(result.skipped)개 제외)" : ""),
                                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Feedly / OPML 가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "취소" : "닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if result == nil {
                        Button("가져오기", action: importNow).disabled(document == nil)
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.opmlTypes) { picked in
                load(picked)
            }
        }
    }

    private func load(_ picked: Result<URL, any Error>) {
        error = nil
        result = nil
        do {
            let url = try picked.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let doc = try OPMLParser.parse(try Data(contentsOf: url))
            guard doc.feedCount > 0 else { throw FeedParserError.notAFeed }
            document = doc
        } catch {
            self.error = "OPML 파일을 읽을 수 없습니다."
        }
    }

    private func importNow() {
        guard let document else { return }
        do {
            result = try app.importOPML(document, context: context)
            Task { await app.refreshAll() }
        } catch {
            self.error = "가져오기에 실패했습니다: \(error.localizedDescription)"
        }
    }
}

/// 이름 입력 알림 (폴더 생성/이름 변경)
struct NamePrompt: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    @State var text: String
    let onSave: (String) -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            TextField("이름", text: $text)
            Button("취소", role: .cancel) {}
            Button("저장") {
                let name = text.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { onSave(name) }
            }
        }
    }
}
