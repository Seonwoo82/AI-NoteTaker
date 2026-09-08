import AppKit
import XCTest

final class WindowLifecycleUITests: XCTestCase {
    @MainActor
    func testClosingAndReopeningWindowKeepsSameProcess() async throws {
        let (app, runningApp) = try await launchIsolatedApp()

        for _ in 0..<2 {
            try await closeAndReopen(app, runningApp: runningApp)
        }

        app.menuBars.menuBarItems["AI-NoteTaker"].click()
        app.menuBars.menuItems["Quit AI-NoteTaker"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Explicit Quit must still terminate the app.")
    }

    @MainActor
    func testRecordingSurvivesClosingAndReopeningWindow() async throws {
        let (app, runningApp) = try await launchIsolatedApp()
        let recordButton = app.buttons.matching(NSPredicate(format: "label == %@", "New Recording")).firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5))
        recordButton.click()
        let doneButton = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))

        try await closeAndReopen(app, runningApp: runningApp)

        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Reopening must preserve the active recording.")
        doneButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["playback-detail"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchIsolatedApp() async throws -> (XCUIApplication, NSRunningApplication) {
        let existingPIDs = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.seonwoo.notetaker"
        ).map(\.processIdentifier))
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-libraryRoot",
            FileManager.default.temporaryDirectory.appending(path: "NoteTakerWindowTests-\(UUID())").path,
            "-AppleLanguages", "(en)"
        ]
        app.launch()
        let runningApp = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.seonwoo.notetaker"
        ).first { !existingPIDs.contains($0.processIdentifier) })
        // XCTest's process launch can restore a previous no-window state.
        // Send the normal LaunchServices open event before exercising Close.
        _ = try await NSWorkspace.shared.openApplication(
            at: XCTUnwrap(runningApp.bundleURL),
            configuration: NSWorkspace.OpenConfiguration()
        )
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return (app, runningApp)
    }

    @MainActor
    private func closeAndReopen(_ app: XCUIApplication, runningApp: NSRunningApplication) async throws {
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 2), "Closing the red button must keep NoteTaker running in the Dock.")
        _ = try XCTUnwrap(runningApp.isTerminated ? nil : runningApp, "Close terminated the application.")
        XCTAssertEqual(app.windows.count, 0)

        // LaunchServices sends the same reopen AppleEvent as a Dock click.
        let reopenedApp = try await NSWorkspace.shared.openApplication(
            at: XCTUnwrap(runningApp.bundleURL),
            configuration: NSWorkspace.OpenConfiguration()
        )
        XCTAssertEqual(reopenedApp.processIdentifier, runningApp.processIdentifier)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
    }
}
