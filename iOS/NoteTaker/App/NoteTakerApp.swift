import SwiftUI

@main
struct NoteTakerApp: App {
    @State private var model: LibraryAppModel
    @Environment(\.scenePhase) private var scenePhase
    private let isTesting: Bool

    init() {
        isTesting = ProcessInfo.processInfo.arguments.contains("-uiTesting") ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        _model = State(initialValue: LibraryAppModel(services: isTesting ? .uiTesting() : .live()))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { model.setForeground(true) }
                    else if phase == .background { model.setForeground(false) }
                }
        }
            .backgroundTask(.appRefresh(IOSBackgroundSync.identifier)) {
                await model.refreshInBackground()
            }
    }
}
