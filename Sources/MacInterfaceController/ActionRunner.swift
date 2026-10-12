import AppKit
import Foundation

@MainActor
enum ActionRunner {
    static func run(_ rule: ShortcutRule) {
        if rule.action == .macro {
            guard let macro = rule.macro else { return }
            MacroRunner.shared.start(macro, trigger: rule.key)
        } else if rule.action == .toggleApplication {
            guard !MacroRunner.shared.isRunning else { return }
            ApplicationToggleController.shared.toggle(rule.targetApplication)
        } else if rule.action.isWindowLayout {
            guard !MacroRunner.shared.isRunning else { return }
            WindowLayoutController.shared.run(rule.action, heightPercent: rule.windowHeightPercent ?? 95, widthPercent: rule.windowWidthPercent)
        } else { run(rule.action) }
    }

    static func run(_ action: AppAction) {
        guard !MacroRunner.shared.isRunning else { return }
        switch action {
        case .toggleInputSource:
            do {
                try InputSourceManager.shared.toggleKoreanEnglish()
            } catch {
                NSSound.beep()
                NSLog("한/영 입력 소스 전환 실패: %@", error.localizedDescription)
            }
        case .toggleApplication:
            break // This action requires a shortcut with a selected application.
        case .finder:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        case .missionControl:
            openApplication(at: "/System/Applications/Mission Control.app")
        case .launchpad:
            openApplication(at: "/System/Applications/Launchpad.app")
        case .screenSaver:
            openApplication(at: "/System/Library/CoreServices/ScreenSaverEngine.app")
        case .windowLeft, .windowRight, .windowMaximize, .windowRestore, .windowCenter, .windowCenterHeight:
            WindowLayoutController.shared.run(action)
        case .macro: break // Macros need a shortcut rule containing their steps.
        case .applications:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
    }

    private static func openApplication(at path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
