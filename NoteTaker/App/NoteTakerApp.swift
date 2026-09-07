import AppKit
import SwiftUI

@main
struct NoteTakerApp: App {
    @State private var services: AppServices
    @State private var container: AppContainer?
    @StateObject private var smokeRecordBootstrap: SmokeRecordBootstrap
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        _services = State(initialValue: isUITesting ? .uiTesting() : .live())
        _smokeRecordBootstrap = StateObject(wrappedValue: SmokeRecordBootstrap())
    }

    var body: some Scene {
        Window("NoteTaker", id: "main") {
            RootView(
                services: services,
                container: $container,
                onContainerLoaded: { appDelegate.session = $0.session }
            )
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    smokeRecordBootstrap.startOnce()
                }
        }
        .defaultSize(width: 1_100, height: 700)
        .commands {
            LibraryCommands(container: container)
        }

        Settings {
            if let container {
                SettingsView(settings: container.settings, session: container.session)
                    .frame(width: 420)
            } else {
                ProgressView()
                    .frame(width: 420, height: 180)
            }
        }
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var session: RecordingSession?
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard let session else { return .terminateNow }
        guard session.phase != .idle else { return .terminateNow }

        isTerminating = true
        Task { @MainActor in
            await session.finishForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
