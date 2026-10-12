import SwiftUI

struct CheckSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var navigation: AppNavigation
    var body: some View {
        let _ = uiLanguage
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(title: "설정 점검", symbol: "checkmark.shield")
                Picker(L10n.text("점검 항목"), selection: Binding(get: { navigation.checkSection }, set: { navigation.openCheck($0) })) {
                    ForEach(CheckSection.allCases) { section in Text(L10n.text(section.title)).tag(section) }
                }.pickerStyle(.segmented).labelsHidden()

            }.frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, -12)
            switch navigation.checkSection {
            case .setup: SystemResetView()
            case .permissions: PermissionSettingsView()
            case .conflicts: ConflictCheckView()
            }
        }
    }
}

struct PermissionSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigation
    var body: some View {
        let _ = uiLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(L10n.text("필수 권한")) {
                    VStack(spacing: 0) {
                        permissionRow("접근성", detail: "키 변환과 매크로 입력, 선택한 창으로 이동합니다.", granted: settings.accessibilityGranted) {
                            _ = KeyboardRemappingEngine.shared.requestAccessibilityPermission()
                            KeyboardRemappingEngine.shared.openAccessibilitySettings()
                        }
                        Divider()
                        permissionRow("입력 모니터링", detail: "키 조합과 매크로 중지 키를 감지합니다.", granted: settings.inputMonitoringGranted) {
                            _ = KeyboardRemappingEngine.shared.requestInputMonitoringPermission()
                            KeyboardRemappingEngine.shared.openInputMonitoringSettings()
                        }
                    }.padding(.horizontal, 8)
                }
                HStack {
                    Label(L10n.text(settings.remappingActive ? "키 매핑 적용 중" : "키 매핑 대기 중"), systemImage: settings.remappingActive ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(settings.remappingActive ? .green : .secondary)
                    Spacer()
                }
                if settings.setupPhase != .ready {
                    SettingsNotice(title: "초기 설정도 완료해 주세요", detail: "",
                                   actionTitle: "초기 설정으로 이동", action: { navigation.openCheck(.setup) })
                }
                if let error = settings.remappingError {
                    SettingsNotice(title: "적용 상태 확인 필요", detail: error)
                }
            }.frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "hand.raised.fill").foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(.body)
                Text(L10n.text(detail)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(L10n.text(granted ? "허용됨" : "허용 필요")).font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("시스템 설정 열기"), action: action)
        }.padding(.vertical, 14)
    }
}
