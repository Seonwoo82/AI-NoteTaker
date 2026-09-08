import AppKit
import SwiftUI

@main
struct NoteTakerApp: App {
    @State private var runtime: AppRuntime
    @StateObject private var smokeRecordBootstrap: SmokeRecordBootstrap
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate

    init() {
        let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        let paths = isUnitTesting && !isUITesting
            ? LibraryPaths(libraryRoot: FileManager.default.temporaryDirectory.appending(path: "NoteTakerTestHost-\(UUID())"), arguments: [])
            : LibraryPaths()
        _runtime = State(initialValue: AppRuntime(services: isUITesting || isUnitTesting ? .uiTesting() : .live(), paths: paths))
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
                TabView(selection: Binding(get: { container.aiConfiguration.settingsTab }, set: { container.aiConfiguration.settingsTab = $0 })) {
                    SettingsView(settings: container.settings, session: container.session)
                        .tabItem { Label(String(localized: "Recording"), systemImage: "mic") }
                        .tag("recording")
                    AISettingsView(configuration: container.aiConfiguration)
                        .tabItem { Label(String(localized: "AI Meeting Notes"), systemImage: "sparkles") }
                        .tag("ai")
                }
                .frame(width: 560, height: 590)
            } else {
                ProgressView()
                    .frame(width: 420, height: 180)
            }
        }
    }

    private func prepareApp() async {
        let container = await runtime.load()
        appDelegate.session = container.session
        appDelegate.meetingNotes = container.meetingNotes
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var session: RecordingSession?
    var meetingNotes: MeetingNotesService?
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        meetingNotes?.prepareForTermination()
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
