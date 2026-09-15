import AppKit
import AVFAudio
import XCTest

final class WaveformLifecycleUITests: XCTestCase {
    @MainActor
    func testFocusedDragUsesFrozenAbsoluteRangeAndResetsForNextDrag() throws {
        let root = try seedLongTimeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-libraryRoot", root.path, "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let main = app.windows["main"]
        if !main.waitForExistence(timeout: 2) {
            app.descendants(matching: .statusItem).firstMatch.click()
            app.buttons["menu-bar-open-window"].click()
        }
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        let primary = app.descendants(matching: .any).matching(identifier: "waveform-view").firstMatch
        let focused = app.descendants(matching: .any).matching(identifier: "overview-waveform").firstMatch
        let time = app.descendants(matching: .any).matching(identifier: "playback-time-label").firstMatch
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        primary.coordinate(withNormalizedOffset: CGVector(dx: 1_650.0 / 3_259.0, dy: 0.3)).click()
        // The full timeline has several seconds per pointer pixel. Measure its
        // actual landing point, then test the focused strip's precise deltas.
        expectTime(1_650, label: time, accuracy: 30)
        let initialTime = try XCTUnwrap(Self.seconds(from: time.label))

        focused.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.1,
                thenDragTo: focused.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        expectTime(initialTime + 75, label: time)

        focused.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                thenDragTo: focused.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        expectTime(initialTime, label: time)
        let attachment = XCTAttachment(screenshot: main.screenshot())
        attachment.name = "focused-waveform-after-two-drags"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func expectTime(_ seconds: Int, label: XCUIElement, accuracy: Int = 3) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard label.exists else { return false }
            guard let actual = Self.seconds(from: label.label) else { return false }
            return abs(actual - seconds) <= accuracy
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed,
            "The focused drag must seek to absolute time \(seconds); observed \(label.label).")
    }

    nonisolated private static func seconds(from label: String) -> Int? {
        let first = label.components(separatedBy: " / ").first ?? ""
        let fields = first.split(separator: ":").compactMap { Int($0) }
        guard fields.count == 2 else { return nil }
        return fields[0] * 60 + fields[1]
    }

    private func seedLongTimeline() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerFocusedWaveformUI-\(UUID())")
        let id = UUID().uuidString
        let folder = root.appending(path: "Recordings/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["id": id, "title": "Synthetic long timeline", "createdAt": "2026-09-15T00:00:00Z",
            "duration": 3_259, "mode": "micOnly", "audioVersion": 1]
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appending(path: "meta.json"))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for index in 0..<16_000 { channel[index] = Float(sin(Double(index) * 2 * .pi * 220 / 16_000)) * 0.4 }
        let audio = try AVAudioFile(forWriting: folder.appending(path: "audio.m4a"), settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
        ])
        try audio.write(from: buffer)
        return root
    }

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
