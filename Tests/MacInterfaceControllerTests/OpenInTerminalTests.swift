import Foundation
import Testing
@testable import MacInterfaceController

struct OpenInTerminalTests {
    @Test func documentTerminalsReceiveTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/My Folder", isDirectory: true)
        #expect(TerminalLauncher.plan(bundleIdentifier: "com.apple.Terminal", directory: folder) == .openDocument)
        #expect(TerminalLauncher.plan(bundleIdentifier: "com.googlecode.iterm2", directory: folder) == .openDocument)
    }

    @Test func flagTerminalsKeepFolderNamesAsOneArgument() {
        let folder = URL(fileURLWithPath: "/tmp/a b; rm -rf x", isDirectory: true)
        #expect(TerminalLauncher.plan(bundleIdentifier: "io.alacritty", directory: folder)
            == .arguments(["--working-directory", "/tmp/a b; rm -rf x"]))
        #expect(TerminalLauncher.plan(bundleIdentifier: "com.github.wez.wezterm", directory: folder)
            == .arguments(["start", "--cwd", "/tmp/a b; rm -rf x"]))
    }

    @Test func selectedFilesResolveToTheirFolderWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oit-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = "\(file.path)\n\(folder.path)/\n/does/not/exist\n"
        let result = FinderLocation.directories(fromScriptOutput: output)
        #expect(result.map(\.path) == [folder.standardizedFileURL.path])
    }

    @Test func finderPreferencesFallBackToTerminal() {
        #expect(FinderPreferences.terminalCandidates.first == "com.apple.Terminal")
        #expect(FinderPreferences.terminalBundleID().isEmpty == false)
    }
}
