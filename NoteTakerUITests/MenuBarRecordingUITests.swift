import AppKit
import AVFAudio
import XCTest

final class MenuBarRecordingUITests: XCTestCase {
    @MainActor
    func testMenuBarRecordsWhileMainWindowIsClosedAndSharesSession() async throws {
        continueAfterFailure = false
        let libraryRoot = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerMenuBarTests-\(UUID())")
        let (app, running) = try await launchApp(libraryRoot: libraryRoot)
        let mainWindow = app.windows["main"]
        let statusItem = app.descendants(matching: .statusItem).firstMatch
        _ = try XCTUnwrap(statusItem.waitForExistence(timeout: 5) ? statusItem : nil, "NoteTaker must be available in the menu bar.")

        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 1))
        statusItem.click()
        let start = app.buttons["menu-bar-start"]
        _ = try XCTUnwrap(start.waitForExistence(timeout: 5) ? start : nil, app.debugDescription)
        try savePanelSnapshot(app, name: "menu-bar-ready")
        start.click()
        let pause = app.buttons["menu-bar-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        try savePanelSnapshot(app, name: "menu-bar-recording")
        XCTAssertFalse(mainWindow.exists, "Quick recording must not force the main window open.")
        pause.click()
        let resume = app.buttons["menu-bar-resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        try savePanelSnapshot(app, name: "menu-bar-paused")
        resume.click()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))

        app.buttons["menu-bar-open-window"].click()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["recording-view"].exists)
        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        statusItem.click()
        let finish = app.buttons["menu-bar-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))

        let recordings = try FileManager.default.contentsOfDirectory(
            at: libraryRoot.appending(path: "Recordings"), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recordings.count, 1)
        let recording = try XCTUnwrap(recordings.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.appending(path: "audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.appending(path: "meta.json").path))
        let audio = try AVAudioFile(forReading: recording.appending(path: "audio.m4a"))
        XCTAssertGreaterThan(audio.length, 0)
        XCTAssertFalse(running.isTerminated)
        app.buttons["menu-bar-open-window"].click()
        XCTAssertTrue(app.descendants(matching: .any)["playback-detail"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMenuBarShowsFailedStartAndCanRetryWithoutMainWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerMenuErrorTests-\(UUID())")
        // A regular file where the library directory should be makes start fail.
        try Data("blocking fixture".utf8).write(to: root)
        let (app, _) = try await launchApp(libraryRoot: root)
        app.windows["main"].buttons[XCUIIdentifierCloseWindow].click()
        app.descendants(matching: .statusItem).firstMatch.click()
        let start = app.buttons["menu-bar-start"]
        _ = try XCTUnwrap(start.waitForExistence(timeout: 5) ? start : nil)
        start.click()
        let error = app.staticTexts["menu-bar-error"]
        _ = try XCTUnwrap(error.waitForExistence(timeout: 5) ? error : nil)
        XCTAssertTrue(start.isEnabled)
        try savePanelSnapshot(app, name: "menu-bar-error")

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        start.click()
        let finish = app.buttons["menu-bar-finish"]
        _ = try XCTUnwrap(finish.waitForExistence(timeout: 5) ? finish : nil)
        XCTAssertFalse(error.exists)
        finish.click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchApp(libraryRoot: URL) async throws -> (XCUIApplication, NSRunningApplication) {
        let existingPIDs = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.seonwoo.notetaker"
        ).map(\.processIdentifier))
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-libraryRoot", libraryRoot.path, "-AppleLanguages", "(en)"]
        app.launch()
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.seonwoo.notetaker"
        ).first { !existingPIDs.contains($0.processIdentifier) })
        let opened = try await NSWorkspace.shared.openApplication(
            at: XCTUnwrap(running.bundleURL), configuration: NSWorkspace.OpenConfiguration()
        )
        XCTAssertEqual(opened.processIdentifier, running.processIdentifier,
                       "Close other NoteTaker instances before UI testing so reopen targets the test app.")
        _ = try XCTUnwrap(app.windows["main"].waitForExistence(timeout: 5) ? running : nil)
        return (app, running)
    }

    @MainActor
    private func savePanelSnapshot(_ app: XCUIApplication, name: String) throws {
        let panel = app.descendants(matching: .any)["menu-bar-panel"]
        _ = try XCTUnwrap(panel.waitForExistence(timeout: 5) ? panel : nil)
        let attachment = XCTAttachment(screenshot: panel.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
