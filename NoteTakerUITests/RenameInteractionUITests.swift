import XCTest

final class RenameInteractionUITests: XCTestCase {
    @MainActor
    func testSidebarDoubleClickEditsInsideRowAndCanSaveOrCancel() async throws {
        let fixture = try await launchAppWithOneRecording()
        let app = fixture.app
        let row = app.descendants(matching: .any)["recording-row-\(fixture.recordingID)"]
        _ = try XCTUnwrap(row.waitForExistence(timeout: 5) ? row : nil)
        let originalRowFrame = row.frame

        app.textFields.firstMatch.click()
        row.doubleClick()

        let sidebarTitleField = app.textFields.matching(titleFieldPredicate(identifier: "sidebar-recording-title-field")).firstMatch
        _ = try XCTUnwrap(sidebarTitleField.waitForExistence(timeout: 5) ? sidebarTitleField : nil)
        XCTAssertTrue(
            originalRowFrame.insetBy(dx: -8, dy: -6).contains(sidebarTitleField.frame),
            "Sidebar title editor must stay inside the original recording row. Field frame: \(sidebarTitleField.frame), row frame: \(originalRowFrame)"
        )
        attachMainWindowScreenshot(app, named: "sidebar-inline-rename")
        app.menuBars.menuBarItems["File"].click()
        let newRecordingMenuItem = app.menuItems["New Recording"].firstMatch
        _ = try XCTUnwrap(newRecordingMenuItem.waitForExistence(timeout: 3) ? newRecordingMenuItem : nil)
        XCTAssertFalse(
            newRecordingMenuItem.isEnabled,
            "New Recording must stay disabled while the sidebar title editor is active, even after search focus hands off."
        )
        app.typeKey(.escape, modifierFlags: [])

        try await replaceText(in: sidebarTitleField, with: "sidebar saved title", app: app)
        app.typeKey(.return, modifierFlags: [])
        try waitForTitle("sidebar saved title", in: app, row: row)

        row.doubleClick()
        let cancelField = app.textFields.matching(titleFieldPredicate(identifier: "sidebar-recording-title-field")).firstMatch
        _ = try XCTUnwrap(cancelField.waitForExistence(timeout: 5) ? cancelField : nil)
        try await replaceText(in: cancelField, with: "sidebar cancelled title", app: app)
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(cancelField.waitForExistence(timeout: 1), "Escape should close the inline sidebar editor.")
        try waitForTitle("sidebar saved title", in: app, row: row)
        XCTAssertFalse(row.label.contains("sidebar cancelled title"))
    }

    @MainActor
    func testDetailRenameCommitsWhenBlankDetailAreaIsClicked() async throws {
        let fixture = try await launchAppWithOneRecording()
        let app = fixture.app
        let row = app.descendants(matching: .any)["recording-row-\(fixture.recordingID)"]
        _ = try XCTUnwrap(row.waitForExistence(timeout: 5) ? row : nil)

        app.buttons.matching(NSPredicate(format: "label == %@", "Rename")).firstMatch.click()
        let titleField = app.textFields.matching(titleFieldPredicate(identifier: "recording-title-field")).firstMatch
        _ = try XCTUnwrap(titleField.waitForExistence(timeout: 5) ? titleField : nil)
        try await replaceText(in: titleField, with: "detail blank click title", app: app)

        let main = app.windows["main"]
        _ = try XCTUnwrap(main.waitForExistence(timeout: 5) ? main : nil)
        main.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.32)).click()

        XCTAssertFalse(titleField.waitForExistence(timeout: 2), "Clicking blank detail space should exit title editing.")
        try waitForTitle("detail blank click title", in: app, row: row)
        attachMainWindowScreenshot(app, named: "detail-rename-finished")
    }

    @MainActor
    func testFavoriteButtonCommitsRenameWithoutSwallowingClickAndAllowsRepeatedEdit() async throws {
        let fixture = try await launchAppWithOneRecording()
        let app = fixture.app
        let row = app.descendants(matching: .any)["recording-row-\(fixture.recordingID)"]
        _ = try XCTUnwrap(row.waitForExistence(timeout: 5) ? row : nil)

        app.buttons.matching(NSPredicate(format: "label == %@", "Rename")).firstMatch.click()
        let titleField = app.textFields.matching(titleFieldPredicate(identifier: "recording-title-field")).firstMatch
        _ = try XCTUnwrap(titleField.waitForExistence(timeout: 5) ? titleField : nil)
        try await replaceText(in: titleField, with: "favorite commits title", app: app)

        app.buttons.matching(NSPredicate(format: "label == %@", "Favorite")).firstMatch.click()

        XCTAssertFalse(titleField.waitForExistence(timeout: 2), "Clicking Favorite should commit and leave title editing.")
        try waitForTitle("favorite commits title", in: app, row: row)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label == %@", "Remove Favorite")).firstMatch.waitForExistence(timeout: 5),
            "The Favorite click must still toggle favorite after committing the rename."
        )

        app.buttons.matching(NSPredicate(format: "label == %@", "Rename")).firstMatch.click()
        let repeatedField = app.textFields.matching(titleFieldPredicate(identifier: "recording-title-field")).firstMatch
        _ = try XCTUnwrap(repeatedField.waitForExistence(timeout: 5) ? repeatedField : nil)
        try await replaceText(in: repeatedField, with: "favorite repeated title", app: app)
        app.typeKey(.return, modifierFlags: [])

        try waitForTitle("favorite repeated title", in: app, row: row)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Remove Favorite")).firstMatch.exists)
    }

    @MainActor
    private func launchAppWithOneRecording() async throws -> (app: XCUIApplication, recordingID: String) {
        let app = XCUIApplication()
        let libraryRoot = FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerRenameUI-\(UUID().uuidString)", directoryHint: .isDirectory)
        app.launchArguments = ["-uiTesting", "-libraryRoot", libraryRoot.path, "-AppleLanguages", "(en)"]
        app.launch()
        try reopenMainWindowIfNeeded(app)

        app.buttons.matching(NSPredicate(format: "label == %@", "New Recording")).firstMatch.click()
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        _ = try XCTUnwrap(done.waitForExistence(timeout: 5) ? done : nil)
        done.click()
        XCTAssertTrue(app.descendants(matching: .any)["playback-detail"].waitForExistence(timeout: 5))

        let recordingID = try waitForOnlyRecordingID(in: libraryRoot)
        return (app, recordingID)
    }

    @MainActor
    private func reopenMainWindowIfNeeded(_ app: XCUIApplication) throws {
        let main = app.windows["main"]
        if !main.waitForExistence(timeout: 2) {
            app.descendants(matching: .statusItem).firstMatch.click()
            app.buttons["menu-bar-open-window"].click()
        }
        _ = try XCTUnwrap(main.waitForExistence(timeout: 5) ? main : nil)
    }

    private func waitForOnlyRecordingID(in libraryRoot: URL) throws -> String {
        let recordingsRoot = libraryRoot.appending(path: "Recordings", directoryHint: .isDirectory)
        var directories: [URL] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            directories = (try? FileManager.default.contentsOfDirectory(
                at: recordingsRoot,
                includingPropertiesForKeys: nil
            )) ?? []
            if directories.count == 1 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(directories.count, 1)
        return try XCTUnwrap(directories.first?.lastPathComponent)
    }

    private func titleFieldPredicate(identifier: String) -> NSPredicate {
        NSPredicate(format: "identifier == %@ OR label == %@ OR (value != nil AND value != '')", identifier, "Title")
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) async throws {
        field.click()
        _ = try XCTUnwrap(field.exists ? field : nil, "Title field disappeared immediately after click.")
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Select All"].firstMatch.click()
        field.typeText(text)

        let valueMatches = NSPredicate(format: "value == %@", text)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: valueMatches, object: field)], timeout: 2)
        let currentValue = try XCTUnwrap(field.value as? String, "Title field value was not readable after typing.")
        guard currentValue == text else {
            XCTFail("Expected title field value '\(text)' after typing, got '\(currentValue)'.")
            throw NSError(domain: "RenameInteractionUITests", code: 1)
        }
    }

    @MainActor
    private func attachMainWindowScreenshot(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func waitForTitle(_ title: String, in app: XCUIApplication, row: XCUIElement) throws {
        let deadline = Date().addingTimeInterval(5)
        let window = app.windows["main"].firstMatch
        _ = try XCTUnwrap(window.waitForExistence(timeout: 5) ? window : nil)
        let rightHalfMinX = window.frame.midX

        var detailTitleFound = false
        while Date() < deadline {
            let detailTitle = app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                title,
                title
            )).allElementsBoundByIndex.first { element in
                element.exists && element.frame.midX > rightHalfMinX
            }
            detailTitleFound = detailTitle != nil
            if detailTitleFound && row.label.contains(title) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(detailTitleFound, "Detail title should show '\(title)' in the right half of the window.")
        XCTFail("Sidebar row should show '\(title)'. Last row label: \(row.label)")
    }
}
