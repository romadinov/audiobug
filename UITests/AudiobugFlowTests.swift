import XCTest

/// End-to-end flows on an iPhone simulator whose Documents/Books already holds "Old Man's War.m4b"
/// (see scripts/run-simulators.sh). Positions persist in the app container between launches.
final class AudiobugFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func seconds(_ clock: String) -> Int {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * Int(pow(60.0, Double($1.offset))) }
    }

    private func elapsed(_ app: XCUIApplication) -> Int {
        seconds(app.staticTexts["player.elapsed"].label)
    }

    private func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
    }

    private func openBook(_ app: XCUIApplication, _ title: String) {
        let row = app.buttons["book.\(title)"]
        waitFor(row)
        row.tap()
        let playPause = app.buttons["player.playPause"]
        waitFor(playPause)
        // Autoplay: becomes "Pause" once the book is loaded and playing.
        let playing = NSPredicate(format: "label == 'Pause'")
        let exp = expectation(for: playing, evaluatedWith: playPause)
        wait(for: [exp], timeout: 15)
    }

    func testPlayerFlow() throws {
        let app = XCUIApplication()
        app.launch()
        openBook(app, "Old Man's War")

        // Playing: elapsed time grows.
        let t0 = elapsed(app)
        sleep(3)
        let t1 = elapsed(app)
        XCTAssertGreaterThan(t1, t0, "elapsed should advance while playing")
        XCTAssertTrue(app.staticTexts["player.remaining"].label.contains("left at"), app.staticTexts["player.remaining"].label)

        // Chapters: jump to the second chapter.
        let chapterButton = app.buttons["player.chapter"]
        waitFor(chapterButton)
        let firstChapter = chapterButton.label
        chapterButton.tap()
        // Jump to a chapter other than the current one (the saved position may already be in chapter 2).
        var second = app.descendants(matching: .any).matching(identifier: "chapter.1").firstMatch
        waitFor(second)
        if firstChapter == second.label || second.label.hasPrefix(firstChapter) {
            second = app.descendants(matching: .any).matching(identifier: "chapter.0").firstMatch
        }
        let secondTitle = second.label
        second.tap()
        let changed = expectation(for: NSPredicate(format: "label != %@", firstChapter), evaluatedWith: chapterButton)
        wait(for: [changed], timeout: 5)
        XCTAssertTrue(secondTitle.hasPrefix(chapterButton.label) || chapterButton.label.contains(secondTitle.prefix(10)),
                      "chapter button '\(chapterButton.label)' vs '\(secondTitle)'")

        // Speed 1.5×.
        app.buttons["player.speed"].tap()
        let rate = app.descendants(matching: .any).matching(NSPredicate(format: "label == '1.5×'")).firstMatch
        waitFor(rate)
        rate.tap()
        XCTAssertTrue(app.buttons["player.speed"].label.contains("1.5×"), app.buttons["player.speed"].label)
        XCTAssertTrue(app.staticTexts["player.remaining"].label.contains("left at 1.5×"), app.staticTexts["player.remaining"].label)

        // Skips: +30 s then −15 s (playing at 1.5×, so allow drift).
        let before = elapsed(app)
        app.buttons["player.skipForward"].tap()
        sleep(1)
        let afterForward = elapsed(app)
        XCTAssertTrue((28...36).contains(afterForward - before), "skip forward moved \(afterForward - before) s")
        app.buttons["player.skipBack"].tap()
        sleep(1)
        let afterBack = elapsed(app)
        XCTAssertTrue((-20 ... -10).contains(afterBack - afterForward), "skip back moved \(afterBack - afterForward) s")

        // Sleep timer: 15 minutes → countdown.
        app.buttons["player.sleep"].tap()
        let fifteen = app.descendants(matching: .any).matching(NSPredicate(format: "label == '15 minutes'")).firstMatch
        waitFor(fifteen)
        fifteen.tap()
        let countdown = expectation(for: NSPredicate(format: "label MATCHES '.*1[45]:[0-5][0-9].*'"), evaluatedWith: app.buttons["player.sleep"])
        wait(for: [countdown], timeout: 5)

        // Output picker opens (system UI) and can be dismissed.
        let output = app.otherElements["player.output"].exists ? app.otherElements["player.output"] : app.buttons["player.output"]
        XCTAssertTrue(output.exists, "output control")
        output.tap()
        sleep(2)
        XCTAssertTrue(app.state == .runningForeground)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "route-picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()   // dismiss the sheet
        sleep(1)

        // Pause and go back: the row shows progress and the mini player appears.
        app.buttons["player.playPause"].tap()
        let pausedAt = elapsed(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons["book.Old Man's War"]
        waitFor(row)
        XCTAssertTrue(row.label.contains("left"), row.label)
        let mini = app.buttons["mini.playPause"]
        waitFor(mini)
        XCTAssertEqual(mini.label, "Play")
        mini.tap()
        XCTAssertEqual(mini.label, "Pause")
        mini.tap()

        // Relaunch: the position is remembered.
        app.terminate()
        app.launch()
        openBook(app, "Old Man's War")
        app.buttons["player.playPause"].tap()
        let resumed = elapsed(app)
        XCTAssertTrue(abs(resumed - pausedAt) <= 8, "resumed at \(resumed), paused at \(pausedAt)")
        XCTAssertTrue(app.buttons["player.speed"].label.contains("1.5×"), "speed remembered per book")
    }

    /// Needs a paired Watch simulator with the Watch app installed and running.
    func testSendToWatch() throws {
        let app = XCUIApplication()
        app.launch()
        let row = app.buttons["book.Джентльмен с Медвежьей речки"]
        waitFor(row)
        row.press(forDuration: 1.2)
        let send = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Send to Apple Watch'")).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "No 'Send to Apple Watch' — is the Watch app installed on the paired Watch?")
        send.tap()
        let transfer = app.otherElements["row.transfer"].firstMatch
        XCTAssertTrue(transfer.waitForExistence(timeout: 10) || app.images["row.onWatch"].exists, "transfer indicator")
        let done = app.images["row.onWatch"]
        XCTAssertTrue(done.waitForExistence(timeout: 240), "transfer did not finish")
    }

    /// Switches the Wi-Fi upload server on from the ⋯ menu, reads its address and talks to it over HTTP.
    func testWiFiUpload() throws {
        let app = XCUIApplication()
        app.launch()
        let more = app.buttons["More"]
        waitFor(more)
        more.tap()
        let item = app.buttons["Wi-Fi Upload…"]
        waitFor(item, 5)
        item.tap()
        let toggle = app.switches["upload.toggle"]
        waitFor(toggle)
        let knob = toggle.switches.firstMatch   // SwiftUI Toggle: the tap must land on the inner switch
        (knob.exists ? knob : toggle).tap()
        let address = app.staticTexts["upload.url"].firstMatch
        waitFor(address, 10)
        let base = address.label
        XCTAssertTrue(base.hasPrefix("http://"), base)

        // The page is served, a non-audiobook upload is refused and nothing is left behind.
        let page = request(base + "/", method: "GET", body: nil)
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.text.contains("<title>Audiobug</title>"))
        let refused = request(base + "/upload/notes.txt", method: "PUT", body: Data("hello".utf8))
        XCTAssertEqual(refused.status, 415, refused.text)
        let library = request(base + "/api/library", method: "GET", body: nil)
        XCTAssertEqual(library.status, 200)
        XCTAssertTrue(library.text.contains("\"books\""), library.text)

        app.buttons["Done"].tap()
        let banner = app.buttons["upload.banner"]
        waitFor(banner, 5)
        app.buttons["Stop"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
        XCTAssertEqual(request(base + "/", method: "GET", body: nil).status, 0, "server still answering after Stop")
    }

    private func request(_ url: String, method: String, body: Data?) -> (status: Int, text: String) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 10
        var result = (status: 0, text: "")
        let done = expectation(description: url)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        return result
    }
}
