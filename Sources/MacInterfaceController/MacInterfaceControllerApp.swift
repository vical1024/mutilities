import SwiftUI

/// Where the app shows itself. Info.plist keeps LSUIElement so launching never flashes a Dock icon;
/// the activation policy is applied at runtime from this preference.
enum AppIconPlacement: String, CaseIterable, Identifiable {
    case menuBar, dock, both
    static let defaultsKey = "appIconPlacement"
    var id: String { rawValue }
    var showsDock: Bool { self != .menuBar }
    var showsMenuBar: Bool { self != .dock }
    var title: String {
        switch self {
        case .menuBar: "메뉴 막대"
        case .dock: "Dock"
        case .both: "메뉴 막대와 Dock"
        }
    }
    static var current: AppIconPlacement {
        AppIconPlacement(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .menuBar
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var settings: AppSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyIconPlacement()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyIconPlacement() }
        }
    }

    private func applyIconPlacement() {
        let policy: NSApplication.ActivationPolicy = AppIconPlacement.current.showsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

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
    @AppStorage(AppIconPlacement.defaultsKey) private var iconPlacement = AppIconPlacement.menuBar.rawValue

    init() { InputSourceFileLog.shared.start() }

    var body: some Scene {
        Window(L10n.text("mutilities"), id: "settings") {
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

        MenuBarExtra(L10n.text("mutilities"), systemImage: "command.square.fill", isInserted: Binding(
            get: { (AppIconPlacement(rawValue: iconPlacement) ?? .menuBar).showsMenuBar }, set: { _ in }
        )) {
            MenuBarView()
                .environmentObject(settings)
                .environmentObject(navigation)
                .environment(\.locale, Locale(identifier: language))
        }
    }
}
