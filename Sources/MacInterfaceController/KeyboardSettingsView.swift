import ServiceManagement
import SwiftUI

struct KeyboardSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigation
    @State private var expandedID: UUID?
    @State private var showFinder = false
    @State private var showEditor = false
    private static let editorKeys: [(String, String)] = [
        ("Home / End", "줄 처음 / 끝으로 (입력창)"), ("Ctrl+Home / End", "문서 처음 / 끝으로 (입력창)"),
        ("Ctrl+← / →", "단어 단위 이동 (입력창)"), ("Ctrl+Page Up / Down", "이전 / 다음 탭")]

    var body: some View {
        let _ = uiLanguage
        SettingsPage {
            SettingsPageHeader(title: "키보드", symbol: "keyboard")
            MappingReadinessNotice()
            if let warning = settings.inputSourceWarning {
                SettingsNotice(title: "입력 소스 확인", detail: warning)
            }
            GroupBox(L10n.text("입력 및 키 동작")) {
                VStack(spacing: 0) {
                    SettingsToggleRow(title: "Control ↔ Command 교환", detail: "교환을 켜면 ⌃는 물리 Command 키, ⌘는 물리 Control 키입니다.", symbol: "arrow.left.arrow.right", isOn: $settings.swapCommandControl)
                    SecureInputSwapNotice().padding(.bottom, 8)
                    Divider()
                    FunctionKeySettingsView()
                }
            }
            ForEach($settings.shortcuts) { $rule in
                if rule.templateID == AppAction.toggleInputSource.rawValue {
                    ShortcutRuleRow(rule: $rule, expanded: Binding(get: { expandedID == rule.id }, set: { expandedID = $0 ? rule.id : nil }), delete: {})
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    FeatureGroupHeader(title: "Windows 스타일 편집", isEnabled: settings.windowsEditorMode) { settings.windowsEditorMode = $0 }
                    DisclosureGroup(L10n.text("조작 키 보기"), isExpanded: $showEditor) {
                        VStack(spacing: 12) {
                            ForEach(Self.editorKeys, id: \.0) { keys, action in
                                HStack { Text(L10n.text(action)); Spacer(); ShortcutBadge(keys: keys) }
                            }
                        }.padding(.top, 8)
                    }
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    FeatureGroupHeader(title: "Windows 스타일 Finder", isEnabled: settings.windowsFinderMode && !settings.finderFeatures.isEmpty) { enabled in
                        settings.finderFeatures = enabled ? Set(FinderFeature.allCases) : []
                        settings.windowsFinderMode = enabled
                    }
                    DisclosureGroup(L10n.text("개별 키 설정"), isExpanded: $showFinder) {
                        VStack(spacing: 0) {
                            ForEach(FinderFeature.allCases) { feature in
                                SettingsToggleRow(title: feature.title, detail: feature.keys, symbol: "folder", isOn: Binding(
                                    get: { settings.windowsFinderMode && settings.finderFeatures.contains(feature) },
                                    set: { enabled in
                                        var features = settings.windowsFinderMode ? settings.finderFeatures : []
                                        if enabled { features.insert(feature) } else { features.remove(feature) }
                                        settings.finderFeatures = features
                                        settings.windowsFinderMode = !features.isEmpty
                                    }
                                ), showsDetailInline: true)
                                if feature != FinderFeature.allCases.last { Divider() }
                            }
                        }.padding(.top, 8)
                    }
                }
            }
        }
    }
}

/// Status of the bundled swap helper, which keeps the Control/Command swap working in password fields.
struct SecureInputSwapNotice: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let _ = uiLanguage
        let helper = SecureInputSwapHelper.shared
        switch settings.swapHelperState {
        case .off:
            EmptyView()
        case .active:
            SettingsNotice(title: "비밀번호 입력창에서도 교환 중", detail: "긴급 해제: 왼쪽 Shift + 오른쪽 Shift + Esc",
                           symbol: "lock.shield.fill", color: .green)
        case .waiting, .starting:
            SettingsNotice(title: "보안 입력 교환 준비 중", detail: "모든 키에서 손을 떼면 시작합니다. 그 전까지는 일반 방식으로 교환합니다.",
                           symbol: "hourglass", color: .secondary)
        case .driverMissing:
            SettingsNotice(title: "비밀번호 입력창에서는 교환되지 않습니다", detail: "Karabiner-DriverKit-VirtualHIDDevice 드라이버를 설치하고 활성화하면 비밀번호 입력창에서도 교환합니다.",
                           actionTitle: "드라이버 다운로드", action: { NSWorkspace.shared.open(SecureInputSwapHelper.driverReleasesURL) })
        case .notRegistered:
            SettingsNotice(title: "비밀번호 입력창에서는 교환되지 않습니다", detail: "보안 입력 교환 헬퍼를 설치하면 비밀번호 입력창에서도 교환합니다.",
                           actionTitle: "헬퍼 설치", action: { helper.register() })
        case .requiresApproval:
            SettingsNotice(title: "헬퍼 실행을 허용해 주세요", detail: "시스템 설정 > 일반 > 로그인 항목 및 확장 프로그램에서 mutilities를 켜 주세요.",
                           actionTitle: "시스템 설정 열기", action: { SMAppService.openSystemSettingsLoginItems() })
        case .inputMonitoringRequired:
            SettingsNotice(title: "헬퍼에 입력 모니터링 권한이 필요합니다", detail: "입력 모니터링 목록에 다음 파일을 추가해 주세요: \(helper.helperPath)",
                           actionTitle: "입력 모니터링 열기", action: { KeyboardRemappingEngine.shared.openInputMonitoringSettings() })
        case .disabledByShortcut:
            SettingsNotice(title: "긴급 해제로 보안 입력 교환이 꺼졌습니다", detail: "지금은 일반 방식으로 교환합니다. 비밀번호 입력창에서는 교환되지 않습니다.",
                           actionTitle: "다시 켜기", action: { helper.reenable() })
        }
    }
}

struct FeatureGroupHeader: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    let title: String
    let isEnabled: Bool
    let setAll: (Bool) -> Void
    var body: some View {
        let _ = uiLanguage
        HStack(spacing: 12) {
            Text(L10n.text(title)).font(.body)
            Spacer()
            Toggle(L10n.text(title), isOn: Binding(get: { isEnabled }, set: setAll))
                .labelsHidden().toggleStyle(.switch)
        }
    }
}
