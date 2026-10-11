import SwiftUI

/// 리더 스타일 조절 패널 (Aa)
struct ReaderStylePanel: View {
    @Bindable var settings: ReaderSettings
    @State private var fonts = FontStore.shared
    @State private var importingFont = false
    @State private var fontError: String?
    @State private var downloadError: String?
    @Environment(\.dismiss) private var dismiss

    private let builtInFonts: [(id: String, name: String, font: Font)] = [
        ("system", "기본", .system(.body)),
        ("serif", "명조", .system(.body, design: .serif)),
        ("rounded", "둥근", .system(.body, design: .rounded)),
        ("mono", "고정폭", .system(.body, design: .monospaced)),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("테마") {
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases) { theme in
                            ThemeChip(theme: theme, selected: settings.theme == theme) { settings.theme = theme }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("글자") {
                    StepperRow(title: "크기", value: $settings.fontSize, range: 12...32, step: 1,
                               format: { "\(Int($0))pt" }, icons: ("textformat.size.smaller", "textformat.size.larger"))
                    StepperRow(title: "줄 간격", value: $settings.lineHeight, range: 1.2...2.4, step: 0.1,
                               format: { String(format: "%.1f", $0) }, icons: ("arrow.down.right.and.arrow.up.left", "arrow.up.left.and.arrow.down.right"))
                    StepperRow(title: "문단 간격", value: $settings.paragraphSpacing, range: 0.4...2.0, step: 0.2,
                               format: { String(format: "%.1f", $0) }, icons: ("minus", "plus"))
                    StepperRow(title: "여백", value: $settings.margin, range: 8...64, step: 4,
                               format: { "\(Int($0))" }, icons: ("arrow.left.and.right.square", "arrow.left.and.right.square.fill"))
                    Toggle("양쪽 정렬", isOn: $settings.justify)
                }

                Section {
                    ForEach(builtInFonts, id: \.id) { item in
                        fontRow(id: item.id, name: item.name, preview: item.font)
                    }
                    ForEach(fonts.fonts) { font in
                        fontRow(id: "custom:\(font.postScriptName)", name: font.displayName,
                                preview: .custom(font.postScriptName, size: 17))
                            .swipeActions {
                                Button("삭제", role: .destructive) { fonts.delete(font) }
                            }
                    }
                    Button { importingFont = true } label: {
                        Label("폰트 파일 추가 (TTF·OTF)", systemImage: "plus.circle")
                    }
                } header: {
                    Text("글꼴")
                } footer: {
                    if let fontError { Text(fontError).foregroundStyle(.red) }
                    else { Text("파일 앱에 있는 폰트 파일을 추가할 수 있습니다. 왼쪽으로 밀어 삭제합니다.") }
                }

                Section {
                    ForEach(GoogleFont.catalog) { gf in
                        if !fonts.isInstalled(gf) {
                            Button { download(gf) } label: {
                                HStack {
                                    Text(gf.name)
                                    Spacer()
                                    if fonts.downloading.contains(gf.id) {
                                        ProgressView()
                                    } else {
                                        Text("\(gf.megabytes)MB").font(.caption).foregroundStyle(.secondary)
                                        Image(systemName: "arrow.down.circle")
                                    }
                                }
                            }
                            .tint(.primary)
                            .disabled(fonts.downloading.contains(gf.id))
                        }
                    }
                } header: {
                    Text("구글 폰트 (한국어)")
                } footer: {
                    if let downloadError { Text(downloadError).foregroundStyle(.red) }
                    else { Text("내려받으면 위 글꼴 목록에 추가됩니다. 처음 한 번만 네트워크가 필요합니다.") }
                }

                Section {
                    Button("기본값으로 되돌리기", role: .destructive) { settings.reset() }
                }
            }
            .navigationTitle("읽기 스타일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .fileImporter(isPresented: $importingFont, allowedContentTypes: FontStore.allowedTypes,
                          allowsMultipleSelection: true) { result in
                fontError = nil
                do {
                    for url in try result.get() {
                        let added = try fonts.importFont(from: url)
                        if let first = added.first { settings.fontChoice = "custom:\(first.postScriptName)" }
                    }
                } catch {
                    fontError = error.localizedDescription
                }
            }
        }
    }

    private func download(_ gf: GoogleFont) {
        downloadError = nil
        Task {
            do {
                if let first = try await fonts.download(gf).first { settings.fontChoice = "custom:\(first.postScriptName)" }
            } catch {
                downloadError = "\(gf.name) 내려받기 실패: \(error.localizedDescription)"
            }
        }
    }

    private func fontRow(id: String, name: String, preview: Font) -> some View {
        Button {
            settings.fontChoice = id
        } label: {
            HStack {
                Text(name).font(preview)
                Spacer()
                Text("가나다 Abc").font(preview).foregroundStyle(.secondary)
                if settings.fontChoice == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .tint(.primary)
    }
}

private struct ThemeChip: View {
    let theme: ReaderTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if theme == .system {
                        HStack(spacing: 0) {
                            Color.white
                            Color(white: 0.11)
                        }
                    } else {
                        Color(hex: theme.palette.bg)
                    }
                    Text("가").font(.headline)
                        .foregroundStyle(theme == .system ? Color.gray : Color(hex: theme.palette.fg))
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().stroke(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 3 : 1))
                Text(theme.label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct StepperRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let icons: (String, String)

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button { value = max(range.lowerBound, (value - step * 1.0001).rounded(to: step)) } label: {
                Image(systemName: icons.0).frame(width: 32, height: 28)
            }
            .buttonStyle(.bordered)
            Text(format(value)).monospacedDigit().frame(minWidth: 48)
            Button { value = min(range.upperBound, (value + step * 1.0001).rounded(to: step)) } label: {
                Image(systemName: icons.1).frame(width: 32, height: 28)
            }
            .buttonStyle(.bordered)
        }
    }
}

private extension Double {
    func rounded(to step: Double) -> Double { (self / step).rounded() * step }
}
