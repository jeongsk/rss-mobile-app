import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark, black
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "시스템"
        case .light: "밝게"
        case .sepia: "세피아"
        case .dark: "어둡게"
        case .black: "검정"
        }
    }
    /// (배경, 글자, 보조 글자, 링크)
    var palette: (bg: String, fg: String, secondary: String, link: String) {
        switch self {
        case .system, .light: ("#ffffff", "#1c1c1e", "#6e6e73", "#0a64d6")
        case .sepia: ("#f6efe0", "#3b2f22", "#7d6b55", "#9a5b13")
        case .dark: ("#1c1c1e", "#e5e5ea", "#98989f", "#5aa9ff")
        case .black: ("#000000", "#d1d1d6", "#8e8e93", "#5aa9ff")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .sepia: .light
        case .dark, .black: .dark
        }
    }
}

/// 리더 화면 스타일 설정 (UserDefaults 저장, 기기 간 동기화는 SyncEngine 이 담당)
@MainActor
@Observable
final class ReaderSettings {
    static let shared = ReaderSettings()

    var fontSize: Double = 18 { didSet { save("fontSize", fontSize) } }
    var lineHeight: Double = 1.7 { didSet { save("lineHeight", lineHeight) } }
    var margin: Double = 20 { didSet { save("margin", margin) } }
    var paragraphSpacing: Double = 1.0 { didSet { save("paragraphSpacing", paragraphSpacing) } }
    var justify: Bool = false { didSet { save("justify", justify) } }
    var themeRaw: String = ReaderTheme.system.rawValue { didSet { save("theme", themeRaw) } }
    /// "system" | "serif" | "rounded" | "mono" | "custom:<PostScript 이름>"
    var fontChoice: String = "system" { didSet { save("fontChoice", fontChoice) } }

    var theme: ReaderTheme {
        get { ReaderTheme(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }

    private let defaults = UserDefaults.standard
    private var loading = false
    nonisolated static let prefix = "reader."
    nonisolated static let keys = ["fontSize", "lineHeight", "margin", "paragraphSpacing", "justify", "theme", "fontChoice"]

    private init() {
        load()
    }

    private func save(_ key: String, _ value: Any) {
        guard !loading else { return }
        defaults.set(value, forKey: Self.prefix + key)
        defaults.set(Date(), forKey: Self.prefix + "updatedAt")
    }

    /// 동기화 등 외부에서 UserDefaults 가 바뀐 뒤 다시 읽는다.
    func load() {
        loading = true
        defer { loading = false }
        func d(_ k: String) -> Any? { defaults.object(forKey: Self.prefix + k) }
        if let v = d("fontSize") as? Double { fontSize = v }
        if let v = d("lineHeight") as? Double { lineHeight = v }
        if let v = d("margin") as? Double { margin = v }
        if let v = d("paragraphSpacing") as? Double { paragraphSpacing = v }
        if let v = d("justify") as? Bool { justify = v }
        if let v = d("theme") as? String { themeRaw = v }
        if let v = d("fontChoice") as? String { fontChoice = v }
    }

    func reset() {
        fontSize = 18; lineHeight = 1.7; margin = 20; paragraphSpacing = 1.0
        justify = false; theme = .system; fontChoice = "system"
    }
}
