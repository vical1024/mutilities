import AppKit

/// Hide an application without closing its windows or terminating its work.
@MainActor
final class ApplicationToggleController {
    static let shared = ApplicationToggleController()
    private var previousApplications: [String: NSRunningApplication] = [:]
    private var isOpening = false

    func toggle(_ target: ApplicationTarget) {
        guard target.isConfigured else { NSSound.beep(); return }
        let bundleID = target.bundleIdentifier
        guard !isOpening else { return }
        let workspace = NSWorkspace.shared
        if let application = workspace.frontmostApplication, application.bundleIdentifier == bundleID {
            guard application.hide() else { NSSound.beep(); return }
            if let previousApplication = previousApplications[bundleID], !previousApplication.isTerminated {
                previousApplication.activate(options: [])
            }
            previousApplications[bundleID] = nil
            return
        }

        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            NSSound.beep()
            return
        }
        previousApplications[bundleID] = workspace.frontmostApplication
        isOpening = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Let the selected app handle reopening when it has no visible windows.
        workspace.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                guard let self else { return }
                self.isOpening = false
                if let error {
                    self.previousApplications[bundleID] = nil
                    NSSound.beep()
                    NSLog("앱 열기 실패 (%@): %@", target.name, error.localizedDescription)
                } else {
                    application?.unhide()
                }
            }
        }
    }
}
