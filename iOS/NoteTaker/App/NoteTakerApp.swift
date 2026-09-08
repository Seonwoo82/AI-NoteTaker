import SwiftUI

@main
struct NoteTakerApp: App {
    @State private var services: AppServices
    #if os(macOS)
    @StateObject private var smokeRecordBootstrap: SmokeRecordBootstrap
    #endif

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        _services = State(initialValue: isUITesting ? .uiTesting() : .live())
        #if os(macOS)
        _smokeRecordBootstrap = StateObject(wrappedValue: SmokeRecordBootstrap())
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        Window("AI-NoteTaker", id: "main") {
            RootView(services: services)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    smokeRecordBootstrap.startOnce()
                }
        }
        .defaultSize(width: 1_100, height: 700)
        #else
        WindowGroup {
            RootView(services: services)
        }
        #endif
    }
}
