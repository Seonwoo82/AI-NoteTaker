import AppKit
import XCTest

final class WaveformLifecycleUITests: XCTestCase {
    @MainActor
    func testWaveformSurvivesFolderTabAndWindowRoundTrips() async throws {
        let app = XCUIApplication()
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerWaveformUI-\(UUID())")
        app.launchArguments = ["-uiTesting", "-libraryRoot", root.path, "-AppleLanguages", "(en)"]
        app.launch()
        let main = app.windows["main"]
        if !main.waitForExistence(timeout: 2) {
            app.descendants(matching: .statusItem).firstMatch.click()
            app.buttons["menu-bar-open-window"].click()
        }
        _ = try XCTUnwrap(main.waitForExistence(timeout: 5) ? main : nil)
        app.buttons.matching(NSPredicate(format: "label == %@", "New Recording")).firstMatch.click()
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        _ = try XCTUnwrap(done.waitForExistence(timeout: 5) ? done : nil)
        done.click()
        try await requireDrawnWaveform(app)

        app.buttons["folder-favorites"].click()
        _ = try XCTUnwrap(app.descendants(matching: .any)["empty-detail"].waitForExistence(timeout: 5) ? true : nil)
        app.buttons["folder-all"].click()
        try await requireDrawnWaveform(app)

        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "AI Meeting Notes")).firstMatch.click()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Audio")).firstMatch.click()
        try await requireDrawnWaveform(app)

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        _ = try XCTUnwrap(settings.waitForExistence(timeout: 5) ? settings : nil)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        try await requireDrawnWaveform(app)

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        app.activate()
        try await requireDrawnWaveform(app)

        main.buttons[XCUIIdentifierCloseWindow].click()
        app.descendants(matching: .statusItem).firstMatch.click()
        app.buttons["menu-bar-open-window"].click()
        try await requireDrawnWaveform(app)
        let attachment = XCTAttachment(screenshot: main.screenshot())
        attachment.name = "waveform-after-navigation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func requireDrawnWaveform(_ app: XCUIApplication) async throws {
        let waveform = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Waveform")).firstMatch
        _ = try XCTUnwrap(waveform.waitForExistence(timeout: 5) ? waveform : nil)
        // The real Canvas draws a blue playhead only when it
        // has waveform samples. Time labels alone must not satisfy this test.
        var bluePixels = 0
        for _ in 0..<20 {
            let data = try XCTUnwrap(waveform.screenshot().image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            bluePixels = 0
            let drawingHeight = max(1, bitmap.pixelsHigh - 30)
            for x in 0..<bitmap.pixelsWide {
                var columnPixels = 0
                for y in 0..<drawingHeight {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.blueComponent > 0.4 && color.blueComponent > color.redComponent + 0.15 {
                        columnPixels += 1
                    }
                }
                bluePixels = max(bluePixels, columnPixels)
            }
            if bluePixels > drawingHeight / 2 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let attachment = XCTAttachment(screenshot: app.windows["main"].screenshot())
        attachment.name = "missing-waveform"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Waveform Canvas is blank after navigation (\(bluePixels) playhead pixels).")
        throw NSError(domain: "WaveformLifecycleUITests", code: 1)
    }
}
