import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Chooses the apps used by the Finder toolbar and context-menu items, and manages the Finder extension.
struct FinderIntegrationView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @AppStorage(FinderPreferences.terminalKey) private var terminalID = "com.apple.Terminal"
    @AppStorage(FinderPreferences.editorKey) private var editorID = ""
    @State private var extensionEnabled: Bool?
    @State private var extensionMessage: String?

    private static let extensionID = "dev.local.MacInterfaceController.FinderExtension"

    var body: some View {
        let _ = uiLanguage
        SettingsPage {
            SettingsPageHeader(title: "Finder 연동", symbol: "folder",
                               help: "Finder 도구 막대와 우클릭 메뉴에 터미널, 편집기, 경로 복사를 추가합니다. 도구 막대 버튼은 Finder의 보기 → 도구 막대 사용자 설정…에서 끌어다 놓아야 보입니다.")
            GroupBox(L10n.text("터미널 앱")) {
                AppChoiceRow(selection: $terminalID, candidates: FinderPreferences.terminalCandidates,
                             fallback: "com.apple.Terminal", chooserTitle: "터미널 앱 선택")
            }
            GroupBox(L10n.text("편집기 앱")) {
                AppChoiceRow(selection: $editorID, candidates: FinderPreferences.editorCandidates,
                             fallback: FinderPreferences.editorBundleID() ?? "", chooserTitle: "편집기 앱 선택")
            }
            GroupBox(L10n.text("Finder 확장")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L10n.text(statusText), systemImage: extensionEnabled == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(extensionEnabled == true ? Color.green : Color.orange)
                        Spacer()
                        Button(L10n.text("확장 켜기")) { Task { await enableExtension() } }
                        Button(L10n.text("시스템 설정 열기")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
                        }
                    }
                    if let extensionMessage { Text(L10n.text(extensionMessage)).font(.caption).foregroundStyle(.secondary) }
                    Text(L10n.text("켜도 메뉴가 보이지 않으면 Finder를 다시 시작해 주세요."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Finder 다시 시작")) { relaunchFinder() }
                }.padding(8)
            }
        }
        .task { await refreshStatus() }
    }

    private var statusText: String {
        switch extensionEnabled {
        case true: "확장이 켜져 있습니다"
        case false: "확장이 꺼져 있습니다"
        default: "확장 상태를 확인하는 중…"
        }
    }

    private func refreshStatus() async {
        let output = await Self.run("/usr/bin/pluginkit", ["-m", "-i", Self.extensionID])
        extensionEnabled = output.split(separator: "\n").contains { $0.hasPrefix("+") }
    }

    private func enableExtension() async {
        extensionMessage = nil
        let appex = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/FinderExtension.appex").path
        _ = await Self.run("/usr/bin/pluginkit", ["-a", appex])
        _ = await Self.run("/usr/bin/pluginkit", ["-e", "use", "-i", Self.extensionID])
        await refreshStatus()
        if extensionEnabled != true { extensionMessage = "시스템 설정의 확장 프로그램에서 직접 켜 주세요." }
    }

    private func relaunchFinder() {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.finder" }.forEach { $0.terminate() }
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do { try process.run() } catch { continuation.resume(returning: ""); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}

/// A menu of installed suggestions plus any other app on disk.
private struct AppChoiceRow: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @Binding var selection: String
    let candidates: [String]
    let fallback: String
    let chooserTitle: String

    private var current: String { selection.isEmpty ? fallback : selection }
    private var installed: [String] {
        var ids = candidates.filter(FinderPreferences.isInstalled)
        if !current.isEmpty, !ids.contains(current) { ids.insert(current, at: 0) }
        return ids
    }

    var body: some View {
        let _ = uiLanguage
        HStack {
            Menu {
                ForEach(installed, id: \.self) { id in
                    Button { selection = id } label: {
                        if id == current { Label(Self.name(for: id), systemImage: "checkmark") } else { Text(Self.name(for: id)) }
                    }
                }
                Divider()
                Button(L10n.text("다른 앱 선택…"), action: choose)
            } label: {
                Text(current.isEmpty ? L10n.text("앱을 선택하세요") : Self.name(for: current))
            }.frame(maxWidth: 360, alignment: .leading)
            Spacer(minLength: 0)
        }.padding(8)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = L10n.text(chooserTitle)
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        selection = id
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
