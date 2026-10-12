import SwiftUI

struct ContentView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigation
    var body: some View {
        let _ = uiLanguage
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section {
                    sidebarRow(.keyboard)
                    sidebarRow(.shortcuts)
                    sidebarRow(.macros)
                } header: { Text(L10n.text("입력")).font(.caption.weight(.regular)) }
                Section {
                    sidebarRow(.windowSwitcher)
                    sidebarRow(.corners)
                    sidebarRow(.dock)
                    sidebarRow(.display)
                } header: { Text(L10n.text("작업 공간")).font(.caption.weight(.regular)) }
                Section {
                    sidebarRow(.checks)
                } header: { Text(L10n.text("관리")).font(.caption.weight(.regular)) }
            }
            .navigationTitle(L10n.text("Mac Controller"))
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.text("설정 활성화"), isOn: $settings.engineEnabled).toggleStyle(.switch)
                        .disabled(settings.isWorking)
                    if !settings.sessionReady && !settings.isWorking {
                        Button(L10n.text("시작 백업 다시 시도")) { Task { await settings.beginSession() } }
                    }
                    Text(L10n.text(settings.statusText)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        } detail: {
            Group {
                switch navigation.selection ?? .keyboard {
                case .keyboard: KeyboardSettingsView()
                case .shortcuts: ShortcutSettingsView()
                case .macros: MacroSettingsView()
                case .windowSwitcher: WindowSwitcherSettingsView()
                case .display: DisplaySettingsView()
                case .dock: DockSettingsView()
                case .corners: HotCornerSettingsView()
                case .checks: CheckSettingsView()
                }
            }
            .disabled(settings.isWorking)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: "app-preferences") } label: { Label(L10n.text("앱 설정"), systemImage: "gearshape") }
                    .help(L10n.text("앱 설정")).keyboardShortcut(",", modifiers: .command)
            }
        }
        .groupBoxStyle(SettingsCardStyle())
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshRemappingPermission()
            Task {
                await settings.refreshSystemState()
                await settings.scanConflicts()
            }
        }
    }
    private func sidebarRow(_ item: SidebarItem) -> some View {
        HStack {
            Label(L10n.text(item.title), systemImage: item.symbol)
            if item == .checks && needsAttention {
                Spacer()
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .accessibilityLabel(L10n.text("확인할 항목 있음"))
            }
        }.font(.body.weight(.regular)).tag(item)
    }
    private var needsAttention: Bool {
        settings.historyError != nil || !settings.sessionReady || settings.setupPhase != .ready || (settings.requiresInputPermissions && (!settings.accessibilityGranted || !settings.inputMonitoringGranted))
            || (settings.conflictReport?.issues.isEmpty == false) || settings.remappingError != nil
            || (!settings.accessibilityGranted && (settings.shortcuts.contains { $0.isEnabled && $0.action.isWindowLayout } || settings.corners.contains { $0.isEnabled && $0.action.isWindowLayout }))
    }
}

struct MenuBarView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigation
    @ObservedObject private var macroRunner = MacroRunner.shared
    @ObservedObject private var windowClose = WindowSwitcherController.shared.closeController
    @ObservedObject private var windowFocus = WindowSwitcherController.shared.focusController
    @ObservedObject private var windowLayout = WindowLayoutController.shared
    @ObservedObject private var display = DisplayController.shared
    var body: some View {
        let _ = uiLanguage
        Text(L10n.text(settings.statusText))
        Toggle(L10n.text("설정 활성화"), isOn: $settings.engineEnabled).disabled(settings.isWorking)
        Divider()
        Button(L10n.text("설정 열기…")) { openSettings(navigation.selection ?? .keyboard) }
        Button(L10n.text("앱 설정…")) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "app-preferences")
        }
        Toggle(L10n.text("내장 화면 자동 끄기"), isOn: $settings.autoDisableBuiltInDisplay)
            .disabled(settings.isWorking)
        if display.error != nil {
            Button(L10n.text("화면 자동 전환 중지 · 확인…")) { openSettings(.display) }
        }
        if settings.historyError != nil || !settings.sessionReady || settings.setupPhase != .ready || (settings.requiresInputPermissions && (!settings.accessibilityGranted || !settings.inputMonitoringGranted)) {
            Button(L10n.text("설정 점검 필요…")) { openSettings(.checks) }
        }
        if windowLayout.lastError != nil {
            Button(L10n.text("창 배치 실패 · 확인…")) { openSettings(.windowSwitcher) }
        }
        if windowClose.lastError != nil {
            Button(L10n.text("창 닫기 확인 필요…")) { openSettings(.windowSwitcher) }
        }
        if windowFocus.lastError != nil {
            Button(L10n.text("창 전환 실패 · 확인…")) { openSettings(.windowSwitcher) }
        }
        if let report = settings.conflictReport, !report.issues.isEmpty {
            Button(L10n.text("충돌 \(report.blockingCount) · 확인 필요 \(report.warningCount)")) {
                navigation.openCheck(.conflicts)
                showWindow()
            }
        }
        Divider()
        if let status = macroRunner.status { Text(L10n.text(status)) }
        if macroRunner.isRunning { Button(L10n.text("매크로 중지 · Esc")) { macroRunner.cancel() } }
        if !settings.shortcuts.filter({ $0.isEnabled && $0.action != .macro }).isEmpty {
        Menu(L10n.text("동작 바로 실행")) {
            ForEach(settings.shortcuts.filter { $0.isEnabled && $0.action != .macro }) { rule in
                let title = rule.action == .toggleApplication && rule.targetApplication.isConfigured
                    ? "\(L10n.text(rule.actionTitle)) · \(rule.targetApplication.displayName)" : L10n.text(rule.actionTitle)
                Button("\(title)  \(rule.displayText)") { ActionRunner.run(rule) }
            }
        }
        }
        Divider()
        Button(L10n.text("종료")) { NSApplication.shared.terminate(nil) }
    }
    private func openSettings(_ item: SidebarItem) { navigation.selection = item; showWindow() }
    private func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }
}
