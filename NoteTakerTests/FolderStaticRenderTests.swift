import SwiftUI
import XCTest
#if os(macOS)
import AppKit
@testable import NoteTaker
#else
import UIKit
@testable import NoteTakerIOS
#endif

@MainActor
final class FolderStaticRenderTests: XCTestCase {
    #if os(macOS)
    func testAllRecordingsAfterFolderCreationAndWithManyFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "folder-navigation-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = await AppContainer.load(services: .uiTesting(), paths: LibraryPaths(libraryRoot: root, arguments: []))
        let controller = container.libraryController
        let first = Recording(title: "전체 목록에 남아 있는 회의", duration: 120, mode: .micOnly)
        try container.library.add(first)
        container.model.selectedRecordingID = first.id
        _ = try controller.createFolder(named: "새 폴더")
        for scenario in ["after-create", "many-folders"] {
            if scenario == "many-folders" {
                for index in 1...24 { _ = try controller.createFolder(named: "회의 폴더 \(index)") }
            }
            let view = SidebarView(controller: controller, model: container.model, settings: container.settings, session: container.session)
                .environment(\.locale, Locale(identifier: "ko_KR")).environment(\.colorScheme, .dark)
                .frame(width: 300, height: 540).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 540)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            await controller.selectFolder(.all)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let output = repo.appending(path: "build/visual-qa")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try png.write(to: output.appending(path: "folder-navigation-\(scenario)-mac.png"))
            XCTAssertNil(container.model.selectedCustomFolderID)
            XCTAssertEqual(controller.visibleRecordings.map(\.id), [first.id])
        }
    }
    #endif

    func testFolderSidebarRendersKoreanWithoutTouchingUserLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "folder-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(libraryRoot: root, arguments: [])
        #if os(macOS)
        let container = await AppContainer.load(services: .uiTesting(), paths: paths)
        let library = container.library
        #else
        let model = LibraryAppModel(services: .uiTesting(), aiEnvironment: .testing())
        await model.open(paths: paths)
        let library = try XCTUnwrap(model.library)
        #endif
        let project = try library.folderStore.create(name: "프로젝트 회의")
        _ = try library.folderStore.create(name: "아이디어")
        var first = Recording(title: "제품 출시 일정 논의", duration: 3_600, mode: .micOnly)
        first.folderID = project.id
        try library.add(first)
        try library.add(Recording(title: "분류하지 않은 메모", duration: 95, mode: .micOnly))
        #if os(macOS)
        await container.libraryController.selectCustomFolder(project.id)
        let content = SidebarView(controller: container.libraryController, model: container.model,
            settings: container.settings, session: container.session)
        let width: CGFloat = 320
        let height: CGFloat = 780
        let view = content.environment(\.locale, Locale(identifier: "ko_KR")).environment(\.colorScheme, .dark)
            .frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let platform = "mac"
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        #else
        model.selectCustomFolder(project.id)
        model.selection = nil
        let view = RootView(model: model).environment(\.locale, Locale(identifier: "ko_KR"))
            .environment(\.colorScheme, .dark)
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = .dark
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.backgroundColor = .systemBackground
        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData())
        let platform = "ios"
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #endif
        let output = repo.appending(path: "build/visual-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appending(path: "recording-folders-\(platform).png"))
        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertEqual(library.folderStore.activeFolders.count, 2)
        XCTAssertEqual(library.recordings.count, 2)
    }
}
