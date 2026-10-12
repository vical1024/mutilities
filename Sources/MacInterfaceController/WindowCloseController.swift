import AppKit
import ApplicationServices

enum WindowCloseState: Equatable { case open, closed, confirmationRequired, unknown }
enum WindowCloseResult: Equatable {
    case closed
    case keptOpen(String)
    case failed(String)
}

protocol WindowCloseBackend: AnyObject {
    func requestClose() -> String?
    func closeState() -> WindowCloseState
}

final class WindowCloseController: ObservableObject {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var lastError: String?
    private var pending: [UUID: UUID] = [:]
    private let schedule: Scheduler
    private let reportFailure: () -> Void
    private let delays: [TimeInterval] = [0.08, 0.15, 0.3, 0.5, 1, 1]

    init(schedule: @escaping Scheduler = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
         reportFailure: @escaping () -> Void = { NSSound.beep() }) {
        self.schedule = schedule
        self.reportFailure = reportFailure
    }

    func close(_ backend: WindowCloseBackend, id: UUID = UUID(), completion: @escaping (WindowCloseResult) -> Void = { _ in }) {
        guard pending[id] == nil else { return }
        let token = UUID()
        pending[id] = token
        lastError = nil
        // One request only. A timeout may already have opened a save dialog.
        schedule(0) { [weak self] in
            guard let self, self.pending[id] == token else { return }
            if let error = backend.requestClose() {
                if backend.closeState() == .closed { self.finish(.closed, id: id, completion: completion) }
                else { self.finish(.failed(error), id: id, completion: completion) }
                return
            }
            self.verify(backend, id: id, token: token, attempt: 0, completion: completion)
        }
    }

    func cancel() { pending.removeAll() }

    private func verify(_ backend: WindowCloseBackend, id: UUID, token: UUID, attempt: Int,
                        completion: @escaping (WindowCloseResult) -> Void) {
        schedule(delays[attempt]) { [weak self] in
            guard let self, self.pending[id] == token else { return }
            switch backend.closeState() {
            case .closed: self.finish(.closed, id: id, completion: completion)
            case .confirmationRequired:
                self.finish(.keptOpen("저장 확인이 필요합니다. 해당 창을 선택하고 Enter를 눌러 확인해 주세요."), id: id, completion: completion)
            case .open, .unknown:
                if attempt + 1 < self.delays.count {
                    self.verify(backend, id: id, token: token, attempt: attempt + 1, completion: completion)
                } else {
                    self.finish(.keptOpen("아직 닫히지 않은 창입니다. 해당 창을 선택하고 Enter를 눌러 확인해 주세요."), id: id, completion: completion)
                }
            }
        }
    }

    private func finish(_ result: WindowCloseResult, id: UUID, completion: (WindowCloseResult) -> Void) {
        pending.removeValue(forKey: id)
        if case .failed(let message) = result { lastError = message; reportFailure() }
        completion(result)
    }
}

final class LiveWindowCloseBackend: WindowCloseBackend {
    private let application: NSRunningApplication
    private let window: AXUIElement

    init(application: NSRunningApplication, window: AXUIElement) {
        self.application = application
        self.window = window
    }

    func closeState() -> WindowCloseState {
        if application.isTerminated { return .closed }
        guard AXIsProcessTrusted() else { return .unknown }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return .unknown }
        guard windows.contains(where: { CFEqual($0, window) }) else { return .closed }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
           let children = children as? [AXUIElement] {
            for child in children {
                AXUIElementSetMessagingTimeout(child, 0.2)
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                   role as? String == kAXSheetRole { return .confirmationRequired }
            }
        }
        for candidate in windows {
            AXUIElementSetMessagingTimeout(candidate, 0.2)
            var modal: CFTypeRef?
            if AXUIElementCopyAttributeValue(candidate, kAXModalAttribute as CFString, &modal) == .success,
               modal as? Bool == true { return .confirmationRequired }
        }
        return .open
    }

    func requestClose() -> String? {
        guard AXIsProcessTrusted() else { return "창 닫기에 접근성 권한이 필요합니다. 설정 점검 → 권한에서 확인해 주세요." }
        guard !application.isTerminated else { return "선택한 앱이 이미 종료되었습니다." }
        AXUIElementSetMessagingTimeout(window, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return "이 창의 닫기 버튼을 사용할 수 없습니다. 앱에서 직접 닫아 주세요."
        }
        let button = value as! AXUIElement
        AXUIElementSetMessagingTimeout(button, 0.3)
        var enabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &enabled) == .success,
              enabled as? Bool == true else {
            return "이 창의 닫기 버튼이 비활성화되어 있습니다. 앱의 대화상자를 먼저 확인해 주세요."
        }
        // Close the exact window without activating it or hiding the switcher.
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return "창 닫기 요청의 처리 여부를 확인하지 못했습니다. 앱의 창이나 저장 확인창을 확인해 주세요."
        }
        return nil
    }
}
