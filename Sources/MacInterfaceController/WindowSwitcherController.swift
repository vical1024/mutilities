import AppKit
import ApplicationServices
import SwiftUI

private struct WindowTarget {
    let display: WindowDisplayItem
    let application: NSRunningApplication
    let element: AXUIElement
    var tab: AXUIElement? = nil
}

struct WindowDisplayItem: Identifiable {
    let id = UUID()
    let applicationName: String
    let windowTitle: String
    let icon: NSImage
    let isMinimized: Bool
    var isTab = false

    static func isChromium(_ bundleIdentifier: String?) -> Bool {
        let chromium = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser"]
        guard let bundleIdentifier else { return false }
        return chromium.contains { bundleIdentifier.hasPrefix($0) }
    }

    /// "Google Chrome" + "Logan (sonatus)" -> "Chrome | Logan (sonatus)".
    static func name(appName: String, profile: String?) -> String {
        guard let profile else { return appName }
        return "\(appName.replacingOccurrences(of: "Google ", with: "")) | \(profile)"
    }

    /// Chromium browsers append " - <Browser> - <Profile>" to the window title once more than one profile exists.
    static func splitProfile(title: String, appName: String, bundleIdentifier: String?) -> (title: String, profile: String?) {
        guard isChromium(bundleIdentifier) else { return (title, nil) }
        for dash in [" - ", " – "] {
            let marker = "\(dash)\(appName)\(dash)"
            if let range = title.range(of: marker, options: .backwards) {
                let profile = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !profile.isEmpty else { continue }
                return (String(title[..<range.lowerBound]), profile)
            }
        }
        return (title, nil)
    }

    /// Chromium appends hover-card details such as " - Memory usage - 243 MB" to the tab's accessible title.
    static func cleanTabTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #" - (Memory usage|메모리 사용량) - .*$"#, with: "", options: .regularExpression)
    }
}

final class WindowSwitcherViewModel: ObservableObject {
    @Published var windows: [WindowDisplayItem] = []
    @Published var selectedIndex = 0
    @Published var closingIDs: Set<UUID> = []
    @Published var notice: String?
    @Published var isCommitting = false
    var selectedID: UUID? { windows.indices.contains(selectedIndex) ? windows[selectedIndex].id : nil }

    func removeWindow(id: UUID) {
        let selected = selectedID
        let oldIndex = selectedIndex
        windows.removeAll { $0.id == id }
        closingIDs.remove(id)
        if let selected, let index = windows.firstIndex(where: { $0.id == selected }) { selectedIndex = index }
        else { selectedIndex = min(oldIndex, max(0, windows.count - 1)) }
    }

    func reset() {
        windows = []
        selectedIndex = 0
        closingIDs = []
        notice = nil
        isCommitting = false
    }
}

protocol WindowSwitching: AnyObject {
    var isVisible: Bool { get }
    func showOrCycle(reverse: Bool)
    func commitSelection()
    func closeSelection()
    func cancel()
}

final class WindowSwitcherController: WindowSwitching {
    static let shared = WindowSwitcherController()

    private let model = WindowSwitcherViewModel()
    private var targets: [WindowTarget] = []
    private var panel: NSPanel?
    private var presentationID = UUID()
    private var transitionID = UUID()
    let focusController = WindowFocusController()
    let closeController = WindowCloseController()

    var isVisible: Bool { panel?.isVisible == true }

    private init() {}

    func showOrCycle(reverse: Bool) {
        focusController.cancel()
        if isVisible {
            if model.isCommitting { transitionID = UUID(); model.isCommitting = false }
            model.selectedIndex = Self.nextIndex(
                current: model.selectedIndex,
                count: targets.count,
                reverse: reverse
            )
            return
        }

        presentationID = UUID()
        closeController.cancel()
        model.reset()
        targets = enumerateWindows()
        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }
        model.windows = targets.map(\.display)
        model.selectedIndex = targets.count > 1 ? (reverse ? targets.count - 1 : 1) : 0
        showPanel()
    }

    func commitSelection() {
        guard !model.isCommitting else { return }
        guard targets.indices.contains(model.selectedIndex) else { cancel(); return }
        let target = targets[model.selectedIndex]
        guard !model.closingIDs.contains(target.display.id) else { return }
        let id = presentationID
        let transition = UUID()
        transitionID = transition
        model.isCommitting = true
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.presentationID == id, self.transitionID == transition, self.model.isCommitting else { return }
            self.closeController.cancel()
            self.hidePanel()
            self.focusController.activate(LiveWindowFocusBackend(application: target.application, window: target.element, tab: target.tab))
            self.targets = []
            self.model.reset()
        }
    }

    private func selectAndCommit(id: UUID) {
        guard let index = targets.firstIndex(where: { $0.display.id == id }) else { return }
        model.selectedIndex = index
        commitSelection()
    }

    func closeSelection() {
        guard targets.indices.contains(model.selectedIndex) else { return }
        guard !targets[model.selectedIndex].display.isTab else {
            model.notice = "탭은 창 전환기에서 닫을 수 없습니다."
            return
        }
        closeWindow(id: targets[model.selectedIndex].display.id)
    }

    private func closeWindow(id: UUID) {
        guard isVisible, !model.isCommitting, !model.closingIDs.contains(id),
              let target = targets.first(where: { $0.display.id == id }) else { return }
        focusController.cancel()
        model.notice = nil
        model.closingIDs.insert(id)
        let session = presentationID
        closeController.close(LiveWindowCloseBackend(application: target.application, window: target.element), id: id) { [weak self] result in
            guard let self, self.presentationID == session, self.isVisible else { return }
            self.model.closingIDs.remove(id)
            switch result {
            case .closed:
                let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.22)
                withAnimation(animation) {
                    self.targets.removeAll { $0.display.id == id }
                    self.model.removeWindow(id: id)
                }
            case .keptOpen(let message), .failed(let message): self.model.notice = message
            }
        }
    }

    func cancel() {
        presentationID = UUID()
        closeController.cancel()
        focusController.cancel()
        hidePanel()
        targets = []
        model.reset()
    }

    static func nextIndex(current: Int, count: Int, reverse: Bool) -> Int {
        guard count > 0 else { return 0 }
        return reverse ? (current - 1 + count) % count : (current + 1) % count
    }

    private func showPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let availableHeight = max(320, (screen?.visibleFrame.height ?? 800) - 120)
        let desiredHeight = CGFloat(targets.count) * 66 + 152
        let size = NSSize(width: 460, height: min(availableHeight, max(250, desiredHeight)))

        let panel = self.panel ?? makePanel()
        panel.setContentSize(size)
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: WindowSwitcherOverlay(model: model,
            closeWindow: { [weak self] id in self?.closeWindow(id: id) },
            selectWindow: { [weak self] id in self?.selectAndCommit(id: id) }))
        return panel
    }

    private var manualAccessibilityPIDs: Set<pid_t> = []

    private func enumerateWindows() -> [WindowTarget] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let frontOrder = frontmostProcessOrder()
        var results: [WindowTarget] = []
        var inactiveTabs: [WindowTarget] = []

        for application in applications {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            // Chromium and Electron (Slack, ...) only publish their windows after a client asks for the accessibility tree.
            if manualAccessibilityPIDs.insert(application.processIdentifier).inserted {
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            for element in axWindows(of: appElement) {
                let role = stringAttribute(element, kAXRoleAttribute as CFString)
                let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
                guard role == (kAXWindowRole as String),
                      subrole == nil || subrole == (kAXStandardWindowSubrole as String) else { continue }

                let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? "제목 없는 창"
                let minimized = boolAttribute(element, kAXMinimizedAttribute as CFString)
                let appName = application.localizedName ?? "알 수 없는 앱"
                let split = WindowDisplayItem.splitProfile(title: title, appName: appName, bundleIdentifier: application.bundleIdentifier)
                let icon = application.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
                let displayName = WindowDisplayItem.name(appName: appName, profile: split.profile)
                results.append(WindowTarget(
                    display: WindowDisplayItem(
                        applicationName: displayName,
                        windowTitle: split.title.isEmpty ? "제목 없는 창" : split.title,
                        icon: icon,
                        isMinimized: minimized
                    ),
                    application: application,
                    element: element
                ))
                guard split.profile != nil || WindowDisplayItem.isChromium(application.bundleIdentifier) else { continue }
                for tab in chromiumTabs(in: element) where !tab.isActive {
                    inactiveTabs.append(WindowTarget(
                        display: WindowDisplayItem(
                            applicationName: displayName,
                            windowTitle: tab.title.isEmpty ? "제목 없는 탭" : tab.title,
                            icon: icon,
                            isMinimized: minimized,
                            isTab: true
                        ),
                        application: application,
                        element: element,
                        tab: tab.element
                    ))
                }
            }
        }

        // Each window's active tab keeps its recency order; the other tabs follow so ⌥Tab still toggles between windows.
        let sorted = results.sorted {
            let left = frontOrder[$0.application.processIdentifier] ?? Int.max
            let right = frontOrder[$1.application.processIdentifier] ?? Int.max
            return left < right
        }
        return sorted + inactiveTabs
    }

    /// Chromium exposes each tab as an AXTabButton radio button; the selected one has value 1.
    private func chromiumTabs(in window: AXUIElement) -> [(element: AXUIElement, title: String, isActive: Bool)] {
        AXUIElementSetMessagingTimeout(window, 0.25)
        var tabs: [(element: AXUIElement, title: String, isActive: Bool)] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute as CFString)
            if role == "AXRadioButton", stringAttribute(element, kAXSubroleAttribute as CFString) == "AXTabButton" {
                var value: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                let title = WindowDisplayItem.cleanTabTitle(stringAttribute(element, kAXTitleAttribute as CFString) ?? "")
                tabs.append((element, title, (value as? NSNumber)?.intValue == 1))
                continue
            }
            guard depth < 9, role != "AXWebArea" else { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let array = children as? [AXUIElement] else { continue }
            queue.append(contentsOf: array.map { ($0, depth + 1) })
        }
        return tabs
    }

    private func frontmostProcessOrder() -> [pid_t: Int] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        var order: [pid_t: Int] = [:]
        for item in info {
            guard let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidValue = item[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidValue.int32Value)
            if order[pid] == nil { order[pid] = order.count }
        }
        return order
    }

    private func axWindows(of application: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success, let value else { return [] }
        let array = value as! CFArray
        return (array as NSArray).map { $0 as! AXUIElement }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
        return value as? Bool ?? false
    }
}

private struct WindowSwitcherOverlay: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @ObservedObject var model: WindowSwitcherViewModel
    let closeWindow: (UUID) -> Void
    let selectWindow: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        let _ = uiLanguage
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("창 전환")).font(.body)
                Spacer()
                Text(L10n.text("⌥Tab / ←→ 선택  ·  ⌥ 떼면 열기")).font(.caption).foregroundStyle(.white.opacity(0.58))
            }.foregroundStyle(.white.opacity(0.92)).padding(.horizontal, 6)
            Text(L10n.text("W 닫기  ·  Esc 취소")).font(.caption).foregroundStyle(.white.opacity(0.58)).padding(.horizontal, 6)
            if model.windows.isEmpty {
                Text(L10n.text("열린 창이 없습니다")).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: model.windows.count > 5) {
                        LazyVStack(spacing: 7) {
                            ForEach(model.windows) { window in
                                WindowSwitcherCard(item: window, selected: window.id == model.selectedID,
                                    closing: model.closingIDs.contains(window.id), selection: selection,
                                    close: { closeWindow(window.id) }, select: { selectWindow(window.id) })
                                    .id(window.id)
                                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity,
                                        removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.96))))
                            }
                        }.padding(6)
                        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.9), value: model.selectedID)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            if let notice = model.notice {
                Text(L10n.text(notice)).font(.caption).foregroundStyle(.orange).lineLimit(3).padding(.horizontal, 6)
            }
        }
        .padding(14)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.15)))
        .padding(8)
        .scaleEffect(model.isCommitting && !reduceMotion ? 0.97 : 1)
        .opacity(model.isCommitting ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.isCommitting)
    }
}

private struct WindowSwitcherCard: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    let item: WindowDisplayItem
    let selected: Bool
    let closing: Bool
    let selection: Namespace.ID
    let close: () -> Void
    let select: () -> Void

    var body: some View {
        let _ = uiLanguage
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(nsImage: item.icon).resizable().scaledToFit().frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(item.applicationName).font(.callout.weight(.regular))
                            if item.isMinimized { Image(systemName: "minus.square") }
                        }
                        Text(item.windowTitle).font(.caption).lineLimit(1).foregroundStyle(.white.opacity(0.68))
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "return").font(.caption).opacity(selected ? 0.82 : 0)
                }.frame(maxWidth: .infinity, minHeight: 58).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(closing)
            if !item.isTab {
                Button(action: close) {
                    Image(systemName: closing ? "ellipsis" : "xmark").font(.system(size: 11, weight: .regular))
                        .frame(width: 26, height: 26).background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain).disabled(closing)
                .help(L10n.text(closing ? "창 닫기 확인 중" : "창 닫기"))
                .accessibilityLabel(L10n.text("\(item.applicationName) · \(item.windowTitle) 창 닫기"))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.1))
            if selected {
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.8), lineWidth: 2))
                    .matchedGeometryEffect(id: "selected-window", in: selection)
            }
        }
        .opacity(closing ? 0.55 : 1)
    }
}
