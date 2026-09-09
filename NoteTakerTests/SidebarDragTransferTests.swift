import CoreTransferable
import Foundation
import Testing
@testable import NoteTaker

@Suite("Sidebar drag transfer")
struct SidebarDragTransferTests {
    @Test("native drag providers round trip folder and recording identifiers")
    func nativeProviderRoundTrip() async throws {
        for item in [SidebarDragItem.recording(UUID()), .folder(UUID())] {
            let provider = NSItemProvider()
            provider.register(item)
            #expect(provider.registeredTypeIdentifiers == ["com.seonwoo.notetaker.library-item"])
            let received: SidebarDragItem = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: SidebarDragItem.self) { result in
                    continuation.resume(with: result)
                }
            }
            #expect(received == item)
        }
    }

    @Test("library drag content is only exported inside this process")
    func transferStaysInApp() {
        #expect(SidebarDragItem.exportedContentTypes(visibility: .all).isEmpty)
        #expect(SidebarDragItem.exportedContentTypes(visibility: .ownProcess) == [.aiNoteTakerLibraryItem])
    }
}
