#if os(iOS)
import SwiftUI
import XCTest
@testable import NoteTakerIOS

@MainActor
final class AIStaticRenderTests: XCTestCase {
    func testAISettingsAndCompletedMinutesRenderAtIPhoneWidth() async throws {
        let environment = AIEnvironment.testing(configured: true)
        let configuration = AIConfiguration(
            client: environment.client,
            keyStore: environment.keyStore,
            defaults: environment.defaults
        )
        await configuration.refreshModels()
        configuration.modelID = "fixture/summary"
        configuration.transcriptionModelID = "fixture/transcription"

        let paths = LibraryPaths(libraryRoot: temporaryLibraryRoot(), arguments: [])
        let library = await LibraryStore.open(paths: paths)
        let recording = Recording(title: "iPhone Planning", duration: 3725, mode: .micOnly)
        try library.add(recording)

        let document = MeetingNotesDocument(
            recordingID: recording.id,
            audioVersion: recording.audioVersion,
            generatedAt: Date(timeIntervalSince1970: 1_756_800_000),
            modelID: "fixture/summary",
            transcriptionModelID: "fixture/transcription",
            markdown: Self.syntheticMinutes,
            transcript: "[00:00]\nWe discussed iOS AI settings, table rendering, outline navigation, and cost visibility.",
            costUSD: 0.0123
        )
        try AIArtifactStore(paths: library.paths).saveDocument(document, recording: recording)

        let service = MeetingNotesService(
            configuration: configuration,
            client: environment.client,
            chunker: environment.chunker,
            library: library
        )
        await service.load(recording)

        let notesImage = try await renderImage(
            MeetingNotesView(
                recording: recording,
                service: service,
                configuration: configuration,
                openAISettings: {}
            )
            .frame(width: 390, height: 920)
        )
        let settingsImage = try await renderImage(
            AISettingsView(configuration: configuration)
                .frame(width: 390, height: 920)
        )

        attach(notesImage, name: "AI Meeting Notes iPhone 390pt")
        attach(settingsImage, name: "AI Settings iPhone 390pt")

        let missingKeyEnvironment = AIEnvironment.testing()
        let missingKeyConfiguration = AIConfiguration(client: missingKeyEnvironment.client,
            keyStore: missingKeyEnvironment.keyStore, defaults: missingKeyEnvironment.defaults)
        missingKeyConfiguration.setSyncContext(endpoint: "https://example.test", enabled: true)
        missingKeyConfiguration.acceptSharedPreferences(AISharedPreferences(
            modelID: "fixture/summary", transcriptionModelID: "fixture/transcription", outputLanguage: "ko",
            autoGenerate: true, modifiedAt: 1000, mutationID: UUID()))
        missingKeyConfiguration.setOtherDeviceKeyPresence(true)
        await missingKeyConfiguration.refreshModels()
        let missingKeyImage = try await renderImage(
            AISettingsView(configuration: missingKeyConfiguration).frame(width: 390, height: 920))
        attach(missingKeyImage, name: "AI Shared Settings Missing Key 390pt")

        let parsed = MarkdownDocument(document.markdown)
        guard service.document(for: recording.id) == document else { throw RenderError.documentNotLoaded }
        guard !parsed.outlineHeadings.isEmpty else { throw RenderError.missingOutline }
        guard document.markdown.contains("| Option | Status |") else { throw RenderError.missingTable }
        guard document.costUSD == 0.0123 else { throw RenderError.missingCost }
        guard configuration.models.contains(where: \.supportsSummary) else { throw RenderError.missingSummaryModel }
        guard configuration.models.contains(where: \.supportsTranscription) else { throw RenderError.missingTranscriptionModel }
        guard (notesImage.pngData()?.count ?? 0) > 10_000 else { throw RenderError.blankNotesRender }
        guard (settingsImage.pngData()?.count ?? 0) > 10_000 else { throw RenderError.blankSettingsRender }
    }

    private func renderImage<Content: View>(_ content: Content) async throws -> UIImage {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw RenderError.missingImage
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 920)
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 920)
        controller.view.backgroundColor = .systemBackground
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format)
        let image = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        guard hasVisibleContent(image) else { throw RenderError.missingImage }
        return image
    }

    private func hasVisibleContent(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var different = 0
        for index in stride(from: 4, to: pixels.count, by: 4) {
            if (0..<3).contains(where: { abs(Int(pixels[index + $0]) - Int(pixels[$0])) > 24 }) {
                different += 1
            }
        }
        return different > 1_000
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func temporaryLibraryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "NoteTakerIOSAIRenderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private enum RenderError: Error {
        case missingImage
        case documentNotLoaded
        case missingOutline
        case missingTable
        case missingCost
        case missingSummaryModel
        case missingTranscriptionModel
        case blankNotesRender
        case blankSettingsRender
    }

    private static let syntheticMinutes = """
    # iOS AI Minutes

    ## Options Reviewed
    The team reviewed iPhone settings, output language choices, model selection, transcript visibility, and Markdown copying.

    ## Cost and Follow-up
    The generated document includes a small USD cost, a transcript, and reusable Markdown.

    ## Decisions
    | Option | Status |
    | --- | --- |
    | Outline navigation | Present |
    | Table rendering | Present |
    | Cost display | Present |

    ## Actions
    - [ ] Verify static iPhone render attachments
    - [ ] Run sequential app builds from the root coordinator
    """
}
#endif
