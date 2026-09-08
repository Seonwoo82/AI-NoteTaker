import XCTest

final class NoteTakerUITests: XCTestCase {
    #if os(iOS)
    @MainActor
    func testDisabledConnectionCanSaveToKeychain() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let endpoint = app.textFields["sync-endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap()
        endpoint.typeText("https://sync.example.com")
        let token = app.secureTextFields["sync-token"]
        token.tap()
        token.typeText("isolated-ui-test-key-not-for-network")
        let hideKeyboard = app.buttons["hide-sync-keyboard"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        app.buttons["save-sync-settings"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Connection Settings Saved"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Connection Error"].exists)
    }
    #endif

    @MainActor
    func testLaunchShowsSplitViewShell() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        #if os(macOS)
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 5))
        #endif
        XCTAssertTrue(app.descendants(matching: .any)["folders-sidebar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["new-recording-button"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings-button"].exists)
        #if os(macOS)
        XCTAssertTrue(app.descendants(matching: .any)["empty-detail"].waitForExistence(timeout: 5))
        #endif
    }

    @MainActor
    func testSettingsRejectsInsecureServerBeforeConnecting() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let endpoint = app.textFields["sync-endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap()
        endpoint.typeText("http://example.com")
        let token = app.secureTextFields["sync-token"]
        token.tap()
        token.typeText("ui-test-key-never-used-for-network")
        #if os(iOS)
        let hideKeyboard = app.buttons["hide-sync-keyboard"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        #endif
        #if os(macOS)
        app.switches["sync-enabled"].tap()
        #else
        let enableSync = app.switches["sync-enabled"]
        enableSync.switches.firstMatch.tap()
        XCTAssertEqual(enableSync.value as? String, "1")
        #endif
        app.buttons["save-sync-settings"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Connection validation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'HTTPS' OR value CONTAINS[c] 'HTTPS'")).firstMatch.waitForExistence(timeout: 5))
    }
}
