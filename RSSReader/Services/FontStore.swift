import Foundation
import CoreText
import UniformTypeIdentifiers

struct CustomFont: Identifiable, Hashable, Sendable {
    var id: String { postScriptName }
    let postScriptName: String
    let displayName: String
    let fileURL: URL
}

/// 앱에서 내려받을 수 있는 구글 폰트(한국어). 파일은 google/fonts 저장소(OFL 라이선스)에서 받는다.
struct GoogleFont: Identifiable, Hashable, Sendable {
    let name: String
    let folder: String
    let fileName: String
    let megabytes: Int
    var id: String { fileName }

    var url: URL {
        URL(string: "https://raw.githubusercontent.com/google/fonts/main/ofl/\(folder)/")!
            .appending(path: fileName.replacingOccurrences(of: "-VF", with: "[wght]"))
    }

    static let catalog: [GoogleFont] = [
        GoogleFont(name: "Noto Sans KR (고딕)", folder: "notosanskr", fileName: "NotoSansKR-VF.ttf", megabytes: 10),
        GoogleFont(name: "Noto Serif KR (명조)", folder: "notoserifkr", fileName: "NotoSerifKR-VF.ttf", megabytes: 24),
        GoogleFont(name: "나눔명조", folder: "nanummyeongjo", fileName: "NanumMyeongjo-Regular.ttf", megabytes: 3),
        GoogleFont(name: "나눔고딕", folder: "nanumgothic", fileName: "NanumGothic-Regular.ttf", megabytes: 2),
        GoogleFont(name: "고운바탕", folder: "gowunbatang", fileName: "GowunBatang-Regular.ttf", megabytes: 8),
        GoogleFont(name: "고운돋움", folder: "gowundodum", fileName: "GowunDodum-Regular.ttf", megabytes: 7),
        GoogleFont(name: "IBM Plex Sans KR", folder: "ibmplexsanskr", fileName: "IBMPlexSansKR-Regular.ttf", megabytes: 3),
        GoogleFont(name: "송명", folder: "songmyung", fileName: "SongMyung-Regular.ttf", megabytes: 2),
        GoogleFont(name: "함렛", folder: "hahmlet", fileName: "Hahmlet-VF.ttf", megabytes: 4),
    ]
}

/// 사용자 폰트(TTF/OTF) 관리. 앱 컨테이너의 Fonts 폴더에 복사하고 프로세스 범위로 등록한다.
@MainActor
@Observable
final class FontStore {
    static let shared = FontStore()
    static let allowedTypes: [UTType] = [
        UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf"),
        UTType(filenameExtension: "ttc"), .font,
    ].compactMap { $0 }

    private(set) var fonts: [CustomFont] = []
    private(set) var downloading: Set<String> = []
    private var cssCache: [String: String] = [:]

    nonisolated static var directory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Fonts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        reload()
    }

    /// 저장된 폰트 파일을 다시 읽어 등록한다.
    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var result: [CustomFont] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            result.append(contentsOf: Self.describe(file))
        }
        fonts = result
    }

    private static func describe(_ url: URL) -> [CustomFont] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        return descriptors.compactMap { d in
            guard let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { return nil }
            // 구글 폰트로 받은 파일은 목록에 보이던 한글 이름을 그대로 쓴다
            let display = GoogleFont.catalog.first { $0.fileName == url.lastPathComponent }?.name
                ?? (CTFontDescriptorCopyAttribute(d, kCTFontDisplayNameAttribute) as? String) ?? ps
            return CustomFont(postScriptName: ps, displayName: display, fileURL: url)
        }
    }

    enum ImportError: LocalizedError {
        case invalidFont(String)
        var errorDescription: String? {
            switch self {
            case .invalidFont(let name): "'\(name)'은(는) 사용할 수 있는 폰트 파일이 아닙니다."
            }
        }
    }

    /// fileImporter 로 받은 파일(보안 범위 URL)을 복사해 등록한다.
    @discardableResult
    func importFont(from source: URL) throws -> [CustomFont] {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let found = Self.describe(source)
        guard !found.isEmpty else { throw ImportError.invalidFont(source.lastPathComponent) }

        let dest = Self.directory.appending(path: source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            CTFontManagerUnregisterFontsForURL(dest as CFURL, .process, nil)
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        // 다시 추가한 폰트는 이전 삭제 기록을 지운다
        var tombs = UserDefaults.standard.dictionary(forKey: SyncedSettings.fontTombstonesKey) as? [String: Date] ?? [:]
        tombs[dest.lastPathComponent] = nil
        UserDefaults.standard.set(tombs, forKey: SyncedSettings.fontTombstonesKey)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        cssCache = [:]
        reload()
        return Self.describe(dest)
    }

    /// 구글 폰트를 내려받아 사용자 폰트 폴더에 저장한다. 이미 있으면 그대로 돌려준다.
    @discardableResult
    func download(_ gf: GoogleFont) async throws -> [CustomFont] {
        let dest = Self.directory.appending(path: gf.fileName)
        if FileManager.default.fileExists(atPath: dest.path) { return Self.describe(dest) }
        downloading.insert(gf.id)
        defer { downloading.remove(gf.id) }

        let (tmp, response) = try await URLSession.shared.download(from: gf.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let named = FileManager.default.temporaryDirectory.appending(path: gf.fileName)
        try? FileManager.default.removeItem(at: named)
        try FileManager.default.moveItem(at: tmp, to: named)
        defer { try? FileManager.default.removeItem(at: named) }
        return try importFont(from: named)
    }

    func isInstalled(_ gf: GoogleFont) -> Bool {
        FileManager.default.fileExists(atPath: Self.directory.appending(path: gf.fileName).path)
    }

    func delete(_ font: CustomFont) {
        CTFontManagerUnregisterFontsForURL(font.fileURL as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: font.fileURL)
        var tombs = UserDefaults.standard.dictionary(forKey: SyncedSettings.fontTombstonesKey) as? [String: Date] ?? [:]
        tombs[font.fileURL.lastPathComponent] = Date()
        UserDefaults.standard.set(tombs, forKey: SyncedSettings.fontTombstonesKey)
        cssCache = [:]
        reload()
        if ReaderSettings.shared.fontChoice == "custom:\(font.postScriptName)" {
            ReaderSettings.shared.fontChoice = "system"
        }
    }

    func font(named postScriptName: String) -> CustomFont? {
        fonts.first { $0.postScriptName == postScriptName }
    }

    /// WKWebView 에서 쓸 @font-face (base64 내장)
    func fontFaceCSS(for font: CustomFont) -> String {
        if let cached = cssCache[font.postScriptName] { return cached }
        guard let data = try? Data(contentsOf: font.fileURL) else { return "" }
        let ext = font.fileURL.pathExtension.lowercased()
        let format = ext == "otf" ? "opentype" : (ext == "ttc" ? "collection" : "truetype")
        let mime = ext == "otf" ? "font/otf" : (ext == "ttc" ? "font/collection" : "font/ttf")
        let css = """
        @font-face { font-family: 'ReaderCustom'; src: url(data:\(mime);base64,\(data.base64EncodedString())) format('\(format)'); }
        """
        cssCache[font.postScriptName] = css
        return css
    }
}
