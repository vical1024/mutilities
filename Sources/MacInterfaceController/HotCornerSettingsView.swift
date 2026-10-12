import SwiftUI

struct HotCornerSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let _ = uiLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPageHeader(title: "핫 코너", symbol: "arrow.up.left.and.arrow.down.right", help: "연결된 각 디스플레이의 같은 모서리에 적용됩니다.")
                MappingReadinessNotice()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach($settings.corners) { $rule in
                        CornerCard(rule: $rule)
                    }
                }

            }
            .frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct CornerCard: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @Binding var rule: HotCornerRule

    var body: some View {
        let _ = uiLanguage
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: rule.position.symbol)
                    .font(.title2)
                    .foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
                Text(L10n.text(rule.position.title)).font(.body)
                Spacer()
                Toggle(L10n.text("\(rule.position.title) 사용"), isOn: $rule.isEnabled).labelsHidden().toggleStyle(.switch)
            }

            Group {
                Picker(L10n.text("동작"), selection: $rule.action) {
                    Section(L10n.text("앱·폴더 열기")) {
                        ForEach([AppAction.finder, .applications, .launchpad]) { action in
                            Label(L10n.text(action.title), systemImage: action.symbol).tag(action)
                        }
                    }
                    Section(L10n.text("창 관리")) {
                        ForEach(AppAction.allCases.filter(\.isWindowLayout)) { action in
                            Label(L10n.text(action.title), systemImage: action.symbol).tag(action)
                        }
                    }
                    Section(L10n.text("시스템 동작")) {
                        ForEach([AppAction.missionControl, .screenSaver, .toggleInputSource]) { action in
                            Label(L10n.text(action.title), systemImage: action.symbol).tag(action)
                        }
                    }
                }

                HStack {
                    Text(L10n.text("머무는 시간"))
                    Spacer()
                    Text(rule.dwellSeconds, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                    Text(L10n.text("초")).foregroundStyle(.secondary)
                }
                Slider(value: $rule.dwellSeconds, in: 0.15...1.0, step: 0.05)
            }.disabled(!rule.isEnabled)
        }

        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
    }
}
