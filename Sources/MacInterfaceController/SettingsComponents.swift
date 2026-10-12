import SwiftUI

struct SettingsPage<Content: View>: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @ViewBuilder let content: () -> Content
    var body: some View {
        let _ = uiLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 22, content: content)
                .frame(maxWidth: 860, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct SettingsCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            configuration.label.font(.body).foregroundStyle(.secondary)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
    }
}

struct SettingsPageHeader: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    let title: String
    var symbol: String? = nil
    var help: String? = nil
    var body: some View {
        let _ = uiLanguage
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(L10n.text(title)).font(.system(size: 26, weight: .regular))
            if let help {
                Spacer()
                HelpButton(title: title, text: help)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 2)
    }
}

struct ShortcutBadge: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    let keys: String
    var body: some View {
        let _ = uiLanguage
        Text(keys).font(.system(.callout, design: .monospaced).weight(.regular))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
    }
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.korean.rawValue
    var body: some View {
        let _ = uiLanguage
        Picker("언어 / Language", selection: $language) {
            Text("한국어").tag(AppLanguage.korean.rawValue)
            Text("English").tag(AppLanguage.english.rawValue)
        }.pickerStyle(.segmented).labelsHidden()
    }
}

struct SettingsToggleRow: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    let title: String
    var detail = ""
    let symbol: String
    @Binding var isOn: Bool
    var showsDetailInline = false
    var body: some View {
        let _ = uiLanguage
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 26)
            Text(L10n.text(title)).font(.body.weight(.regular)).fixedSize(horizontal: false, vertical: true)
            if showsDetailInline { ShortcutBadge(keys: detail) }
            else if !detail.isEmpty { HelpButton(title: title, text: detail) }
            Spacer(minLength: 12)
            Toggle(L10n.text(title), isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }.padding(.vertical, 10)
    }
}

struct SettingsNotice: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    let title: String
    let detail: String
    var symbol = "info.circle.fill"
    var color: Color = .orange
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        let _ = uiLanguage
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(.body)
                if !detail.isEmpty {
                    Text(L10n.text(detail)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let actionTitle, let action {
                    Button(L10n.text(actionTitle), action: action).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One actionable readiness message everywhere, instead of independent warnings per feature.
struct MappingReadinessNotice: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigation
    var body: some View {
        let _ = uiLanguage
        if !settings.sessionReady {
            SettingsNotice(title: "시작 전 백업 확인 필요", detail: settings.historyError ?? "", actionTitle: "백업 확인", action: { navigation.openCheck(.setup) })
        } else if !settings.engineEnabled {
            SettingsNotice(title: "설정이 일시 중지되었습니다", detail: "", symbol: "pause.circle.fill", color: .secondary)
        } else if settings.setupPhase != .ready {
            SettingsNotice(title: "키 매핑을 시작하려면 초기 설정이 필요합니다", detail: "기존 macOS 키 설정을 백업하고 기본값으로 전환하세요. Shift+Space 한/영 전환은 지금도 사용할 수 있습니다.",
                           actionTitle: "초기 설정으로 이동", action: { navigation.openCheck(.setup) })
        } else if settings.requiresInputPermissions && (!settings.accessibilityGranted || !settings.inputMonitoringGranted) {
            SettingsNotice(title: "키 매핑에 필요한 권한을 확인해 주세요", detail: "", symbol: "hand.raised.fill",
                           actionTitle: "권한 확인", action: { navigation.openCheck(.permissions) })
        } else if let error = settings.remappingError {
            SettingsNotice(title: "일부 설정을 적용하지 못했습니다", detail: error,
                           actionTitle: "설정 점검", action: { navigation.openCheck(.permissions) })
        }
    }
}

struct HelpButton: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    var title = "도움말"
    let text: String
    @State private var showing = false
    var body: some View {
        let _ = uiLanguage
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L10n.text(title))
        .accessibilityLabel(L10n.text("\(title) 도움말"))
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text(title)).font(.body)
                Text(L10n.text(text)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(width: 340, alignment: .leading)
        }
    }
}
