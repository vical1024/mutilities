import AppKit
import ApplicationServices

struct WindowFocusState {
    var frontmostPID: pid_t?
    var selectedWindowFocused: Bool
    var isMinimized = false
    var isHidden = false

    func hasFocus(targetPID: pid_t) -> Bool {
        frontmostPID == targetPID && selectedWindowFocused && !isMinimized && !isHidden
    }
}

protocol WindowFocusBackend: AnyObject {
    var targetPID: pid_t { get }
    var unavailableReason: String? { get }
    func state() -> WindowFocusState
    func requestFocus()
}

/// Activation is asynchronous. Verify the selected window, not just the app,
/// and invalidate pending work when another selection or cancellation occurs.
final class WindowFocusController: ObservableObject {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var lastError: String?
    private var requestID: UUID?
    private let schedule: Scheduler
    private let ownPID: pid_t
    private let reportFailure: () -> Void

    init(ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         schedule: @escaping Scheduler = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }, reportFailure: @escaping () -> Void = { NSSound.beep() }) {
        self.ownPID = ownPID
        self.schedule = schedule
        self.reportFailure = reportFailure
    }

    func activate(_ backend: WindowFocusBackend) {
        let id = UUID()
        requestID = id
        lastError = nil
        // Leave the keyboard event-tap callback before making cross-process AX calls.
        schedule(0) { [weak self] in
            guard let self, self.requestID == id else { return }
            let originalPID = backend.state().frontmostPID
            self.attempt(backend, id: id, originalPID: originalPID, number: 0)
        }
    }

    func cancel() { requestID = nil }

    private func attempt(_ backend: WindowFocusBackend, id: UUID, originalPID: pid_t?, number: Int) {
        guard requestID == id else { return }
        if let reason = backend.unavailableReason { fail(reason); return }
        backend.requestFocus()
        schedule([0.12, 0.25, 0.5][number]) { [weak self] in
            guard let self, self.requestID == id else { return }
            if let reason = backend.unavailableReason { self.fail(reason); return }
            let state = backend.state()
            if state.hasFocus(targetPID: backend.targetPID) {
                self.requestID = nil
                return
            }
            // A user switching to a third app must not have focus stolen back.
            if let pid = state.frontmostPID,
               pid != originalPID && pid != backend.targetPID && pid != self.ownPID {
                self.cancel()
                return
            }
            if number < 2 {
                self.attempt(backend, id: id, originalPID: originalPID, number: number + 1)
            } else {
                self.fail("선택한 창을 앞으로 가져오지 못했습니다. 창이 열려 있는지 확인하고 다시 선택해 주세요. 반복되면 설정 점검에서 접근성 권한을 확인해 주세요.")
            }
        }
    }

    private func fail(_ message: String) {
        requestID = nil
        lastError = message
        reportFailure()
    }
}

final class LiveWindowFocusBackend: WindowFocusBackend {
    private let application: NSRunningApplication
    private let window: AXUIElement
    private let appElement: AXUIElement
    var targetPID: pid_t { application.processIdentifier }
    var unavailableReason: String? {
        if application.isTerminated { return "선택한 앱이 종료되어 창을 열 수 없습니다." }
        if !AXIsProcessTrusted() { return "창 전환에 접근성 권한이 필요합니다. 설정 점검 → 권한에서 허용해 주세요." }
        return nil
    }

    init(application: NSRunningApplication, window: AXUIElement) {
        self.application = application
        self.window = window
        appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        AXUIElementSetMessagingTimeout(window, 0.2)
    }

    func state() -> WindowFocusState {
        let focused = attribute(appElement, kAXFocusedWindowAttribute)
        return WindowFocusState(
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            selectedWindowFocused: focused.map { CFEqual($0, window) } ?? false,
            isMinimized: attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
            isHidden: application.isHidden
        )
    }

    func requestFocus() {
        if application.isHidden { application.unhide() }
        if attribute(window, kAXMinimizedAttribute) as? Bool == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        // Set the selected window before activation so Finder does not restore
        // its previously-main window instead. AXFocusedWindow can be read-only.
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        if NSApplication.shared.isActive { NSApplication.shared.yieldActivation(to: application) }
        application.activate(options: [])
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(window, kAXFocusedAttribute as CFString, &settable) == .success,
           settable.boolValue {
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
