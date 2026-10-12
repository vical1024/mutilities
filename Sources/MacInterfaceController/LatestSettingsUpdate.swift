import Foundation

/// Coalesce rapid edits while serializing writes. Flush before backup/restore/exit
/// so an older request cannot run after a newer configuration or restoration.
@MainActor
final class LatestSettingsUpdate<Value: Equatable> {
    private var lastRequested: Value?
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private let wait: () async throws -> Void
    private let write: (Value) async throws -> Void
    private let onError: (Error) -> Void

    init(wait: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) },
         write: @escaping (Value) async throws -> Void, onError: @escaping (Error) -> Void) {
        self.wait = wait
        self.write = write
        self.onError = onError
    }

    func submit(_ value: Value) {
        guard lastRequested != .some(value) else { return }
        lastRequested = .some(value)
        let id = UUID()
        revision = id
        let previous = task
        previous?.cancel()
        task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.wait()
                try Task.checkCancellation()
                try await self.write(value)
            } catch {
                guard self.revision == id else { return }
                self.lastRequested = nil
                if !(error is CancellationError) { self.onError(error) }
            }
        }
    }

    func flush() async { await task?.value }
    func invalidate() { lastRequested = nil }
}
