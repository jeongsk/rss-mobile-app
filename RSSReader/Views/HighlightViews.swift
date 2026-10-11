import SwiftUI
import SwiftData

/// 하이라이트 색상/메모 편집
struct HighlightEditor: View {
    @Bindable var highlight: Highlight
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var noteFocused: Bool
    var focusNote = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(highlight.quote)
                        .font(.body)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color(hex: highlight.color.hex)).frame(width: 4)
                        }
                }
                Section("색상") {
                    HStack(spacing: 14) {
                        ForEach(HighlightColor.allCases) { color in
                            Button {
                                highlight.color = color
                                highlight.updatedAt = Date()
                                UserDefaults.standard.set(color.rawValue, forKey: "highlightColor")
                            } label: {
                                Circle().fill(Color(hex: color.hex))
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if highlight.color == color {
                                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black.opacity(0.7))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.rawValue)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("메모") {
                    TextField("메모를 남겨 보세요", text: Binding(get: { highlight.note }, set: {
                        highlight.note = $0
                        highlight.updatedAt = Date()
                    }), axis: .vertical)
                    .lineLimit(3...12)
                    .focused($noteFocused)
                }
                Section {
                    Button("하이라이트 삭제", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("하이라이트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .onAppear { if focusNote { noteFocused = true } }
        }
    }
}

/// 모든 하이라이트 모아보기 (글별로 묶음)
struct HighlightListView: View {
    @Binding var selection: PersistentIdentifier?
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query(sort: \Highlight.createdAt, order: .reverse) private var highlights: [Highlight]
    @State private var search = ""

    private var groups: [(key: String, items: [Highlight])] {
        let filtered = search.isEmpty ? highlights : highlights.filter {
            $0.quote.localizedCaseInsensitiveContains(search) || $0.note.localizedCaseInsensitiveContains(search)
                || $0.articleTitle.localizedCaseInsensitiveContains(search)
        }
        var order: [String] = []
        var map: [String: [Highlight]] = [:]
        for h in filtered {
            if map[h.articleKey] == nil { order.append(h.articleKey) }
            map[h.articleKey, default: []].append(h)
        }
        return order.map { ($0, map[$0]!.sorted { $0.createdAt < $1.createdAt }) }
    }

    var body: some View {
        Group {
            if highlights.isEmpty {
                ContentUnavailableView("하이라이트가 없습니다", systemImage: "highlighter",
                                       description: Text("글에서 문장을 길게 눌러 선택한 뒤 '하이라이트' 또는 '메모'를 고르세요."))
            } else {
                List {
                    ForEach(groups, id: \.key) { group in
                        Section {
                            ForEach(group.items) { h in
                                Button { open(h) } label: { HighlightRow(highlight: h) }
                                    .buttonStyle(.plain)
                                    .swipeActions {
                                        Button("삭제", role: .destructive) { app.deleteHighlight(h, context: context) }
                                    }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.items.first?.articleTitle ?? "").font(.subheadline.bold()).foregroundStyle(.primary)
                                Text(group.items.first?.feedTitle ?? "").font(.caption)
                            }
                            .textCase(nil)
                        }
                    }
                }
                .searchable(text: $search, prompt: "하이라이트·메모 검색")
            }
        }
        .navigationTitle("하이라이트")
        .toolbar {
            if !highlights.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: HighlightExport.markdown(highlights),
                              preview: SharePreview("하이라이트.md")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Markdown으로 내보내기")
                }
            }
        }
    }

    private func open(_ h: Highlight) {
        let key = h.articleKey
        if let article = try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first {
            app.pendingHighlightID = h.id.uuidString
            selection = article.persistentModelID
        } else if let url = URL(string: h.articleLink) {
            // 보관 기간이 지나 글 캐시가 지워진 경우 원문을 연다
            openURL(url)
        }
    }
}

struct HighlightRow: View {
    let highlight: Highlight

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: highlight.color.hex))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(highlight.quote).font(.body).lineLimit(6)
                if !highlight.note.isEmpty {
                    Label(highlight.note, systemImage: "note.text")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(highlight.createdAt, format: .dateTime.year().month().day())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

enum HighlightExport {
    /// Obsidian 등에서 쓰기 좋은 Markdown
    static func markdown(_ highlights: [Highlight]) -> String {
        var out = "# 하이라이트\n"
        var seen: [String: [Highlight]] = [:]
        var order: [String] = []
        for h in highlights.sorted(by: { $0.createdAt < $1.createdAt }) {
            if seen[h.articleKey] == nil { order.append(h.articleKey) }
            seen[h.articleKey, default: []].append(h)
        }
        for key in order {
            guard let items = seen[key], let first = items.first else { continue }
            out += "\n## [\(first.articleTitle)](\(first.articleLink))\n"
            out += "_\(first.feedTitle)_\n\n"
            for h in items {
                out += h.quote.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n"
                if !h.note.isEmpty { out += "\n\(h.note)\n" }
                out += "\n"
            }
        }
        return out
    }
}
