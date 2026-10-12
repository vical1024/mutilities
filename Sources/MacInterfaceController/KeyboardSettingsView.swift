import SwiftUI

struct KeyboardSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigation
    @State private var expandedID: UUID?
    @State private var showFinder = false

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
