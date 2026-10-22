import AppKit
import os

// Windowless helper for the Finder extension. A sandboxed extension cannot pass command-line
// arguments to an app it starts, so requests arrive as `mutilities-finder://terminal|editor?path=…`.
// The same request can be given as arguments (`FinderAgent terminal <path>…`) for testing.
// It lives outside the main app so that opening a terminal never shows the settings window.
let log = Logger(subsystem: "dev.local.MacInterfaceController.FinderAgent", category: "actions")

func finish(_ message: String?) {
    log.notice("finished \(message ?? "ok", privacy: .public)")
    exit(message == nil ? 0 : 1)
}

func runRequest(action: String, paths: [String]) {
    log.notice("request \(action, privacy: .public) paths=\(paths.count, privacy: .public)")
    switch action {
    case "terminal":
        let directories = FinderLocation.directories(fromScriptOutput: paths.joined(separator: "\n"))
        log.notice("terminal \(FinderPreferences.terminalBundleID(), privacy: .public) dirs=\(directories.count, privacy: .public)")
        FinderActionRunner.openInTerminal(directories, bundleID: FinderPreferences.terminalBundleID(), completion: finish)
    case "editor":
        FinderActionRunner.openInEditor(paths.map { URL(fileURLWithPath: $0) }, bundleID: FinderPreferences.editorBundleID(), completion: finish)
    default:
        finish("unknown action \(action)")
    }
}

final class URLRequestHandler: NSObject {
    @objc func handle(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let components = URLComponents(string: string), components.scheme == "mutilities-finder",
              let action = components.host else { finish("bad url"); return }
        let paths = components.queryItems?.filter { $0.name == "path" }.compactMap(\.value) ?? []
        runRequest(action: action, paths: paths)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
log.notice("started args=\(arguments.joined(separator: " | "), privacy: .public)")

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let handler = URLRequestHandler()
NSAppleEventManager.shared().setEventHandler(handler, andSelector: #selector(URLRequestHandler.handle(_:withReplyEvent:)),
                                             forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
if let action = arguments.first { runRequest(action: action, paths: Array(arguments.dropFirst())) }
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish("timed out") }
NSApp.run()
