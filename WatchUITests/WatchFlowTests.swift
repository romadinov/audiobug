import XCTest

/// Runs on a Watch simulator whose Documents/Books holds "Old Man's War.m4b".
final class WatchFlowTests: XCTestCase {
    private func seconds(_ clock: String) -> Int {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * Int(pow(60.0, Double($1.offset))) }
    }

    func testWatchPlayer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let row = app.buttons["book.Old Man's War"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: playPause)], timeout: 20)
        let t0 = seconds(app.staticTexts["player.elapsed"].label)
        sleep(3)
        XCTAssertGreaterThan(seconds(app.staticTexts["player.elapsed"].label), t0)

        app.buttons["player.speed"].tap()
        let rate = app.cells["1.25×"]
        XCTAssertTrue(rate.waitForExistence(timeout: 5))
        rate.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '1.25×'"), evaluatedWith: app.buttons["player.speed"])], timeout: 5)

        app.buttons["player.more"].tap()
        XCTAssertTrue(app.staticTexts["Audio output"].waitForExistence(timeout: 5) || app.staticTexts["AUDIO OUTPUT"].exists)
        add({ let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "more"; a.lifetime = .keepAlways; return a }())
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sleep timer' OR label CONTAINS 'SLEEP TIMER'")).firstMatch.exists)
    }
}
