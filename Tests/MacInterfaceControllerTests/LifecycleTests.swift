import Foundation
import Testing
@testable import MacInterfaceController

private final class MemorySystemBackend: SystemSettingsBackend {
    var entries: [PreferenceAddress: Data]
    var hid: [HIDMapping]
    var events: [String] = []
    var failOnWrite: Int?
    var writeCount = 0
    var failFinish = false
    var dropWrites = false
    var excludedDomains: [PreferenceDomain] = []

    init(_ backup: SystemSettingsBackup) {
        entries = Dictionary(uniqueKeysWithValues: backup.preferences.map { ($0.address, $0.value) })
        hid = backup.hidMappings
        excludedDomains = backup.excludedDomains ?? []
    }
    func capture() throws -> SystemSettingsBackup {
        SystemSettingsBackup(createdAt: Date(), machineName: "Test", preferences: entries.filter { !excludedDomains.contains(PreferenceDomain(domain: $0.key.domain, currentHost: $0.key.currentHost)) }.map { PreferenceBackup(address: $0.key, value: $0.value) }, hidMappings: hid, excludedDomains: excludedDomains)
    }
    func write(_ item: PreferenceBackup, removing: Bool) throws {
        events.append(removing ? "remove" : "restore")
        writeCount += 1
        if failOnWrite == writeCount { throw ProfileError.invalid("simulated write failure") }
        if !dropWrites { entries[item.address] = removing ? nil : item.value }
    }
    func setHIDMappings(_ mappings: [HIDMapping]) throws { events.append("hid"); hid = mappings }
    func finish() throws {
        events.append("finish")
        if failFinish { failFinish = false; throw ProfileError.invalid("simulated finish failure") }
    }
}

struct LifecycleTests {
    private func fixture() throws -> SystemSettingsBackup {
        let values: [(PreferenceAddress, Any)] = [
            (.init(domain: "NSGlobalDomain", currentHost: true, key: "com.apple.keyboard.modifiermapping.0-0-0"), [["HIDKeyboardModifierMappingSrc": 30064771296, "HIDKeyboardModifierMappingDst": 30064771299]]),
            (.init(domain: "com.example.editor", currentHost: false, key: "NSUserKeyEquivalents"), ["Save": "@s"]),
            (.init(domain: "com.apple.dock", currentHost: false, key: "wvous-tl-corner"), 2)
        ]
        return try SystemSettingsBackup(createdAt: Date(), machineName: "Test", preferences: values.map {
            PreferenceBackup(address: $0.0, value: try PropertyListSerialization.data(fromPropertyList: ["value": $0.1], format: .binary, options: 0))
        }, hidMappings: [HIDMapping(source: 1, destination: 2)])
    }

    @Test func backupFailureNeverChangesSystem() throws {
        let initial = try fixture()
        let backend = MemorySystemBackend(initial)
        #expect(throws: (any Error).self) {
            try SystemSettingsTransaction(backend: backend).reset { _ in throw ProfileError.invalid("disk full") }
        }
        #expect(backend.events.isEmpty)
        #expect(backend.entries.count == initial.preferences.count)
        #expect(backend.hid == initial.hidMappings)
    }

    @Test func preparationFailureIsDistinguishedFromMutationFailure() throws {
        let backend = MemorySystemBackend(try fixture())
        do {
            try SystemSettingsTransaction(backend: backend).reset { _ in throw CocoaError(.fileWriteOutOfSpace) }
            Issue.record("Expected preparation failure")
        } catch SystemDefaultsError.preparationFailed { }
        catch { Issue.record("Wrong error category: \(error)") }
        #expect(backend.events.isEmpty)
        backend.failOnWrite = 1
        do {
            try SystemSettingsTransaction(backend: backend).reset { _ in }
            Issue.record("Expected mutation failure")
        } catch SystemDefaultsError.preparationFailed {
            Issue.record("Mutation failures must not be reported as preflight failures")
        } catch { }
    }

    @Test func resetBacksUpHostAndApplicationSettingsBeforeMutation() throws {
        let initial = try fixture()
        let backend = MemorySystemBackend(initial)
        var saved: SystemSettingsBackup?
        try SystemSettingsTransaction(backend: backend).reset { snapshot in
            #expect(backend.events.isEmpty)
            saved = snapshot
        }
        #expect(saved?.preferences.count == 3)
        #expect(saved?.preferences.contains(where: { $0.address.currentHost }) == true)
        #expect(backend.entries.isEmpty)
        #expect(backend.hid.isEmpty)
        try SystemSettingsTransaction(backend: backend).restore(#require(saved))
        #expect(backend.entries == Dictionary(uniqueKeysWithValues: initial.preferences.map { ($0.address, $0.value) }))
        #expect(backend.hid == initial.hidMappings)
    }

    @Test func partialResetRollsBack() throws {
        let initial = try fixture()
        let backend = MemorySystemBackend(initial)
        backend.failOnWrite = 2
        #expect(throws: (any Error).self) { try SystemSettingsTransaction(backend: backend).reset { _ in } }
        #expect(backend.entries == Dictionary(uniqueKeysWithValues: initial.preferences.map { ($0.address, $0.value) }))
        #expect(backend.hid == initial.hidMappings)
    }

    @Test func failedRefreshAfterClearingHIDRollsBack() throws {
        let initial = try fixture()
        let backend = MemorySystemBackend(initial)
        backend.failFinish = true
        #expect(throws: (any Error).self) { try SystemSettingsTransaction(backend: backend).reset { _ in } }
        #expect(backend.entries.count == 3)
        #expect(backend.hid == initial.hidMappings)
    }

    @Test func ignoredWritesAreNotReportedAsSuccess() throws {
        let backend = MemorySystemBackend(try fixture())
        backend.dropWrites = true
        #expect(throws: (any Error).self) { try SystemSettingsTransaction(backend: backend).reset { _ in } }
    }

    @Test func corruptBackupRejectedBeforeAnyWrite() throws {
        let initial = try fixture()
        let backend = MemorySystemBackend(initial)
        let invalid = SystemSettingsBackup(createdAt: Date(), machineName: "Test", preferences: [
            PreferenceBackup(address: initial.preferences[0].address, value: Data("broken".utf8))
        ], hidMappings: [])
        #expect(throws: (any Error).self) { try SystemSettingsTransaction(backend: backend).restore(invalid) }
        #expect(backend.events.isEmpty)
    }

    @Test func backupCannotChangeUnmanagedPreferences() throws {
        let item = PreferenceBackup(address: .init(domain: "com.apple.dock", currentHost: false, key: "persistent-apps"), value: try PropertyListSerialization.data(fromPropertyList: ["value": 40], format: .binary, options: 0))
        let invalid = SystemSettingsBackup(createdAt: Date(), machineName: "Test", preferences: [item], hidMappings: [])
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test func backupIsVerifiedAndPrivateOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("backup.json")
        let initial = try fixture()
        try SystemDefaultsService.saveVerified(initial, to: url)
        #expect(try JSONDecoder().decode(SystemSettingsBackup.self, from: Data(contentsOf: url)) == initial)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func resetBacksUpScopeAndLeavesExcludedDomainUntouched() throws {
        var initial = try fixture()
        let domain = PreferenceDomain(domain: "com.example.protected", currentHost: false)
        initial.excludedDomains = [domain]
        let backend = MemorySystemBackend(initial)
        let address = PreferenceAddress(domain: domain.domain, currentHost: false, key: "NSUserKeyEquivalents")
        let privateValue = try PropertyListSerialization.data(fromPropertyList: ["value": ["Save": "@s"]], format: .binary, options: 0)
        backend.entries[address] = privateValue
        var saved: SystemSettingsBackup?
        try SystemSettingsTransaction(backend: backend).reset { saved = $0 }
        #expect(saved?.excludedDomains == [domain])
        #expect(backend.entries == [address: privateValue])
        #expect(backend.hid.isEmpty)
    }

    @Test func restorePreservesFormerlyExcludedDomainEvenWhenReadableNow() throws {
        var backup = try fixture()
        let domain = PreferenceDomain(domain: "com.example.protected", currentHost: false)
        backup.excludedDomains = [domain]
        let backend = MemorySystemBackend(try fixture())
        let address = PreferenceAddress(domain: domain.domain, currentHost: false, key: "NSUserKeyEquivalents")
        let preserved = try PropertyListSerialization.data(fromPropertyList: ["value": ["Save": "@z"]], format: .binary, options: 0)
        backend.entries[address] = preserved
        try SystemSettingsTransaction(backend: backend).restore(backup)
        #expect(backend.entries[address] == preserved)
    }

    @Test func cannotRestoreARecordedPreferenceThatIsNowInaccessible() throws {
        let backup = try fixture()
        let backend = MemorySystemBackend(backup)
        backend.excludedDomains = [PreferenceDomain(domain: "com.example.editor", currentHost: false)]
        #expect(throws: (any Error).self) { try SystemSettingsTransaction(backend: backend).restore(backup) }
        #expect(backend.events.isEmpty)
    }

    @Test func excludedScopeRoundTripsAndLegacyBackupStillDecodes() throws {
        var backup = try fixture()
        backup.excludedDomains = [PreferenceDomain(domain: "com.example.protected", currentHost: true)]
        #expect(try JSONDecoder().decode(SystemSettingsBackup.self, from: JSONEncoder().encode(backup)) == backup)
        var legacy = try fixture()
        legacy.version = 2
        legacy.excludedDomains = nil
        let decoded = try JSONDecoder().decode(SystemSettingsBackup.self, from: JSONEncoder().encode(legacy))
        try decoded.validate()
        #expect(decoded.excludedDomains == nil)
    }

    @Test func essentialSystemDomainsCannotBeExcludedFromBackup() throws {
        for domain in ["NSGlobalDomain", ".GlobalPreferences", "com.apple.dock", "com.apple.symbolichotkeys"] {
            var backup = try fixture()
            backup.excludedDomains = [PreferenceDomain(domain: domain, currentHost: false)]
            #expect(throws: (any Error).self) { try backup.validate() }
        }
    }

    @Test func finderCutExpiresWhenClipboardChanges() {
        var cut = FinderCutState()
        _ = cut.begin(copyChangeCount: 10)
        cut.observe(changeCount: 11)
        let result128 = cut.consume(changeCount: 12)
        #expect(!result128)
    }

    @Test func finderCutCanBeConsumedOnlyOnce() {
        var cut = FinderCutState()
        _ = cut.begin(copyChangeCount: 10)
        cut.observe(changeCount: 11)
        let result135 = cut.consume(changeCount: 11)
        #expect(result135)
        let result136 = cut.consume(changeCount: 11)
        #expect(!result136)
    }

    @Test func cancelledOrFailedCopyCannotMoveFiles() {
        var cut = FinderCutState()
        _ = cut.begin(copyChangeCount: 10)
        let result142 = cut.consume(changeCount: 10)
        #expect(!result142)
        _ = cut.begin(copyChangeCount: 10)
        cut.observe(changeCount: 11)
        cut.cancel()
        let result146 = cut.consume(changeCount: 11)
        #expect(!result146)
    }
}
