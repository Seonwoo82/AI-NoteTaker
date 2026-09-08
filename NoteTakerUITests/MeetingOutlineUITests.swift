import Foundation
import XCTest

final class MeetingOutlineUITests: XCTestCase {
    @MainActor
    func testOutlineUsesReadableRowsAndNavigatesToLaterSections() throws {
        let root = try seedMeeting()
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-libraryRoot", root.path, "-AppleLanguages", "(en)"]
        app.launch()
        let main = app.windows["main"]
        if !main.waitForExistence(timeout: 2) {
            app.descendants(matching: .statusItem).firstMatch.click()
            app.buttons["menu-bar-open-window"].click()
        }
        _ = try XCTUnwrap(main.waitForExistence(timeout: 5) ? main : nil)
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "AI Meeting Notes")).firstMatch.click()

        let toggle = app.buttons["ai-outline-toggle"]
        _ = try XCTUnwrap(toggle.waitForExistence(timeout: 5) ? toggle : nil,
                          "Outline must be a collapsible navigation list, not static capsules.")
        let first = app.buttons.matching(NSPredicate(format: "label == %@", "개요")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label == %@", "제품 설계 변경 사항과 사용자 피드백을 반영한 다음 단계 검토")).firstMatch
        _ = try XCTUnwrap(first.waitForExistence(timeout: 3) ? first : nil)
        _ = try XCTUnwrap(second.waitForExistence(timeout: 3) ? second : nil)
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(second.frame.minY, first.frame.maxY)
        XCTAssertGreaterThan(first.frame.width, 200)
        saveScreenshot(main, name: "outline-preview")

        toggle.click()
        XCTAssertFalse(first.waitForExistence(timeout: 1))
        toggle.click()
        _ = try XCTUnwrap(first.waitForExistence(timeout: 3) ? first : nil)
        let all = app.buttons["ai-outline-show-all"]
        _ = try XCTUnwrap(all.waitForExistence(timeout: 3) ? all : nil)
        all.click()

        let destination = app.buttons.matching(NSPredicate(format: "label == %@", "최종 결정 및 다음 회의")).firstMatch
        _ = try XCTUnwrap(destination.waitForExistence(timeout: 3) ? destination : nil)
        destination.click()
        let heading = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "최종 결정 및 다음 회의", "최종 결정 및 다음 회의")).firstMatch
        _ = try XCTUnwrap(heading.waitForExistence(timeout: 3) ? heading : nil)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            heading.exists && main.frame.contains(heading.frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "Selecting the eighth section must scroll its real body heading into view.")
        saveScreenshot(main, name: "outline-navigated")
    }

    @MainActor
    private func saveScreenshot(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func seedMeeting() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "NoteTakerOutlineUI-\(UUID())")
        let id = UUID().uuidString
        let folder = root.appending(path: "Recordings/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = "2026-09-08T00:00:00Z"
        let metadata: [String: Any] = ["id": id, "title": "목차 화면 테스트", "createdAt": date,
            "duration": 900, "mode": "micOnly", "audioVersion": 1]
        let titles = ["개요", "제품 설계 변경 사항과 사용자 피드백을 반영한 다음 단계 검토", "진행 일정", "검토 사항",
                      "담당 업무", "출시 준비", "검토 사항", "최종 결정 및 다음 회의"]
        let paragraph = String(repeating: "이번 회의에서는 진행 상황을 확인하고 다음 단계의 준비 사항을 논의했습니다. 확인되지 않은 일정과 담당자는 확정하지 않고 후속 검토하기로 했습니다. ", count: 6)
        let source = "# 제품 회의 보고서\n\n회의에서 논의한 내용을 정리합니다.\n\n" + titles.enumerated().map {
            "## \($0.element)\n\nSECTION_\($0.offset + 1)_BODY \(paragraph)"
        }.joined(separator: "\n\n")
        let notes: [String: Any] = ["schemaVersion": 1, "recordingID": id, "audioVersion": 1,
            "generatedAt": date, "modelID": "fixture/summary", "transcriptionModelID": "fixture/transcription",
            "markdown": source, "transcript": "화면 검증용 합성 전사문입니다.", "costUSD": 0]
        try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appending(path: "meta.json"))
        try JSONSerialization.data(withJSONObject: notes).write(to: folder.appending(path: "meeting-notes.json"))
        try Data("fixture".utf8).write(to: folder.appending(path: "audio.m4a"))
        return root
    }
}
