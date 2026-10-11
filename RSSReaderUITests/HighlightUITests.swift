import XCTest

/// 실제 터치 흐름 점검: 텍스트 길게 누르기 → "하이라이트" 메뉴 → 하이라이트 탭 → 편집 시트
final class HighlightUITests: XCTestCase {
    let shots = ProcessInfo.processInfo.environment["SHOT_DIR"]

    func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shots { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }

    func testCreateHighlightFromSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-fixtureArticle", "-openFirst"]
        app.launch()

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30))
        sleep(3) // 본문 로딩 대기
        // 화면 중간(본문 영역)의 단어를 길게 눌러 선택
        let paragraph = web.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.6))
        paragraph.press(forDuration: 1.0)

        let menuItem = app.buttons["하이라이트"].exists ? app.buttons["하이라이트"] : app.menuItems["하이라이트"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "선택 메뉴에 하이라이트가 없음")
        save("m5-menu")
        menuItem.tap()
        sleep(1)
        save("m5-after-highlight")

        // 칠해진 하이라이트를 누르면 편집 시트가 열린다
        paragraph.tap()
        XCTAssertTrue(app.navigationBars["하이라이트"].waitForExistence(timeout: 5), "편집 시트가 열리지 않음")
        save("m5-editor")
    }
}
