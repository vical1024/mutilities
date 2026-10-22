import Cocoa
import FinderSync
import os

/// Adds terminal, editor and copy-path items to the Finder toolbar and context menu.
/// The sandboxed extension only hands paths to the windowless agent, which does the launching.
@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
    private let log = Logger(subsystem: "dev.local.MacInterfaceController.FinderExtension", category: "actions")
    private let isKorean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false

    override init() {
        super.init()
        log.notice("extension started")
        NSLog("FinderExtension: started")
        let controller = FIFinderSyncController.default()
        var roots: Set<URL> = [URL(fileURLWithPath: "/")]
        if let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            roots.formUnion(volumes)
        }
        controller.directoryURLs = roots
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            if let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                controller.directoryURLs.insert(volume)
            }
        }
    }

    private func text(_ korean: String, _ english: String) -> String { isKorean ? korean : english }

    /// Template symbols follow the menu bar and toolbar tint, like Finder's own glyphs.
    private func symbol(_ name: String, size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }

    override var toolbarItemName: String { text("터미널", "Terminal") }
    override var toolbarItemToolTip: String { text("현재 폴더를 터미널·편집기에서 엽니다.", "Open the current folder in Terminal or an editor.") }
    override var toolbarItemImage: NSImage { symbol("terminal", size: 16) }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        log.notice("menu requested kind=\(menuKind.rawValue, privacy: .public)")
        let menu = NSMenu(title: "")
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer, .toolbarItemMenu:
            let items: [(String, String, Selector)] = [
                (text("터미널에서 열기", "Open in Terminal"), "terminal", #selector(openInTerminal(_:))),
                (text("편집기에서 열기", "Open in Editor"), "chevron.left.forwardslash.chevron.right", #selector(openInEditor(_:))),
                (text("경로 복사", "Copy Path"), "doc.on.doc", #selector(copyPath(_:))),
            ]
            for (title, symbolName, action) in items {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.image = symbol(symbolName, size: 13)
                menu.addItem(item)
            }
        default:
            break
        }
        return menu
    }

    private func targetURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        var urls = controller.selectedItemURLs() ?? []
        if urls.isEmpty, let target = controller.targetedURL() { urls = [target] }
        return urls
    }

    /// Hands the request to the windowless agent through its URL scheme; a sandboxed extension
    /// cannot pass command-line arguments to an app it starts.
    private func runAgent(_ action: String, urls: [URL]) {
        guard !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "mutilities-finder"
        components.host = action
        components.queryItems = urls.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = components.url else { return }
        log.notice("open \(action, privacy: .public) paths=\(urls.count, privacy: .public)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { [log] _, error in
            if let error { log.error("could not reach agent: \(error.localizedDescription, privacy: .public)") }
            else { log.notice("agent reached") }
        }
    }

    @objc func openInTerminal(_ sender: Any?) {
        let urls = targetURLs()
        log.notice("openInTerminal urls=\(urls.count, privacy: .public)")
        runAgent("terminal", urls: urls)
    }

    @objc func openInEditor(_ sender: Any?) {
        let urls = targetURLs()
        log.notice("openInEditor urls=\(urls.count, privacy: .public)")
        runAgent("editor", urls: urls)
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = targetURLs().map(\.path)
        log.notice("copyPath paths=\(paths.count, privacy: .public)")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
}
