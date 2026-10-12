import Foundation
import Testing
@testable import MacInterfaceController

private final class FocusSchedule {
    var work: [() -> Void] = []
    func enqueue(_ delay: TimeInterval, _ action: @escaping () -> Void) { work.append(action) }
    func next() { if !work.isEmpty { work.removeFirst()() } }
    func drain() { while !work.isEmpty { next() } }
}

private final class FakeWindowFocus: WindowFocusBackend {
    let targetPID: pid_t
    var unavailableReason: String?
    var current = WindowFocusState(frontmostPID: 10, selectedWindowFocused: false)
    var requests = 0
    var onRequest: (() -> Void)?
    init(pid: pid_t = 20) { targetPID = pid }
    func state() -> WindowFocusState { current }
    func requestFocus() { requests += 1; onRequest?() }
    func finish() { current = WindowFocusState(frontmostPID: targetPID, selectedWindowFocused: true) }
}

struct WindowFocusTests {
    @Test func waitsForActualWindowFocusAfterAsynchronousActivation() {
        let queue = FocusSchedule()
        let backend = FakeWindowFocus()
        let focus = WindowFocusController(ownPID: 99, schedule: queue.enqueue, reportFailure: {})
        focus.activate(backend)
        #expect(backend.requests == 0) // No AX work inside the key event callback.
        queue.next()
        #expect(backend.requests == 1)
        backend.finish() // The OS completes activation on a later run-loop turn.
        queue.drain()
        #expect(backend.requests == 1)
        #expect(focus.lastError == nil)
    }

    @Test func retriesWhenOriginalAppRemainsInFront() {
        let queue = FocusSchedule()
        let backend = FakeWindowFocus()
        let focus = WindowFocusController(ownPID: 99, schedule: queue.enqueue, reportFailure: {})
        backend.onRequest = { if backend.requests == 2 { backend.finish() } }
        focus.activate(backend)
        queue.drain()
        #expect(backend.requests == 2)
        #expect(focus.lastError == nil)
    }

    @Test func activatingAppAloneDoesNotCountAsSelectingItsWindow() {
        let queue = FocusSchedule()
        let backend = FakeWindowFocus()
        backend.current.frontmostPID = backend.targetPID
        var failures = 0
        let focus = WindowFocusController(ownPID: 99, schedule: queue.enqueue, reportFailure: { failures += 1 })
        focus.activate(backend)
        queue.drain()
        #expect(backend.requests == 3)
        #expect(focus.lastError != nil)
        #expect(failures == 1)
    }

    @Test func hiddenOrMinimizedWindowIsNotSuccessfulFocus() {
        let minimized = WindowFocusState(frontmostPID: 20, selectedWindowFocused: true, isMinimized: true)
        let hidden = WindowFocusState(frontmostPID: 20, selectedWindowFocused: true, isHidden: true)
        #expect(!minimized.hasFocus(targetPID: 20))
        #expect(!hidden.hasFocus(targetPID: 20))
    }

    @Test func doesNotStealFocusAfterUserMovesToAnotherApp() {
        let queue = FocusSchedule()
        let backend = FakeWindowFocus()
        let focus = WindowFocusController(ownPID: 99, schedule: queue.enqueue, reportFailure: {})
        focus.activate(backend)
        queue.next()
        backend.current.frontmostPID = 30
        queue.drain()
        #expect(backend.requests == 1)
        #expect(focus.lastError == nil)
    }

    @Test func newSelectionInvalidatesPreviousRetry() {
        let queue = FocusSchedule()
        let old = FakeWindowFocus()
        let new = FakeWindowFocus(pid: 30)
        let focus = WindowFocusController(ownPID: 99, schedule: queue.enqueue, reportFailure: {})
        focus.activate(old)
        queue.next()
        new.onRequest = { new.finish() }
        focus.activate(new)
        queue.drain()
        #expect(old.requests == 1)
        #expect(new.requests == 1)
        #expect(focus.lastError == nil)
    }

    @Test func cancelStopsPendingFocusRequests() {
        let queue = FocusSchedule()
        let backend = FakeWindowFocus()
        let focus = WindowFocusController(ownPID: 99, schedule: queue.enqueue, reportFailure: {})
        focus.activate(backend)
        queue.next()
        focus.cancel()
        queue.drain()
        #expect(backend.requests == 1)
        #expect(focus.lastError == nil)
    }

    @Test func unavailableTargetFailsWithoutActivation() {
        let queue = FocusSchedule()
        let backend = FakeWindowFocus()
        backend.unavailableReason = "앱 종료"
        let focus = WindowFocusController(ownPID: 99, schedule: queue.enqueue, reportFailure: {})
        focus.activate(backend)
        queue.drain()
        #expect(backend.requests == 0)
        #expect(focus.lastError == "앱 종료")
    }
}
