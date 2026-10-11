import XCTest

/// 원본 웹 → "이 페이지를 리더로 저장" → 리더 화면으로 돌아오는 흐름
final class CaptureUITests: XCTestCase {
    func testSavePageToReader() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-openFirst", "-web", "-markFailed"]
        app.launch()

        let save = app.buttons["이 페이지를 리더로 저장"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), "저장 버튼이 없음")
        // 페이지 로딩이 끝나야 버튼이 켜진다
        let deadline = Date().addingTimeInterval(30)
        while !save.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertTrue(save.isEnabled, "저장 버튼이 켜지지 않음")
        save.tap()

        XCTAssertTrue(app.staticTexts["본문을 저장했습니다. 이제 오프라인에서도 읽을 수 있어요."].waitForExistence(timeout: 20),
                      "저장 완료 안내가 없음")
        // 리더로 돌아오면 저장 버튼은 사라지고 본문이 보인다
        XCTAssertFalse(save.exists)
        let body = app.webViews.firstMatch.staticTexts.element(boundBy: 5)
        XCTAssertTrue(body.waitForExistence(timeout: 10), "리더 본문이 보이지 않음")
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("cap-saved.png"))
        }
    }
}
