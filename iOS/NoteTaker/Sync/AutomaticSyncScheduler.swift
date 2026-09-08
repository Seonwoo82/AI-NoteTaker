import Foundation

/// One cancellable polling loop; an explicit request also resets failure backoff.
@MainActor
final class AutomaticSyncScheduler {
    private let synchronize: @MainActor () async -> Bool
    private let sleep: @MainActor (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    init(synchronize: @escaping @MainActor () async -> Bool,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.synchronize = synchronize
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        task = Task { [synchronize, sleep] in
            var retrySeconds = 30
            while !Task.isCancelled {
                let succeeded = await synchronize()
                guard !Task.isCancelled else { return }
                let delay = succeeded ? 30 : retrySeconds
                retrySeconds = succeeded ? 30 : min(300, retrySeconds * 2)
                do { try await sleep(.seconds(delay)) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func requestSync() {
        guard task != nil else { return }
        stop()
        start()
    }
}
