import Foundation
import Testing
@testable import MacInterfaceController

struct MenuShortcutDiscoveryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ values: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: url)
    }

    @Test func onlyMenuShortcutCandidatesNeedPreferenceDomainAccess() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["unrelated": true], to: dir.appendingPathComponent("com.apple.MobileSMS.plist"))
        try write(["NSUserKeyEquivalents": ["Save": "@s"]], to: dir.appendingPathComponent("com.example.editor.plist"))
        let result = try MenuShortcutDiscovery.scan(directory: dir)
        #expect(result.domains == ["com.example.editor"])
        #expect(result.warnings.isEmpty)
    }

    @Test func currentHostOnlyAndDomainSuffixPreserved() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = UUID().uuidString
        try write(["NSUserKeyEquivalents": [:]], to: dir.appendingPathComponent("com.example.editor.\(host).plist"))
        try write(["NSUserKeyEquivalents": [:]], to: dir.appendingPathComponent("com.example.other.\(UUID().uuidString).plist"))
        let result = try MenuShortcutDiscovery.scan(directory: dir, hostIdentifier: host.lowercased())
        #expect(result.domains == ["com.example.editor"])
    }

    @Test func unreadableFilesAreReportedInsteadOfClaimingDefaults() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["NSUserKeyEquivalents": [:]], to: dir.appendingPathComponent("com.example.editor.plist"))
        let result = try MenuShortcutDiscovery.scan(directory: dir, read: { _ in throw CocoaError(.fileReadNoPermission) })
        #expect(result.domains.isEmpty)
        #expect(result.warnings.count == 1)
    }

    @Test func permissionDenialIsNotRetriedEveryBackgroundScan() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(["NSUserKeyEquivalents": [:]], to: dir.appendingPathComponent("com.example.editor.plist"))
        let denied = DeniedPreferenceFiles()
        var reads = 0
        for _ in 0..<3 {
            let result = try MenuShortcutDiscovery.scan(directory: dir, deniedFiles: denied, read: { _ in
                reads += 1
                throw CocoaError(.fileReadNoPermission)
            })
            #expect(result.warnings.count == 1)
        }
        #expect(reads == 1)
    }

    @Test func symlinkIsNotFollowedToUnrelatedLocations() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("com.example.link.plist"), withDestinationURL: URL(fileURLWithPath: "/missing"))
        var reads = 0
        let result = try MenuShortcutDiscovery.scan(directory: dir, read: { _ in reads += 1; return Data() })
        #expect(reads == 0)
        #expect(result.warnings.count == 1)
    }
}
