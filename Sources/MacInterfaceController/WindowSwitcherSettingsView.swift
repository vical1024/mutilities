import SwiftUI

struct WindowSwitcherSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigation
    @ObservedObject private var closeController = WindowSwitcherController.shared.closeController
    @ObservedObject private var focusController = WindowSwitcherController.shared.focusController
    @ObservedObject private var layoutController = WindowLayoutController.shared
    @State private var expandedID: UUID?
    @State private var showGuide = false

    var body: some View {
        let _ = uiLanguage
        SettingsPage {
            SettingsPageHeader(title: "창 관리", symbol: "rectangle.on.rectangle")
            MappingReadinessNotice()
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsToggleRow(title: "창 전환 사용", detail: "⌃Tab", symbol: "rectangle.on.rectangle",
                                      isOn: $settings.windowSwitcherEnabled, showsDetailInline: true)
                    DisclosureGroup(L10n.text("조작 키 보기"), isExpanded: $showGuide) {
                        VStack(spacing: 12) {
                            shortcut("⌃Tab", action: "다음 창")
                            shortcut("⌃⇧Tab", action: "이전 창")
                            shortcut("↑ / ↓", action: "목록에서 선택")
                            shortcut("Enter", action: "선택한 창 열기")
                            shortcut("W / ×", action: "선택한 창 닫기")
                            shortcut("Esc", action: "취소")
                        }.padding(.top, 12)
                    }
                }
            }
            if let error = closeController.lastError { SettingsNotice(title: "창 닫기 확인 필요", detail: error) }
            if let error = focusController.lastError {
                SettingsNotice(title: "창 전환 확인 필요", detail: error, actionTitle: "권한 확인", action: { navigation.openCheck(.permissions) })
            }
            if !EngineConflictDetector.windowSwitcherIssues(shortcuts: settings.shortcuts, enabled: settings.windowSwitcherEnabled).isEmpty {
                SettingsNotice(title: "창 전환 단축키가 겹칩니다", detail: "Control+Tab 또는 Control+Shift+Tab이 다른 단축키에도 지정되어 있습니다.", actionTitle: "충돌 검사", action: { navigation.openCheck(.conflicts) })
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    FeatureGroupHeader(title: "창 배치", isEnabled: hasEnabledLayouts) { enabled in
                        var rules = settings.shortcuts
                        for index in rules.indices where rules[index].templateID != nil && rules[index].action.isWindowLayout { rules[index].isEnabled = enabled }
                        settings.shortcuts = rules
                    }
                    Divider()
                    ForEach(KeyboardTemplates.actions.filter(\.isWindowLayout)) { action in
                        if let index = settings.shortcuts.firstIndex(where: { $0.templateID == action.rawValue }) {
                            let id = settings.shortcuts[index].id
                            ShortcutRuleRow(rule: $settings.shortcuts[index], expanded: Binding(get: { expandedID == id }, set: { expandedID = $0 ? id : nil }), delete: {})
                        }
                    }
                }
            }
            if let error = layoutController.lastError { SettingsNotice(title: "창 배치 확인 필요", detail: error) }
            if !settings.accessibilityGranted && settings.shortcuts.contains(where: { $0.isEnabled && $0.action.isWindowLayout }) {
                SettingsNotice(title: "창 관리에 접근성 권한이 필요합니다", detail: "다른 앱의 창 위치와 크기를 변경하는 데 사용합니다.", actionTitle: "권한 확인", action: { navigation.openCheck(.permissions) })
            }
        }
    }
    private var hasEnabledLayouts: Bool { settings.shortcuts.contains { $0.templateID != nil && $0.action.isWindowLayout && $0.isEnabled } }
    private func shortcut(_ keys: String, action: String) -> some View {
        HStack { Text(L10n.text(action)); Spacer(); ShortcutBadge(keys: keys) }
    }
}
