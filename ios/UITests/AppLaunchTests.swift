import XCTest

/// Starts the app with a song and checks it comes up and stays running (the Live Activity starts with it).
final class AppLaunchTests: XCTestCase {
    func testLaunchAndPlay() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-wbPlay", "blinding lights the weeknd"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(12)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
