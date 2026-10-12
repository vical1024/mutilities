import Foundation
import Testing
@testable import MacInterfaceController

private final class HistoryBackend: SystemSettingsBackend {
    var values: [PreferenceAddress: Data] = [:]
    var mappings: [HIDMapping] = []
    var writes = 0
    var captures = 0
    var dockCaptures = 0
    var hidWrites = 0
    var failFinish = false
    func capture() throws -> SystemSettingsBackup {
        captures += 1
        return SystemSettingsBackup(createdAt: Date(), machineName: "Test", preferences: values.map { PreferenceBackup(address: $0.key, value: $0.value) }, hidMappings: mappings)
    }
    func captureDock() throws -> [PreferenceBackup] {
        dockCaptures += 1
        return values.filter { $0.key.domain == "com.apple.dock" && SystemDefaultsService.dockKeys.contains($0.key.key) }
            .map { PreferenceBackup(address: $0.key, value: $0.value) }
    }
    func write(_ item: PreferenceBackup, removing: Bool) throws {
        writes += 1
        values[item.address] = removing ? nil : item.value
    }
    func setHIDMappings(_ mappings: [HIDMapping]) throws { hidWrites += 1; self.mappings = mappings }
    func finish() throws {
        if failFinish { failFinish = false; throw ProfileError.invalid("simulated failure") }
    }
    func set(_ key: String, _ value: Any, domain: String = "com.apple.dock") throws {
        values[.init(domain: domain, currentHost: false, key: key)] = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }
}

struct SettingsHistoryTests {
    private func app() -> AppConfigurationSnapshot {
        AppConfigurationSnapshot(profile: PortableProfile(name: "Test", shortcuts: KeyboardTemplates.migrating([]),
            corners: CornerPosition.allCases.map { HotCornerRule(position: $0, isEnabled: false, dwellSeconds: 0.35, action: .finder) },
            swapCommandControl: true, windowsFinderMode: true, windowSwitcherEnabled: true, finderFeatures: [.open]),
            engineEnabled: true, autoDisableBuiltInDisplay: true, dock: DockConfiguration(autoHide: true, delay: 0.1, duration: 0.2), loginEnabled: false)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("history-test-\(UUID())") }
    private func history(_ root: URL, _ backend: HistoryBackend) -> SettingsHistory {
        SettingsHistory(root: root, backend: backend, readFunctionKeys: { false }, writeFunctionKeys: { _ in })
    }

    @Test func durableBackupPrecedesDockWritesAndExitRestoresExactValues() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = HistoryBackend()
        try backend.set("autohide-delay", 1.2)
        try backend.set("com.apple.keyboard.modifiermapping.test", [["source": 1]], domain: "NSGlobalDomain")
        let original = backend.values
        let store = history(root, backend)
        do { try await store.applyDock(app().dock); Issue.record("must refuse without backup") } catch { }
        #expect(backend.writes == 0)
        try await store.begin(app: app())
        #expect(backend.writes == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-session.json").path))
        try await store.applyDock(app().dock)
        #expect(backend.values != original)
        try await store.finish()
        #expect(backend.values == original)
        #expect(try await store.list().first?.completedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("active-session.json").path))
    }

    @Test func liveDockEditsAndRollbackOnlyInspectDock() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = HistoryBackend()
        try backend.set("autohide", false)
        try backend.set("NSUserKeyEquivalents", ["Test": "x"], domain: "example.other")
        let original = backend.values
        let store = history(root, backend)
        try await store.begin(app: app())
        let fullCaptures = backend.captures
        backend.failFinish = true
        await #expect(throws: (any Error).self) { try await store.applyDock(app().dock) }
        #expect(backend.values == original)
        #expect(backend.captures == fullCaptures)
        #expect(backend.hidWrites == 0)
        try await store.applyDock(app().dock)
        #expect(backend.captures == fullCaptures)
        #expect(backend.hidWrites == 0)
        let writes = backend.writes
        try await store.applyDock(app().dock)
        #expect(backend.writes == writes)
        try await store.finish()
    }

    @Test func retainsFifteenCompletedCyclesAndNeverDeletesManualSnapshots() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = HistoryBackend(), configuration = app()
        let store = history(root, backend)
        let manual = try await store.checkpoint(app: configuration, name: "keep forever")
        for _ in 0..<17 { try await store.begin(app: configuration); try await store.finish() }
        let snapshots = try await store.list()
        #expect(snapshots.filter { $0.kind == .automatic }.count == 15)
        #expect(snapshots.contains { $0.id == manual.id })
        try await store.begin(app: configuration)
        #expect(try await store.list().filter { $0.kind == .automatic }.count == 16)
    }

    @Test func interruptedSessionRecoversBeforeNextBackup() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = HistoryBackend()
        try backend.set("autohide", false)
        let original = backend.values
        let first = history(root, backend)
        try await first.begin(app: app())
        try await first.applyDock(app().dock)
        let next = history(root, backend)
        try await next.begin(app: app())
        #expect(backend.values == original)
        let snapshots = try await next.list()
        #expect(snapshots.count == 2)
        #expect(snapshots.filter { $0.completedAt != nil }.count == 1)
        try await next.finish()
    }

    @Test func failedExitKeepsRecoveryRecordAndCanRetry() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = HistoryBackend()
        let active = history(root, backend)
        try await active.begin(app: app())
        try await active.applyDock(app().dock)
        backend.failFinish = true
        do { try await active.finish(); Issue.record("expected failure") } catch { }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-session.json").path))
        #expect(try await active.list().first?.completedAt == nil)
        try await active.finish()
        #expect(backend.values.isEmpty)
    }

    @Test func pointInTimeRestoresSystemAndReturnsAllAppSettings() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = HistoryBackend()
        let active = history(root, backend)
        try await active.begin(app: app())
        try backend.set("autohide-delay", 0.7)
        var config = app()
        config.profile.shortcuts[0].windowWidthPercent = 70
        let selected = try await active.checkpoint(app: config, name: "chosen")
        let original = backend.values
        try backend.set("autohide-delay", 3.0)
        let restored = try await active.restore(id: selected.id, currentApp: app())
        #expect(restored.app == config)
        #expect(backend.values == original)
        #expect(try await active.list().contains { $0.kind == .beforeRestore })
        try await active.applyDock(app().dock)
        try await active.finish()
        #expect(backend.values == original) // quitting does not undo the explicit restore
    }

    @Test func unwritableBackupNeverChangesPreferences() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let backend = HistoryBackend()
        let active = history(root, backend)
        do { try await active.begin(app: app()); Issue.record("expected failure") } catch { }
        #expect(backend.writes == 0)
    }

    @Test func legacyBackupDoesNotEraseNewDockAndFunctionKeyScope() throws {
        let backend = HistoryBackend()
        try backend.set("autohide-delay", 0.2)
        try backend.set("com.apple.keyboard.fnState", true, domain: "NSGlobalDomain")
        try backend.set("wvous-tl-corner", 4)
        let legacy = SystemSettingsBackup(version: 3, createdAt: Date(), machineName: "Test", preferences: [], hidMappings: [])
        try SystemSettingsTransaction(backend: backend).restore(legacy)
        #expect(backend.values.count == 2)
        #expect(backend.values.keys.allSatisfy { SystemDefaultsService.isExtended($0) })
    }

    @Test func functionKeyFailureRollsBackAndKeepsSessionRecoverable() async throws {
        final class FunctionState { var mode = false; var failNext = false }
        let state = FunctionState()
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = HistoryBackend()
        let store = SettingsHistory(root: root, backend: backend, readFunctionKeys: { state.mode }, writeFunctionKeys: { mode in
            if state.failNext { state.failNext = false; throw ProfileError.invalid("function key failure") }
            state.mode = mode
        })
        try await store.begin(app: app())
        try await store.applyDock(app().dock)
        let running = backend.values
        state.mode = true
        state.failNext = true
        do { try await store.finish(); Issue.record("expected failure") } catch { }
        #expect(backend.values == running)
        #expect(state.mode)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-session.json").path))
        try await store.finish()
        #expect(backend.values.isEmpty)
        #expect(!state.mode)
    }

    @Test func widthPercentageSurvivesPortableProfileRoundTripAndRejectsInvalidValues() throws {
        var profile = app().profile
        let index = try #require(profile.shortcuts.firstIndex { $0.action == .windowCenterHeight })
        profile.shortcuts[index].windowWidthPercent = 75
        profile.shortcuts[index].windowHeightPercent = 85
        let decoded = try PortableProfile.decode(profile.encoded())
        #expect(decoded.shortcuts[index].windowWidthPercent == 75)
        #expect(decoded.shortcuts[index].windowHeightPercent == 85)
        profile.shortcuts[index].windowWidthPercent = 0
        #expect(throws: (any Error).self) { try profile.validated() }
    }

    @Test func dockSizesAreBackedUpAndLegacyTimingChangesPreserveThem() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = HistoryBackend()
        try backend.set("tilesize", 42)
        try backend.set("largesize", 110)
        try backend.set("magnification", true)
        let original = backend.values
        let store = history(root, backend)
        try await store.begin(app: app())
        try await store.applyDock(app().dock)
        for (address, value) in original { #expect(backend.values[address] == value) }
        try await store.applyDock(DockConfiguration(autoHide: true, delay: 0, duration: 0.2, tileSize: 32, magnification: true, largeSize: 96))
        #expect(backend.values != original)
        try await store.finish()
        #expect(backend.values == original)
    }

    @Test func versionFourRestorePreservesDockSizes() throws {
        let backend = HistoryBackend()
        try backend.set("tilesize", 48)
        try backend.set("largesize", 96)
        try backend.set("autohide-delay", 1.5)
        let old = SystemSettingsBackup(version: 4, createdAt: Date(), machineName: "Test", preferences: [], hidMappings: [])
        try SystemSettingsTransaction(backend: backend).restore(old)
        #expect(backend.values.count == 2)
        #expect(backend.values.keys.allSatisfy { SystemDefaultsService.dockSizeKeys.contains($0.key) })
    }

    @Test func dockSizeRangeIsValidatedAndOldConfigurationDecodes() throws {
        let old = try JSONDecoder().decode(DockConfiguration.self, from: Data(#"{"autoHide":true,"delay":0.1,"duration":0.2}"#.utf8))
        #expect(old.tileSize == nil && old.largeSize == nil && old.magnification == nil)
        #expect(DockConfiguration(autoHide: true, tileSize: 16, magnification: true, largeSize: 128).isValid)
        #expect(!DockConfiguration(autoHide: true, tileSize: 15).isValid)
        #expect(!DockConfiguration(autoHide: true, tileSize: 129).isValid)
        #expect(!DockConfiguration(autoHide: true, tileSize: 64, magnification: true, largeSize: 32).isValid)
    }

    @Test func widthAndHeightScaleIndependentlyAndLegacyWidthIsPreserved() {
        let visible = CGRect(x: 20, y: 30, width: 1000, height: 800)
        let current = CGRect(x: 100, y: 100, width: 400, height: 400)
        let sized = WindowLayoutGeometry.target(.windowCenterHeight, current: current, visible: visible, heightPercent: 50, widthPercent: 80)
        #expect(sized == CGRect(x: 120, y: 230, width: 800, height: 400))
        let legacy = WindowLayoutGeometry.target(.windowCenterHeight, current: current, visible: visible, heightPercent: 50)
        #expect(legacy.width == current.width)
        let clamped = WindowLayoutGeometry.target(.windowCenterHeight, current: current, visible: visible, heightPercent: 200, widthPercent: 200)
        #expect(clamped == visible)
    }
}
