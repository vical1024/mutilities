import SwiftUI

struct SystemResetView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @State private var name = ""
    @State private var selectedID: UUID?
    @State private var confirmingRestore = false
    @State private var confirmingReset = false
    @State private var legacyBackups = SystemDefaultsService.backupURLs()
    @State private var legacyURL: URL?
    @State private var confirmingLegacy = false

    var body: some View {
        let _ = uiLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(L10n.text("macOS 기본값 · 권장")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.text(settings.setupPhase == .ready ? "기본값 확인 완료" : "기본값 확인 필요"))
                            Spacer()
                            HelpButton(title: "macOS 기본값 유지 권장", text: "다른 입력 앱이 켜져 있으면 지운 설정이 다시 생길 수 있습니다. 보조 키 변경은 로그아웃·로그인 후 적용될 수 있습니다. 시작 전 값은 이 앱을 종료할 때 복원합니다.")
                        }
                        HStack {
                            Button(L10n.text("백업 후 기본값 전환")) { confirmingReset = true }.disabled(!settings.sessionReady)
                            if settings.setupPhase == .awaitingVerification {
                                Button(L10n.text("로그아웃 후 기본값 확인 완료")) { Task { await settings.confirmDefaults() } }
                            }
                        }
                    }.padding(8)
                }
                GroupBox(L10n.text("자동 백업·복원")) {
                    HStack {
                        Label(L10n.text(settings.sessionReady ? "시작 전 백업 완료" : "시작 전 백업 확인 필요"), systemImage: settings.sessionReady ? "checkmark.shield" : "exclamationmark.shield")
                        Spacer()
                        Text(L10n.text("최근 15회차")).font(.caption).foregroundStyle(.secondary)
                        HelpButton(title: "자동 백업·복원", text: "완료된 시작·종료 회차 중 최근 15개만 보관합니다. 수동·복원 직전 백업은 자동 삭제하지 않습니다. 비정상 종료로 남은 백업은 다음 실행에서 먼저 복구합니다.")
                    }.padding(8)
                }
                GroupBox(L10n.text("시점 백업")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            TextField(L10n.text("백업 이름 (선택)"), text: $name).textFieldStyle(.roundedBorder)
                            Button(L10n.text("현재 설정 백업")) { Task { await settings.createCheckpoint(name: name); name = "" } }
                                .disabled(!settings.sessionReady)
                            HelpButton(title: "시점 백업 범위", text: "앱 설정과 이 앱이 관리하는 macOS 설정을 보관합니다. 실제 창 위치·권한 승인은 포함하지 않습니다. 선택한 시점을 복원하면 그 시점이 이후 종료 복원의 기준이 됩니다. 복원 직전 상태도 별도로 남깁니다.")
                        }
                        Picker(L10n.text("복원 시점"), selection: $selectedID) {
                            Text(L10n.text("백업 선택")).tag(nil as UUID?)
                            ForEach(settings.history) { snapshot in
                                Text(L10n.text("\(snapshot.createdAt.formatted(date: .abbreviated, time: .standard)) · \(kind(snapshot)) · \(snapshot.name)")).tag(Optional(snapshot.id))
                            }
                        }
                        HStack {
                            Button(L10n.text("선택한 시점 복원")) { confirmingRestore = true }.disabled(selectedID == nil || !settings.sessionReady)
                            Button(L10n.text("백업 폴더 열기")) { Task { NSWorkspace.shared.open(await SettingsHistory.shared.directory()) } }
                            Spacer()

                        }
                    }.padding(8)
                }
                if !legacyBackups.isEmpty {
                    DisclosureGroup(L10n.text("이전 버전 시스템 백업")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(L10n.text("백업"), selection: $legacyURL) {
                                Text(L10n.text("선택하세요")).tag(nil as URL?)
                                ForEach(legacyBackups, id: \.self) { Text(L10n.text($0.deletingPathExtension().lastPathComponent)).tag(Optional($0)) }
                            }
                            Button(L10n.text("이전 시스템 백업 복원")) { confirmingLegacy = true }.disabled(legacyURL == nil || !settings.sessionReady)
                        }.padding(8)
                    }
                }
                if let message = settings.historyMessage { Label(L10n.text(message), systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let error = settings.historyError ?? settings.setupError ?? settings.systemState?.error {
                    SettingsNotice(title: "백업·복원 확인 필요", detail: error)
                }
                if let warnings = settings.systemState?.warnings, !warnings.isEmpty {
                    SettingsNotice(title: "접근 제한으로 제외된 항목 \(warnings.count)개", detail: warnings.joined(separator: "\n"))
                }
            }.frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await settings.refreshHistory(); await settings.refreshSystemState() }
        .confirmationDialog(L10n.text("선택한 시점으로 복원할까요?"), isPresented: $confirmingRestore) {
            Button(L10n.text("복원")) { if let selectedID { Task { await settings.restoreCheckpoint(selectedID) } } }
        } message: { Text(L10n.text("현재 설정도 별도로 백업한 뒤 앱 설정과 관리 대상 macOS 설정을 복원합니다.")) }
        .confirmationDialog(L10n.text("백업 후 macOS 기본값으로 전환할까요?"), isPresented: $confirmingReset) {
            Button(L10n.text("기본값 전환")) { Task { await settings.prepareSystem(); legacyBackups = SystemDefaultsService.backupURLs() } }
        }
        .confirmationDialog(L10n.text("이전 시스템 백업을 복원할까요?"), isPresented: $confirmingLegacy) {
            Button(L10n.text("복원")) { if let legacyURL { Task { await settings.restoreSystem(from: legacyURL) } } }
        }
    }
    private func kind(_ snapshot: SettingsSnapshot) -> String {
        switch snapshot.kind { case .automatic: L10n.text("자동"); case .manual: L10n.text("수동"); case .beforeRestore: L10n.text("복원 직전") }
    }
}
