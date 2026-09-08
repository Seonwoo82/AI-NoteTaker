import BackgroundTasks
import Foundation
import OSLog
import UIKit

@MainActor
enum IOSBackgroundSync {
    static let identifier = "com.seonwoo.notetaker.ios.sync-refresh"
    private static let logger = Logger(subsystem: "com.seonwoo.notetaker.ios", category: "BackgroundSync")

    static func schedule(enabled: Bool) {
        guard enabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { logger.debug("Background refresh unavailable: \(error.localizedDescription, privacy: .public)") }
    }
}

/// Finishes a foreground transfer when the app is put away, within iOS's time allowance.
@MainActor
final class SyncBackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var work: Task<Void, Never>?
    private var onExpiration: (() -> Void)?
    private var generation = 0

    func begin(operation: @escaping @MainActor () async -> Void, onExpiration: @escaping @MainActor () -> Void) {
        guard work == nil else { return }
        generation += 1
        let current = generation
        self.onExpiration = onExpiration
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Complete note sync") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        guard identifier != .invalid else {
            self.onExpiration = nil
            onExpiration()
            return
        }
        work = Task { [weak self] in
            await operation()
            guard let self, self.generation == current else { return }
            self.finish()
        }
    }

    private func expire() {
        generation += 1
        onExpiration?()
        work?.cancel()
        finish()
    }

    private func finish() {
        work = nil
        onExpiration = nil
        guard identifier != .invalid else { return }
        let ended = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(ended)
    }
}
