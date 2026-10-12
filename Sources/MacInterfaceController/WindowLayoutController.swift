import AppKit
import ApplicationServices

extension AppAction {
    var isWindowLayout: Bool {
        switch self {
        case .windowLeft, .windowRight, .windowMaximize, .windowRestore, .windowCenter, .windowCenterHeight: true
        default: false
        }
    }
}

enum WindowLayoutGeometry {
    /// Both full and visible screen frames must use the same AX (top-left) coordinates.
    static func accessibilityFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func screenIndex(for window: CGRect, screens: [CGRect]) -> Int? {
        screens.indices.max { a, b in
            let areaA = intersectionArea(window, screens[a])
            let areaB = intersectionArea(window, screens[b])
            if areaA != areaB { return areaA < areaB }
            return distance(window, screens[a]) > distance(window, screens[b])
        }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func distance(_ window: CGRect, _ screen: CGRect) -> CGFloat {
        let dx = max(screen.minX - window.midX, 0, window.midX - screen.maxX)
        let dy = max(screen.minY - window.midY, 0, window.midY - screen.maxY)
        return dx * dx + dy * dy
    }

    static func target(_ action: AppAction, current: CGRect, visible: CGRect, heightPercent: Double = 95, widthPercent: Double? = nil) -> CGRect {
        switch action {
        case .windowLeft:
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case .windowRight:
            return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case .windowMaximize: return visible
        case .windowCenter:
            return CGRect(x: visible.midX - current.width / 2, y: visible.midY - current.height / 2,
                          width: current.width, height: current.height)
        case .windowCenterHeight:
            let percent = heightPercent.isFinite ? min(100, max(30, heightPercent)) : 95
            let width: CGFloat
            if let widthPercent, widthPercent.isFinite { width = visible.width * CGFloat(min(100, max(30, widthPercent))) / 100 }
            else { width = min(current.width, visible.width) }
            let size = CGSize(width: width, height: visible.height * percent / 100)
            return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)
        default: return current
        }
    }

    static func fitted(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
        abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}

enum WindowLayoutPresets {
    static var rules: [ShortcutRule] {
        [(.left, AppAction.windowLeft), (.right, .windowRight), (.up, .windowMaximize),
         (.down, .windowRestore), (.c, .windowCenter), (.enter, .windowCenterHeight)].map { key, action in
            ShortcutRule(key: key, modifiers: [.control, .option], action: action)
        }
    }

    /// Preserve edited rules and disable only new combinations already in use.
    static func addingMissing(to existing: [ShortcutRule]) -> [ShortcutRule] {
        var result = existing
        for var rule in rules where !existing.contains(where: { $0.action == rule.action }) {
            rule.isEnabled = !result.contains { $0.isEnabled && $0.key == rule.key && $0.modifiers == rule.modifiers }
            result.append(rule)
        }
        return result
    }
}

@MainActor
final class WindowLayoutController: ObservableObject {
    static let shared = WindowLayoutController()
    @Published private(set) var lastError: String?
    private struct SavedWindow {
        let window: AXUIElement
        let original: CGRect
        var applied: CGRect
    }
    private var saved: [SavedWindow] = []

    func run(_ action: AppAction, heightPercent: Double = 95, widthPercent: Double? = nil) {
        guard action.isWindowLayout else { return }
        lastError = nil
        do {
            guard AXIsProcessTrusted() else {
                throw LayoutError("창 배치에 접근성 권한이 필요합니다. 설정 점검 → 권한에서 허용해 주세요.")
            }
            guard let app = NSWorkspace.shared.frontmostApplication else {
                throw LayoutError("배치할 활성 창이 없습니다.")
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            guard let value = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw LayoutError("이 앱에 배치할 활성 창이 없습니다.")
            }
            let window = value as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.3)
            guard attribute(window, "AXFullScreen") as? Bool != true else {
                throw LayoutError("전체 화면을 해제한 뒤 창을 배치해 주세요.")
            }
            let current = try frame(of: window)
            let screens = NSScreen.screens
            guard let primary = screens.first else { throw LayoutError("화면 정보를 읽지 못했습니다.") }
            let frames = screens.map { WindowLayoutGeometry.accessibilityFrame($0.frame, primaryTop: primary.frame.maxY) }
            let visibleFrames = screens.map { WindowLayoutGeometry.accessibilityFrame($0.visibleFrame, primaryTop: primary.frame.maxY) }
            guard let index = WindowLayoutGeometry.screenIndex(for: current, screens: frames) else { return }
            let previous = saved.first { CFEqual($0.window, window) }
            let target: CGRect
            if action == .windowRestore {
                guard let previous else { throw LayoutError("이 창의 저장된 위치가 없습니다. 먼저 창 배치를 실행해 주세요.") }
                let restoreIndex = WindowLayoutGeometry.screenIndex(for: previous.original, screens: frames) ?? index
                target = WindowLayoutGeometry.fitted(previous.original, in: visibleFrames[restoreIndex])
            } else {
                target = WindowLayoutGeometry.target(action, current: current, visible: visibleFrames[index], heightPercent: heightPercent, widthPercent: widthPercent)
            }
            guard isSettable(window, kAXPositionAttribute),
                  (action == .windowCenter || isSettable(window, kAXSizeAttribute)) else {
                throw LayoutError("이 창은 위치 또는 크기 변경을 지원하지 않습니다.")
            }
            // Keep recovery available even if the application accepts only part of a request.
            let original = previous.flatMap { WindowLayoutGeometry.approximatelyEqual($0.applied, current) ? $0.original : nil } ?? current
            if action != .windowRestore {
                saved.removeAll { CFEqual($0.window, window) }
                saved.append(SavedWindow(window: window, original: original, applied: current))
                if saved.count > 64 { saved.removeFirst() }
            }
            do {
                try setFrame(target, of: window, resize: action != .windowCenter)
                let actual = try frame(of: window)
                if let savedIndex = saved.firstIndex(where: { CFEqual($0.window, window) }) { saved[savedIndex].applied = actual }
                guard WindowLayoutGeometry.approximatelyEqual(actual, target) else {
                    throw LayoutError("앱의 최소 크기 또는 창 제한 때문에 요청한 배치를 정확히 적용하지 못했습니다.")
                }
                if action == .windowRestore { saved.removeAll { CFEqual($0.window, window) } }
            } catch {
                if let actual = try? frame(of: window), let savedIndex = saved.firstIndex(where: { CFEqual($0.window, window) }) {
                    saved[savedIndex].applied = actual
                }
                throw error
            }
        } catch {
            lastError = error.localizedDescription
            NSSound.beep()
            NSLog("창 배치 실패: %@", error.localizedDescription)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func isSettable(_ window: AXUIElement, _ name: String) -> Bool {
        var result: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, name as CFString, &result) == .success && result.boolValue
    }

    private func frame(of window: AXUIElement) throws -> CGRect {
        guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw LayoutError("창의 위치와 크기를 읽지 못했습니다.")
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else {
            throw LayoutError("올바른 창 크기를 읽지 못했습니다.")
        }
        return CGRect(origin: point, size: dimensions)
    }

    private func setFrame(_ frame: CGRect, of window: AXUIElement, resize: Bool) throws {
        var point = frame.origin, size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw LayoutError("창 배치 값을 만들지 못했습니다.")
        }
        // Some apps constrain size using the old location. Reapply after moving.
        if resize { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = resize ? AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) : .success
        let finalPositionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        guard (positionResult == .success || finalPositionResult == .success), sizeResult == .success else {
            throw LayoutError("앱이 창 배치 요청을 처리하지 못했습니다. 접근성 권한과 창 상태를 확인해 주세요.")
        }
    }

    private struct LayoutError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
