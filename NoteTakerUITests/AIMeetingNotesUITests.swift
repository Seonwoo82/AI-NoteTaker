import AppKit
import XCTest

final class AIMeetingNotesUITests: XCTestCase {
    @MainActor
    func testAISettingsKeyAndModelSetupUsesExplicitOptIn() async throws {
        let app = XCUIApplication()
        let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.seonwoo.notetaker").map(\.processIdentifier))
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerAISetupUI-\(UUID())")
        app.launchArguments = ["-uiTesting", "-libraryRoot", root.path, "-AppleLanguages", "(en)"]
        app.launch()
        let target = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.seonwoo.notetaker")
            .first { !existingPIDs.contains($0.processIdentifier) })
        _ = try await NSWorkspace.shared.openApplication(at: XCTUnwrap(target.bundleURL), configuration: .init())
        let record = app.buttons.matching(NSPredicate(format: "label == %@", "New Recording")).firstMatch
        _ = try XCTUnwrap(record.waitForExistence(timeout: 8) ? record : nil)
        record.click()
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        _ = try XCTUnwrap(done.waitForExistence(timeout: 8) ? done : nil)
        done.click()
        let detail = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "AI Meeting Notes")).firstMatch
        _ = try XCTUnwrap(detail.waitForExistence(timeout: 8) ? detail : nil)
        detail.click()
        app.buttons["Open AI Settings"].click()
        let keyField = app.secureTextFields["ai-settings-key"]
        _ = try XCTUnwrap(keyField.waitForExistence(timeout: 8) ? keyField : nil)
        keyField.click()
        keyField.typeText("fixture-key")
        let save = app.buttons["ai-save-key"]
        XCTAssertEqual(save.label, "Save Key & Enable AI")
        save.click()
        XCTAssertEqual(keyField.value as? String, "")
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "ai-settings-setup"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testAutomaticMinutesRenderAndCopyMarkdown() async throws {
        let app = XCUIApplication()
        let existingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.seonwoo.notetaker")
            .map(\.processIdentifier))
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerAIUI-\(UUID())")
        app.launchArguments = ["-uiTesting", "-uiTestingAI", "-libraryRoot", root.path, "-AppleLanguages", "(en)"]
        app.launch()
        // XCTest can launch into a saved no-window state; use the normal reopen event.
        let target = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.seonwoo.notetaker")
            .first { !existingPIDs.contains($0.processIdentifier) })
        _ = try await NSWorkspace.shared.openApplication(at: XCTUnwrap(target.bundleURL), configuration: .init())
        let record = app.buttons.matching(NSPredicate(format: "label == %@", "New Recording")).firstMatch
        _ = try XCTUnwrap(record.waitForExistence(timeout: 8) ? record : nil)
        record.click()
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        _ = try XCTUnwrap(done.waitForExistence(timeout: 8) ? done : nil)
        done.click()
        let viewNotes = app.buttons["View AI Meeting Notes"]
        _ = try XCTUnwrap(viewNotes.waitForExistence(timeout: 12) ? viewNotes : nil)
        viewNotes.click()
        let document = app.descendants(matching: .any).matching(identifier: "ai-notes-document").firstMatch
        _ = try XCTUnwrap(document.waitForExistence(timeout: 8) ? document : nil)
        let screenshot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        screenshot.name = "ai-minutes-document"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let saved = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
            return saved
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(previousItems)
        }
        app.buttons["ai-copy-markdown"].click()
        let copied = pasteboard.string(forType: .string) ?? ""
        XCTAssertTrue(copied.hasPrefix("# "))
        XCTAssertTrue(copied.contains("## Action Items"))
        XCTAssertTrue(copied.contains("- [ ]"))

        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Transcript")).firstMatch.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "오늘 제품 회의", "오늘 제품 회의")).firstMatch.exists)
    }
}
