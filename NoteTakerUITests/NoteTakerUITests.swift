import AppKit
import XCTest

final class NoteTakerUITests: XCTestCase {
    @MainActor
    func testLibraryFoldersActionsRenameFavoriteDeleteAndRestoreJourney() throws {
        let libraryRoot = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-uiTestingTransitionDelayMilliseconds",
            "400",
            "-libraryRoot",
            libraryRoot.path(percentEncoded: false),
            "-AppleLanguages",
            "(en)"
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["new-recording-button"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["new-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["done-recording-button"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["done-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["playback-detail"].waitForExistence(timeout: 5))

        app.buttons["Favorite"].click()
        app.descendants(matching: .any)["folder-favorites"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "detail-action-bar").firstMatch.waitForExistence(timeout: 5))

        app.buttons["Rename"].click()
        let titleField = app.descendants(matching: .any)["recording-title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.typeKey("a", modifierFlags: [.command])
        titleField.typeText("Renamed")
        app.typeKey(.return, modifierFlags: [])

        app.buttons["Delete"].click()
        app.descendants(matching: .any)["folder-recentlyDeleted"].click()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
        app.buttons["Restore"].click()
        app.descendants(matching: .any)["folder-all"].click()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testKeyboardShortcutsRespectSearchFocusAndTogglePausedPreview() throws {
        let libraryRoot = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-uiTestingTransitionDelayMilliseconds",
            "400",
            "-libraryRoot",
            libraryRoot.path(percentEncoded: false),
            "-AppleLanguages",
            "(en)"
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["new-recording-button"].waitForExistence(timeout: 5))

        let searchField = app.descendants(matching: .any)["sidebar-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: [.command])
        searchField.typeText("Meeting")
        XCTAssertEqual(searchField.value as? String, "Meeting")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()

        searchField.click()
        app.typeKey("n", modifierFlags: [.command])
        XCTAssertFalse(app.descendants(matching: .any)["recording-view"].waitForExistence(timeout: 1))
        app.descendants(matching: .any)["new-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["recording-view"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["done-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["playback-detail"].waitForExistence(timeout: 5))

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()

        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(app.descendants(matching: .any)["recording-view"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["pause-recording-button"].waitForExistence(timeout: 5))

        app.descendants(matching: .any)["pause-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["pause-preview-transport"].waitForExistence(timeout: 5))

        let playPauseButton = app.descendants(matching: .any)["play-pause-button"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
        XCTAssertEqual(playPauseButton.label, "Play")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(playPauseButton.label, "Pause Playback")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(playPauseButton.label, "Play")
    }

    @MainActor
    func testFirstLaunchRecordsFinishesSelectsAndPersistsAudio() throws {
        let libraryRoot = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-uiTestingTransitionDelayMilliseconds",
            "400",
            "-libraryRoot",
            libraryRoot.path(percentEncoded: false),
            "-AppleLanguages",
            "(en)"
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["new-recording-button"].waitForExistence(timeout: 5))

        app.descendants(matching: .any)["new-recording-button"].click()

        XCTAssertTrue(app.descendants(matching: .any)["recording-view"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["pause-recording-button"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["done-recording-button"].waitForExistence(timeout: 5))

        let newRecordingButton = app.descendants(matching: .any)["new-recording-button"]
        XCTAssertFalse(newRecordingButton.isEnabled)
        let imageData = try XCTUnwrap(newRecordingButton.screenshot().image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: imageData))
        var blueFocusPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent > 0.35,
                   color.blueComponent > color.redComponent + 0.15,
                   color.greenComponent > color.redComponent + 0.05 {
                    blueFocusPixels += 1
                }
            }
        }
        XCTAssertEqual(blueFocusPixels, 0, "The disabled red record control must not retain the extra blue focus halo.")

        app.descendants(matching: .any)["pause-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["pause-preview-transport"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["resume-recording-button"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["play-pause-button"].click()
        app.descendants(matching: .any)["forward-15-button"].click()
        app.descendants(matching: .any)["resume-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["pause-recording-button"].waitForExistence(timeout: 5))

        app.descendants(matching: .any)["pause-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["pause-preview-transport"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["resume-recording-button"].click()
        XCTAssertTrue(app.descendants(matching: .any)["pause-recording-button"].waitForExistence(timeout: 5))

        app.descendants(matching: .any)["done-recording-button"].click()

        XCTAssertTrue(app.descendants(matching: .any)["playback-detail"].waitForExistence(timeout: 5))
        let playPauseButton = app.descendants(matching: .any)["play-pause-button"]
        let timeLabel = app.descendants(matching: .any)["playback-time-label"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))
        XCTAssertTrue(timeLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(playPauseButton.label, "Play")
        XCTAssertEqual(timeLabel.label, "0:00 / 0:01")

        playPauseButton.click()
        XCTAssertEqual(playPauseButton.label, "Pause Playback")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(playPauseButton.label, "Play")

        app.descendants(matching: .any)["forward-15-button"].click()
        XCTAssertEqual(timeLabel.label, "0:01 / 0:01")

        app.descendants(matching: .any)["back-15-button"].click()
        XCTAssertEqual(timeLabel.label, "0:00 / 0:01")

        let recordingsRoot = libraryRoot.appending(path: "Recordings", directoryHint: .isDirectory)
        let recordingDirectories = try FileManager.default.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recordingDirectories.count, 1)

        let recordingDirectory = try XCTUnwrap(recordingDirectories.first)
        let rowID = "recording-row-\(recordingDirectory.lastPathComponent)"
        XCTAssertTrue(app.descendants(matching: .any)[rowID].waitForExistence(timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingDirectory.appending(path: "audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingDirectory.appending(path: "meta.json").path))
        let segmentsDirectory = recordingDirectory.appending(path: "segments", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: segmentsDirectory.path))
    }
}
