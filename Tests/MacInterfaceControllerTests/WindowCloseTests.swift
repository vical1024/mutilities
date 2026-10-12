import Foundation
import Carbon
import CoreGraphics
import Testing
@testable import MacInterfaceController

private final class CloseQueue {
    var work: [() -> Void] = []
    func enqueue(_ delay: TimeInterval, _ action: @escaping () -> Void) { work.append(action) }
    func drain() { while !work.isEmpty { work.removeFirst()() } }
}

private final class FakeWindowClose: WindowCloseBackend {
    var error: String?
    var requests = 0
    var state: WindowCloseState = .closed
    var reads = 0
    var onRead: (() -> Void)?
    func closeState() -> WindowCloseState { reads += 1; onRead?(); return state }
    func requestClose() -> String? { requests += 1; return error }
}

struct WindowCloseTests {
    @Test func closeLeavesEventCallbackAndRequestsExactlyOnce() {
        let queue = CloseQueue()
        let backend = FakeWindowClose()
        let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: {})
        controller.close(backend)
        #expect(backend.requests == 0)
        queue.drain()
        #expect(backend.requests == 1)
        #expect(controller.lastError == nil)
        queue.drain()
        #expect(backend.requests == 1)
    }

    @Test func failedOrAmbiguousCloseIsReportedWithoutRetry() {
        let queue = CloseQueue()
        let backend = FakeWindowClose()
        backend.error = "저장 확인창을 확인해 주세요."
        backend.state = .unknown
        var failures = 0
        let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: { failures += 1 })
        controller.close(backend)
        queue.drain()
        #expect(backend.requests == 1)
        #expect(controller.lastError == backend.error)
        #expect(failures == 1)
    }

    @Test func reopeningOrStoppingCancelsQueuedClose() {
        let queue = CloseQueue()
        let backend = FakeWindowClose()
        let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: {})
        controller.close(backend)
        controller.cancel()
        queue.drain()
        #expect(backend.requests == 0)
    }

    @Test func independentWindowsCanCloseWithoutCancellingEachOther() {
        let queue = CloseQueue()
        let first = FakeWindowClose(), second = FakeWindowClose()
        let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: {})
        var results: [WindowCloseResult] = []
        controller.close(first) { results.append($0) }
        controller.close(second) { results.append($0) }
        queue.drain()
        #expect(first.requests == 1 && second.requests == 1)
        #expect(results == [.closed, .closed])
    }

    @Test func duplicatePendingRequestIsIgnored() {
        let queue = CloseQueue(), id = UUID()
        let backend = FakeWindowClose()
        let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: {})
        controller.close(backend, id: id)
        controller.close(backend, id: id)
        queue.drain()
        #expect(backend.requests == 1)
    }

    @Test func successfulRequestWaitsForActualClosure() {
        let queue = CloseQueue(), backend = FakeWindowClose()
        backend.state = .open
        backend.onRead = { if backend.reads == 3 { backend.state = .closed } }
        let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: {})
        var results: [WindowCloseResult] = []
        controller.close(backend) { results.append($0) }
        queue.work.removeFirst()()
        #expect(results.isEmpty)
        queue.work.removeFirst()()
        #expect(results.isEmpty)
        queue.drain()
        #expect(results == [.closed])
        #expect(backend.requests == 1 && backend.reads == 3)
    }

    @Test func confirmationKeepsWindowAndDoesNotRetryClose() {
        let queue = CloseQueue(), backend = FakeWindowClose()
        backend.state = .confirmationRequired
        let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: {})
        var result: WindowCloseResult?
        controller.close(backend) { result = $0 }
        queue.drain()
        guard case .keptOpen = result else { Issue.record("confirmation must keep window"); return }
        #expect(backend.requests == 1 && backend.reads == 1)
    }

    @Test func unknownOrUnclosedWindowIsNeverRemovedAndPollingIsBounded() {
        for state in [WindowCloseState.unknown, .open] {
            let queue = CloseQueue(), backend = FakeWindowClose()
            backend.state = state
            let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: {})
            var result: WindowCloseResult?
            controller.close(backend) { result = $0 }
            queue.drain()
            guard case .keptOpen = result else { Issue.record("unconfirmed window must remain"); return }
            #expect(backend.requests == 1 && backend.reads == 6)
        }
    }

    @Test func cancellingAfterRequestDiscardsLateResult() {
        let queue = CloseQueue(), backend = FakeWindowClose()
        let controller = WindowCloseController(schedule: queue.enqueue, reportFailure: {})
        var results: [WindowCloseResult] = []
        controller.close(backend) { results.append($0) }
        queue.work.removeFirst()()
        controller.cancel()
        queue.drain()
        #expect(backend.requests == 1 && backend.reads == 0)
        #expect(results.isEmpty)
    }

    @Test func closeUsesWAndAllowsHoldingSwitcherModifiers() {
        for flags: CGEventFlags in [[], .maskControl, [.maskControl, .maskShift]] {
            #expect(KeyboardRemappingEngine.isWindowCloseShortcut(keyCode: kVK_ANSI_W, modifiers: flags))
            #expect(!KeyboardRemappingEngine.isWindowCloseShortcut(keyCode: kVK_Delete, modifiers: flags))
            #expect(!KeyboardRemappingEngine.isWindowCloseShortcut(keyCode: kVK_ForwardDelete, modifiers: flags))
        }
        for flags: CGEventFlags in [.maskCommand, .maskAlternate, .maskShift] {
            #expect(!KeyboardRemappingEngine.isWindowCloseShortcut(keyCode: kVK_ANSI_W, modifiers: flags))
        }
    }

    @Test @MainActor func wPassesThroughWhenSwitcherIsNotVisible() throws {
        let engine = KeyboardRemappingEngine()
        let press = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: true))
        press.flags = []
        #expect(engine.transform(type: .keyDown, event: press, finderContext: .otherApplication) != nil)
        #expect(press.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_W))
        let release = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: false))
        #expect(engine.transform(type: .keyUp, event: release, finderContext: .otherApplication) != nil)
    }
}

private final class FakeSwitcher: WindowSwitching {
    var isVisible = true
    var closes = 0
    var cycles = 0
    func showOrCycle(reverse: Bool) { cycles += 1; isVisible = true }
    func commitSelection() { isVisible = false }
    func closeSelection() { closes += 1 }
    func cancel() { isVisible = false }
}

@MainActor
struct WindowCloseKeyTests {
    private func event(_ key: Int, down: Bool = true, repeating: Bool = false, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down))
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return event
    }

    @Test func heldWClosesOnlyOnceWhileListRemainsVisible() throws {
        let switcher = FakeSwitcher()
        let engine = KeyboardRemappingEngine(windowSwitcherEnabled: true, windowSwitcher: switcher)
        let first = try event(kVK_ANSI_W)
        #expect(engine.transform(type: .keyDown, event: first, finderContext: .otherApplication) == nil)
        #expect(switcher.closes == 1)
        #expect(switcher.isVisible)
        for _ in 0..<3 {
            let repeatKey = try event(kVK_ANSI_W, repeating: true)
            #expect(engine.transform(type: .keyDown, event: repeatKey, finderContext: .otherApplication) == nil)
        }
        #expect(switcher.closes == 1)
        let release = try event(kVK_ANSI_W, down: false)
        #expect(engine.transform(type: .keyUp, event: release, finderContext: .otherApplication) == nil)
        let newPress = try event(kVK_ANSI_W)
        #expect(engine.transform(type: .keyDown, event: newPress, finderContext: .otherApplication) == nil)
        #expect(switcher.closes == 2)
    }

    @Test func repeatedArrowStillCyclesAndDeleteDoesNotClose() throws {
        let switcher = FakeSwitcher()
        let engine = KeyboardRemappingEngine(windowSwitcherEnabled: true, windowSwitcher: switcher)
        for repeating in [false, true] {
            let arrow = try event(kVK_DownArrow, repeating: repeating)
            #expect(engine.transform(type: .keyDown, event: arrow, finderContext: .otherApplication) == nil)
        }
        #expect(switcher.cycles == 2)
        let delete = try event(kVK_Delete)
        #expect(engine.transform(type: .keyDown, event: delete, finderContext: .otherApplication) != nil)
        #expect(switcher.closes == 0)
    }

    @Test func holdingPostSwapControlStillAllowsWToClose() throws {
        let switcher = FakeSwitcher()
        let engine = KeyboardRemappingEngine(swapCommandControl: true, windowSwitcherEnabled: true, windowSwitcher: switcher)
        let press = try event(kVK_ANSI_W, flags: .maskCommand)
        #expect(engine.transform(type: .keyDown, event: press, finderContext: .otherApplication) == nil)
        #expect(switcher.closes == 1)
    }
}
