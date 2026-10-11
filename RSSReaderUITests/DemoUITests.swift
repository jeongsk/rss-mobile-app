import XCTest

/// README 데모 영상용 흐름: 사이트 주소로 피드 추가 → 피드 열기 → 글 읽기 (네트워크 필요)
/// 녹화: xcrun simctl io <기기> recordVideo demo.mp4 를 켠 채로
///       TEST_RUNNER_DEMO_VIDEO=1 ./test.sh -only-testing:RSSReaderUITests/DemoUITests
final class DemoUITests: XCTestCase {
    func testAddHackerNewsAndRead() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DEMO_VIDEO"] == nil, "데모 녹화 때만 실행")
        let app = XCUIApplication()
        app.launchArguments = ["-sidebar"]
        app.launch()
        sleep(2)

        app.navigationBars.buttons.matching(NSPredicate(format: "label == '추가' OR label == 'Add'")).firstMatch.tap()
        app.buttons["피드 추가"].tap()
        let field = app.textFields["사이트 또는 피드 주소"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        for ch in "https://news.ycombinator.com/" { field.typeText(String(ch)) }
        sleep(1)
        app.navigationBars["피드 추가"].buttons["추가"].tap()

        let feed = app.staticTexts["Hacker News"].firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 30), "피드가 추가되지 않음")
        sleep(2)
        feed.tap()

        let firstArticle = app.cells.firstMatch
        XCTAssertTrue(firstArticle.waitForExistence(timeout: 30))
        sleep(3) // 목록과 썸네일 표시
        firstArticle.tap()

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30))
        sleep(5) // 원문에서 본문 추출
        for _ in 0..<3 {
            web.swipeUp(velocity: .slow)
            sleep(1)
        }
        sleep(2)
    }
}
