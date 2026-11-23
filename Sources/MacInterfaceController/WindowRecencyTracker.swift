import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func axGetWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// macOS keeps every window of the active app grouped in z-order, so two windows of one app (e.g. two Chrome
/// profiles) always sit next to each other there. This tracks which window was actually focused last, driven by
/// app activation and per-app AX focused-window notifications rather than polling.
final class WindowRecencyTracker {
    private var order: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var started = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private static let focusChanged: AXObserverCallback = { _, element, _, refcon in
        guard let refcon else { return }
        Unmanaged<WindowRecencyTracker>.fromOpaque(refcon).takeUnretainedValue().recordFocusedWindow(ofAppWith: element)
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.attach(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.detach(app.processIdentifier) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.attach(app)
            self?.recordFocusedWindow(ofAppWith: AXUIElementCreateApplication(app.processIdentifier))
        }
        attachRunningApplications()
    }

    /// Refreshes the frontmost window and picks up apps that could not be observed earlier (e.g. permission granted later).
    func sample() {
        attachRunningApplications()
        if let app = NSWorkspace.shared.frontmostApplication {
            recordFocusedWindow(ofAppWith: AXUIElementCreateApplication(app.processIdentifier))
        }
    }

    /// 0 is the most recently focused window; windows never seen focused are absent.
    func ranks() -> [CGWindowID: Int] {
        Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
    }

    private func attachRunningApplications() {
        guard AXIsProcessTrusted() else { return }
        NSWorkspace.shared.runningApplications.forEach(attach)
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), app.activationPolicy == .regular, !app.isTerminated,
              pid != ownPID, observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.focusChanged, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        guard AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    /// A stale entry would stop a new app that reuses the PID from being observed.
    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// Records the focused window of the app owning `element` if that app is frontmost.
    private func recordFocusedWindow(ofAppWith element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != ownPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused else { return }
        var id: CGWindowID = 0
        guard axGetWindowID(unsafeBitCast(focused, to: AXUIElement.self), &id) == .success, id != 0, order.first != id else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        if order.count > 300 { order.removeLast(order.count - 300) }
    }
}
