import Foundation
import Observation

/// Keeps capture and library ownership independent of any visible window.
@MainActor
@Observable
final class AppRuntime {
    private let services: AppServices
    private let paths: LibraryPaths
    @ObservationIgnored private var loadingTask: Task<AppContainer, Never>?
    private(set) var container: AppContainer?

    init(services: AppServices, paths: LibraryPaths = LibraryPaths()) {
        self.services = services
        self.paths = paths
    }

    @discardableResult
    func load() async -> AppContainer {
        if let container { return container }
        let task: Task<AppContainer, Never>
        if let loadingTask {
            task = loadingTask
        } else {
            task = Task { await AppContainer.load(services: services, paths: paths) }
            loadingTask = task
        }
        let loaded = await task.value
        container = loaded
        loadingTask = nil
        return loaded
    }
}
