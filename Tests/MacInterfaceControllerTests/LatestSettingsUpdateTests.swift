import Foundation
import Testing
@testable import MacInterfaceController

@MainActor
struct LatestSettingsUpdateTests {
    @Test func rapidEditsWriteOnlyFinalValueAndSkipDuplicates() async {
        var writes: [Int] = []
        let updates = LatestSettingsUpdate<Int>(wait: {}, write: { writes.append($0) }, onError: { _ in Issue.record("unexpected failure") })
        for value in 0..<100 { updates.submit(value) }
        await updates.flush()
        #expect(writes == [99])
        updates.submit(99)
        await updates.flush()
        #expect(writes == [99])
    }

    @Test func disableIsARealRequestAndReplacesPendingEdits() async {
        var writes: [Int?] = []
        let updates = LatestSettingsUpdate<Int?>(wait: {}, write: { writes.append($0) }, onError: { _ in })
        updates.submit(42)
        updates.submit(nil)
        await updates.flush()
        #expect(writes.count == 1)
        #expect(writes.first! == nil)
        updates.submit(nil)
        await updates.flush()
        #expect(writes.count == 1)
    }

    @Test func writeInProgressFinishesBeforeLatestEditAndFlushWaitsForBoth() async throws {
        var gate: CheckedContinuation<Void, Never>?
        var started: [Int] = [], finished: [Int] = []
        let updates = LatestSettingsUpdate<Int>(wait: {}, write: { value in
            started.append(value)
            if value == 1 { await withCheckedContinuation { gate = $0 } }
            finished.append(value)
        }, onError: { _ in Issue.record("unexpected failure") })
        updates.submit(1)
        for _ in 0..<1000 { if gate != nil { break }; await Task.yield() }
        let continuation = try #require(gate)
        updates.submit(2)
        updates.submit(3)
        #expect(started == [1])
        continuation.resume()
        await updates.flush()
        #expect(started == [1, 3])
        #expect(finished == [1, 3])
    }

    @Test func failureAllowsRetryAndInvalidationReappliesSameValue() async {
        var attempts = 0, failures = 0
        let updates = LatestSettingsUpdate<Int>(wait: {}, write: { _ in
            attempts += 1
            if attempts == 1 { throw ProfileError.invalid("write failed") }
        }, onError: { _ in failures += 1 })
        updates.submit(1)
        await updates.flush()
        updates.submit(1)
        await updates.flush()
        #expect(attempts == 2 && failures == 1)
        updates.invalidate()
        updates.submit(1)
        await updates.flush()
        #expect(attempts == 3)
    }
}
