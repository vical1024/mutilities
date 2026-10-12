import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var settings: AppSettings?

    private var quitting = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let settings else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        Task { @MainActor in
            do {
                try await settings.finishSession()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                quitting = false
                let alert = NSAlert()
                alert.messageText = L10n.text("시작 전 설정을 복원하지 못했습니다")
                alert.informativeText = L10n.text(error.localizedDescription) + L10n.text("\n백업은 보관되어 있습니다. 문제를 해결한 뒤 종료를 다시 시도해 주세요.")
                alert.addButton(withTitle: L10n.text("앱으로 돌아가기"))
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

@main
struct MacInterfaceControllerApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var navigation = AppNavigation()
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.korean.rawValue

    var body: some Scene {
        Window(L10n.text("Mac Interface Controller"), id: "settings") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(navigation)
                .environment(\.locale, Locale(identifier: language))
                .onAppear { applicationDelegate.settings = settings }
                .frame(minWidth: 880, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 780)

        Window(L10n.text("앱 설정"), id: "app-preferences") {
            ProfileSettingsView()
                .environmentObject(settings)
                .environment(\.locale, Locale(identifier: language))
                .groupBoxStyle(SettingsCardStyle())
                .frame(minWidth: 580, minHeight: 490)
        }
        .defaultSize(width: 640, height: 560)

        MenuBarExtra(L10n.text("Mac Interface Controller"), systemImage: "command.square.fill") {
            MenuBarView()
                .environmentObject(settings)
                .environmentObject(navigation)
                .environment(\.locale, Locale(identifier: language))
        }
    }
}
