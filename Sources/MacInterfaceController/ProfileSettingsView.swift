import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ProfileSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @State private var pendingProfile: PortableProfile?
    @State private var message: String?
    @State private var error: String?
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        let _ = uiLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPageHeader(title: "앱 설정", symbol: "gearshape")
                GroupBox(L10n.text("언어")) {
                    HStack {
                        Text(L10n.text("앱 표시 언어"))
                        Spacer()
                        LanguagePicker().frame(width: 230)
                    }.padding(.vertical, 6)
                }
                GroupBox(L10n.text("실행")) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggleRow(title: "로그인 시 자동 실행", symbol: "power", isOn: Binding(
                            get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: setLoginEnabled
                        )).disabled(!settings.sessionReady || settings.isWorking)
                        if loginStatus == .requiresApproval {
                            SettingsNotice(title: "로그인 항목 허용이 필요합니다", detail: "", actionTitle: "로그인 항목 열기", action: { SMAppService.openSystemSettingsLoginItems() })
                        }

                    }.padding(8)
                }
                GroupBox(L10n.text("설정 파일")) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Button(L10n.text("내보내기"), systemImage: "square.and.arrow.up") { exportProfile() }
                            Button(L10n.text("가져오기"), systemImage: "square.and.arrow.down") { chooseProfile() }
                            HelpButton(title: "프로필 내보내기", text: "디스플레이·Dock·언어·로그인 실행과 macOS 설정은 이 파일에 포함되지 않습니다. 키보드·단축키·창 관리·핫 코너 설정을 옮길 수 있습니다.")
                        }.disabled(settings.isWorking)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message { SettingsNotice(title: "완료", detail: message, symbol: "checkmark.circle.fill", color: .green) }
                if let error { SettingsNotice(title: "설정을 확인해 주세요", detail: error) }
            }.frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
        .confirmationDialog(L10n.text("가져온 설정으로 현재 앱 설정을 바꿀까요?"), isPresented: Binding(
            get: { pendingProfile != nil }, set: { if !$0 { pendingProfile = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.text("설정 가져오기")) {
                guard let profile = pendingProfile else { return }
                do {
                    try settings.importProfile(profile)
                    message = "설정을 가져왔습니다. 적용 상태와 충돌 검사 결과를 확인해 주세요."
                } catch { self.error = error.localizedDescription }
                pendingProfile = nil
            }
        } message: {
            if let profile = pendingProfile {
                Text(L10n.text("\(profile.name) · 단축키 \(profile.shortcuts.count)개 · Hot Corner \(profile.corners.filter(\.isEnabled).count)개. 현재 설정은 자동 백업됩니다."))
            }
        }
    }

    private func exportProfile() {
        message = nil; error = nil
        do {
            let data = try settings.profile.encoded()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "My-Key-Settings.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            message = "설정을 내보냈습니다: \(url.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }

    private func chooseProfile() {
        message = nil; error = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else {
                throw ProfileError.invalid("설정 파일이 너무 큽니다.")
            }
            pendingProfile = try PortableProfile.decode(Data(contentsOf: url))
        }
        catch { self.error = error.localizedDescription }
    }

    private func setLoginEnabled(_ enabled: Bool) {
        guard settings.sessionReady, !settings.isWorking else { return }
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "로그인 실행 설정 실패: \(error.localizedDescription). 빌드된 .app에서 실행해 주세요." }
        loginStatus = SMAppService.mainApp.status
    }
}
