import SwiftUI

struct DisplaySettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var controller = DisplayController.shared

    var body: some View {
        let _ = uiLanguage
        SettingsPage {
            SettingsPageHeader(title: "디스플레이", symbol: "display")
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsToggleRow(title: "외장 모니터 연결 시 내장 화면 끄기", symbol: "display.2", isOn: $settings.autoDisableBuiltInDisplay)
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: controller.builtInOn == false ? "laptopcomputer.slash" : "laptopcomputer")
                            .foregroundStyle(.secondary).frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text(status))
                            Text(L10n.text("활성 외장 화면 \(controller.externalCount)개")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HelpButton(title: "화면 복구", text: "외장 화면 연결을 해제하거나 이 스위치를 끄면 내장 화면을 켭니다. 앱 종료 시에도 자동 복구합니다.")
                    }
                    if !settings.engineEnabled && settings.autoDisableBuiltInDisplay {
                        Label(L10n.text("앱 설정이 꺼져 있어 자동 전환이 일시 중지되었습니다."), systemImage: "pause.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = controller.error {
                SettingsNotice(title: "화면 전환 확인 필요", detail: error,
                               actionTitle: canRetry ? "다시 시도" : nil,
                               action: canRetry ? { controller.retry() } : nil)
            }
        }
    }
    private var canRetry: Bool { settings.autoDisableBuiltInDisplay && settings.engineEnabled && settings.sessionReady }
    private var status: String {
        if controller.isStopping { return "내장 화면 복구 중" }
        if controller.error != nil { return "자동 전환 중지 · 확인 필요" }
        if controller.isRunning { return controller.builtInOn == false ? "내장 화면 꺼짐 · 외장 화면 사용 중" : "내장 화면 켜짐 · 외장 연결 대기" }
        if settings.autoDisableBuiltInDisplay && settings.engineEnabled { return "자동 전환 준비 중" }
        return controller.builtInOn == true ? "내장 화면 켜짐" : "내장 화면 자동 전환 꺼짐"
    }
}
