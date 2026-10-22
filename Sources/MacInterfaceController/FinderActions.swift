import AppKit
import Foundation

/// How a terminal needs to be launched to start in a given directory.
enum TerminalLaunchPlan: Equatable {
    /// Hand the folder to the app as a document (Terminal, iTerm, Ghostty, Warp, ...).
    case openDocument
    /// Start a new instance with the terminal's own working-directory flag.
    case arguments([String])
}

enum TerminalLauncher {
    /// Terminals that ignore a folder passed as a document and need their own flag.
    private static let flagBased: [String: [String]] = [
        "io.alacritty": ["--working-directory"],
        "net.kovidgoyal.kitty": ["--single-instance", "--instance-group", "1", "--directory"],
        "com.github.wez.wezterm": ["start", "--cwd"],
        "org.tabby": ["--directory"],
    ]

    static func plan(bundleIdentifier: String, directory: URL) -> TerminalLaunchPlan {
        guard let flags = flagBased[bundleIdentifier] else { return .openDocument }
        return .arguments(flags + [directory.path])
    }
}

enum FinderLocation {
    /// Selection when something is selected, otherwise the front Finder window, otherwise the Desktop.
    static let script = """
    tell application "Finder"
        set selectedItems to selection as alias list
        set output to ""
        if selectedItems is {} then
            try
                set output to POSIX path of (target of front Finder window as alias)
            on error
                set output to POSIX path of (path to desktop folder)
            end try
        else
            repeat with selectedItem in selectedItems
                set output to output & POSIX path of selectedItem & linefeed
            end repeat
        end if
        return output
    end tell
    """

    static let maximumDirectories = 5

    /// A selected file stands for its folder. Duplicates collapse and missing paths are ignored.
    static func directories(fromScriptOutput output: String, fileManager: FileManager = .default) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let path = String(line).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
            let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
            let standardized = directory.standardizedFileURL
            if seen.insert(standardized.path).inserted { result.append(standardized) }
            if result.count == maximumDirectories { break }
        }
        return result
    }
}

/// Terminal and editor choices shared by the app and the Finder agent through the app's preferences domain.
enum FinderPreferences {
    static let domain = "dev.local.MacInterfaceController"
    static let terminalKey = "finder.terminalBundleID"
    static let editorKey = "finder.editorBundleID"

    static let terminalCandidates = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.tabby",
    ]
    static let editorCandidates = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4",
        "com.barebones.bbedit", "com.apple.dt.Xcode", "com.apple.TextEdit",
    ]

    /// The app itself must not open a suite named after its own bundle identifier.
    private static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == domain ? .standard : (UserDefaults(suiteName: domain) ?? .standard)
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func terminalBundleID() -> String {
        if let id = defaults.string(forKey: terminalKey), isInstalled(id) { return id }
        return "com.apple.Terminal"
    }

    static func editorBundleID() -> String? {
        if let id = defaults.string(forKey: editorKey), isInstalled(id) { return id }
        return editorCandidates.first(where: isInstalled)
    }
}

/// Launches terminals and editors. It has no UI dependencies so the windowless Finder agent can use it too.
enum FinderActionRunner {
    /// `completion` receives an error message, or nil on success, once every folder was handed over.
    static func openInTerminal(_ directories: [URL], bundleID: String, completion: @escaping (String?) -> Void) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion("터미널 앱을 찾을 수 없습니다. 'Finder 연동'에서 터미널 앱을 다시 선택해 주세요.")
            return
        }
        guard !directories.isEmpty else { completion("Finder에서 열 폴더를 찾지 못했습니다."); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var failure: String?
        func record(_ message: String) { lock.lock(); failure = failure ?? message; lock.unlock() }
        for directory in directories {
            switch TerminalLauncher.plan(bundleIdentifier: bundleID, directory: directory) {
            case .openDocument:
                group.enter()
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: configuration) { _, error in
                    if let error { record("터미널을 열지 못했습니다: \(error.localizedDescription)") }
                    group.leave()
                }
            case .arguments(let arguments):
                // No shell is involved, so folder names are passed to the terminal verbatim.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-n", "-b", bundleID, "--args"] + arguments
                do { try process.run() } catch { record("터미널을 열지 못했습니다: \(error.localizedDescription)") }
            }
        }
        group.notify(queue: .main) { completion(failure) }
    }

    static func openInEditor(_ urls: [URL], bundleID: String?, completion: @escaping (String?) -> Void) {
        guard let bundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion("편집기 앱을 찾을 수 없습니다. 'Finder 연동'에서 편집기 앱을 선택해 주세요.")
            return
        }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { completion("Finder에서 열 항목을 찾지 못했습니다."); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(existing, withApplicationAt: appURL, configuration: configuration) { _, error in
            completion(error.map { "편집기를 열지 못했습니다: \($0.localizedDescription)" })
        }
    }
}
