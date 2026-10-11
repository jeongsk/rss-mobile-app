import Testing
import Foundation
import CoreText
@testable import RSSReader

@MainActor
struct FontStoreTests {
    @Test func importsAndDeletesFontFile() throws {
        // 시스템 폰트 파일 하나를 사용자 폰트처럼 가져와 본다
        let ctFont = CTFontCreateWithName("Georgia" as CFString, 17, nil)
        let source = try #require(CTFontCopyAttribute(ctFont, kCTFontURLAttribute) as? URL)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "TestFont-\(UUID().uuidString).\(source.pathExtension)")
        try FileManager.default.copyItem(at: source, to: tmp)

        let store = FontStore.shared
        let added = try store.importFont(from: tmp)
        let font = try #require(added.first)
        #expect(store.font(named: font.postScriptName) != nil)
        let css = store.fontFaceCSS(for: font)
        #expect(css.contains("@font-face") && css.contains("base64,"))

        for f in added { store.delete(f) }
        #expect(store.font(named: font.postScriptName) == nil)
    }

    @Test func rejectsNonFont() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "notafont.ttf")
        try Data("hello".utf8).write(to: tmp)
        #expect(throws: (any Error).self) { try FontStore.shared.importFont(from: tmp) }
    }
}
