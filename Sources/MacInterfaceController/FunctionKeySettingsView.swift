import SwiftUI

struct FunctionKeySettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var controller = FunctionKeyController.shared
    var body: some View {
        let _ = uiLanguage
        VStack(alignment: .leading, spacing: 8) {
            SettingsToggleRow(title: "F1–F12를 기본 기능 키로 사용",
                              detail: "Fn(🌐)을 함께 누르면 밝기·음량 등 반대 동작을 사용합니다. 키보드 자체 Fn Lock이 켜져 있으면 적용되지 않을 수 있습니다.",
                              symbol: "keyboard", isOn: Binding(
                                get: { settings.standardFunctionKeys ?? controller.actualStandard ?? false },
                                set: { value in Task { @MainActor in settings.standardFunctionKeys = value } }
                              ))
            if let error = controller.error {
                SettingsNotice(title: "기능 키 확인 필요", detail: error, actionTitle: "다시 시도", action: { settings.apply() })
            }
        }
    }
}
