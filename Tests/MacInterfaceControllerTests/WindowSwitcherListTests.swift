import AppKit
import Testing
@testable import MacInterfaceController

struct WindowSwitcherListTests {
    private func model() -> WindowSwitcherViewModel {
        let model = WindowSwitcherViewModel()
        model.windows = (0..<3).map { WindowDisplayItem(applicationName: "Test", windowTitle: "Window \($0)", icon: NSImage(), isMinimized: false) }
        return model
    }

    @Test func removingDifferentWindowPreservesSelectedIdentityAndRemainingIDs() {
        let model = model()
        let ids = model.windows.map(\.id)
        model.selectedIndex = 2
        model.removeWindow(id: ids[0])
        #expect(model.windows.map(\.id) == Array(ids.dropFirst()))
        #expect(model.selectedID == ids[2])
        #expect(model.selectedIndex == 1)
    }

    @Test func closingSelectionPicksNextThenPreviousAtEnd() {
        let model = model()
        // Use the model's stable identities throughout repeated removals.
        let ownIDs = model.windows.map(\.id)
        model.selectedIndex = 1
        model.closingIDs.insert(ownIDs[1])
        model.removeWindow(id: ownIDs[1])
        #expect(model.selectedID == ownIDs[2])
        #expect(model.closingIDs.isEmpty)
        model.removeWindow(id: ownIDs[2])
        #expect(model.selectedID == ownIDs[0])
    }

    @Test func lastRemovalLeavesValidEmptyModel() {
        let model = model()
        for id in model.windows.map(\.id) { model.removeWindow(id: id) }
        #expect(model.windows.isEmpty)
        #expect(model.selectedIndex == 0)
        #expect(model.selectedID == nil)
    }

    @Test func resetClearsPendingAndTransitionState() {
        let model = model()
        model.closingIDs = Set(model.windows.map(\.id))
        model.notice = "Pending confirmation"
        model.isCommitting = true
        model.reset()
        #expect(model.closingIDs.isEmpty && model.windows.isEmpty)
        #expect(model.notice == nil && !model.isCommitting)
    }
}
