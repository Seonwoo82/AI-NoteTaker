import AppKit
import SwiftUI

@main
struct NoteTakerApp: App {
    @State private var runtime: AppRuntime
    @StateObject private var smokeRecordBootstrap: SmokeRecordBootstrap
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        _runtime = State(initialValue: AppRuntime(services: isUITesting ? .uiTesting() : .live()))
        _smokeRecordBootstrap = StateObject(wrappedValue: SmokeRecordBootstrap())
    }

    var body: some Scene {
        Window("NoteTaker", id: "main") {
            RootView(container: runtime.container)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    await prepareApp()
                    smokeRecordBootstrap.startOnce()
                }
        }
        .defaultSize(width: 1_100, height: 700)
        .commands {
            LibraryCommands(container: runtime.container)
        }

        MenuBarExtra {
            MenuBarRecordingView(container: runtime.container)
                .task { await prepareApp() }
        } label: {
            MenuBarRecordingLabel(session: runtime.container?.session)
                .task { await prepareApp() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let container = runtime.container {
                SettingsView(settings: container.settings, session: container.session)
                    .frame(width: 420)
            } else {
                ProgressView()
                    .frame(width: 420, height: 180)
            }
        }
    }

    private func prepareApp() async {
        let container = await runtime.load()
        appDelegate.session = container.session
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
