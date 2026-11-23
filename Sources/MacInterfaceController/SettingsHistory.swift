import Foundation
import FunctionKeySupport

struct DockConfiguration: Codable, Equatable {
    var autoHide: Bool
    var delay: Double?
    var duration: Double?
    var tileSize: Double? = nil
    var magnification: Bool? = nil
    var largeSize: Double? = nil
    var isValid: Bool {
        [delay, duration].compactMap { $0 }.allSatisfy { $0.isFinite && (0...5).contains($0) }
        && [tileSize, largeSize].compactMap { $0 }.allSatisfy { $0.isFinite && (16...128).contains($0) }
        && (magnification != true || tileSize == nil || largeSize == nil || largeSize! >= tileSize!)
    }
}

/// What the Dock preferences should be: the user's pre-session values, the macOS defaults, or the app's own configuration.
enum DockTarget: Equatable {
    case original
    case macOSDefault
    case custom(DockConfiguration)
}

/// The macOS "Select the previous input source" shortcut (symbolic hot key 60): the user's pre-session hot keys,
/// the macOS defaults, or one shortcut owned by the app. The system handles it even while Secure Event Input is on.
enum LanguageTarget: Equatable {
    case original
    case macOSDefault
    case custom(character: Int, keyCode: Int, flags: Int)

    var isCustom: Bool { if case .custom = self { true } else { false } }

    func preference() throws -> PreferenceBackup? {
        guard case .custom(let character, let keyCode, let flags) = self else { return nil }
        let entry: [String: Any] = ["enabled": true, "value": ["type": "standard", "parameters": [character, keyCode, flags]]]
        return PreferenceBackup(address: SystemDefaultsService.symbolicHotKeysAddress,
                                value: try PropertyListSerialization.data(fromPropertyList: ["value": ["60": entry]], format: .binary, options: 0))
    }
}

struct AppConfigurationSnapshot: Codable, Equatable {
    var profile: PortableProfile
    var engineEnabled: Bool
    var autoDisableBuiltInDisplay: Bool
    var dock: DockConfiguration?
    var loginEnabled: Bool

    func validate() throws {
        // Preserve unfinished edits and duplicate disabled/enabled combinations in historical snapshots.
        var copy = profile
        for index in copy.shortcuts.indices { copy.shortcuts[index].isEnabled = false }
        _ = try copy.validated()
        guard dock?.isValid != false else { throw SystemDefaultsError.invalidBackup }
    }
}

struct SettingsSnapshot: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case automatic, manual, beforeRestore }
    var version = 1
    var id = UUID()
    var createdAt = Date()
    var completedAt: Date?
    var kind: Kind
    var name: String
    var system: SystemSettingsBackup
    var app: AppConfigurationSnapshot
    var functionKeys: Bool?

    func validate() throws {
        guard version == 1 else { throw SystemDefaultsError.invalidBackup }
        try system.validate()
        try app.validate()
    }
}

struct ActiveSettingsSession: Codable, Equatable {
    var cycleID: UUID
    var ownerPID: Int32? = nil
    var target: SettingsSnapshot
}

/// All system writes and retention run on one actor. An active recovery record is
/// written and read back before the app is allowed to change any managed setting.
actor SettingsHistory {
    static let shared = SettingsHistory()
    private let root: URL
    private let backend: any SystemSettingsBackend
    private let readFunctionKeys: () throws -> Bool
    private let writeFunctionKeys: (Bool) throws -> Void
    private var active: ActiveSettingsSession?
    private var started = false
    private var activeURL: URL { root.appendingPathComponent("active-session.json") }

    init(root: URL? = nil, backend: any SystemSettingsBackend = LocalSystemSettingsBackend(),
         readFunctionKeys: @escaping () throws -> Bool = { try FunctionKeyHardware.read() },
         writeFunctionKeys: @escaping (Bool) throws -> Void = { try FunctionKeyHardware.write($0) }) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacInterfaceController/History")
        self.backend = backend
        self.readFunctionKeys = readFunctionKeys
        self.writeFunctionKeys = writeFunctionKeys
    }

    func begin(app: AppConfigurationSnapshot) throws {
        guard !started else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: activeURL.path) {
            // Recover an interrupted exit before capturing another cycle.
            let pending = try JSONDecoder().decode(ActiveSettingsSession.self, from: Data(contentsOf: activeURL))
            if let owner = pending.ownerPID, owner != getpid(), kill(owner, 0) == 0 {
                throw SystemDefaultsError.commandFailed("다른 앱 인스턴스가 실행 중입니다. 먼저 해당 앱을 종료해 주세요.")
            }
            active = pending
            try finish()
        }
        let snapshot = try capture(kind: .automatic, name: "시작 전 자동 백업", app: app)
        try save(snapshot)
        let session = ActiveSettingsSession(cycleID: snapshot.id, ownerPID: getpid(), target: snapshot)
        try writeVerified(session, to: activeURL)
        active = session
        started = true
    }

    func finish() throws {
        guard let session = active else { return }
        try restoreSystem(session.target)
        let url = file(session.cycleID)
        var completed = try read(url)
        completed.completedAt = Date()
        try save(completed)
        try FileManager.default.removeItem(at: activeURL)
        active = nil
        started = false
        try prune()
    }

    func checkpoint(app: AppConfigurationSnapshot, name: String, kind: SettingsSnapshot.Kind = .manual) throws -> SettingsSnapshot {
        let snapshot = try capture(kind: kind, name: name.isEmpty ? "수동 백업" : name, app: app)
        try save(snapshot)
        return snapshot
    }

    func restore(id: UUID, currentApp: AppConfigurationSnapshot, currentFunctionKeys: Bool? = nil) throws -> SettingsSnapshot {
        guard let session = active else { throw SystemDefaultsError.commandFailed("시작 백업을 완료한 뒤 복원해 주세요.") }
        let target = try read(file(id))
        try target.validate()
        var undo = try capture(kind: .beforeRestore, name: "복원 직전", app: currentApp)
        if let currentFunctionKeys { undo.functionKeys = currentFunctionKeys }
        try save(undo)
        try restoreSystem(target)
        // An explicit point-in-time restore becomes the new exit target, so quit
        // cannot silently undo the user's restore. The original cycle remains in history.
        var exitTarget = target
        exitTarget.system = try backend.capture()
        let updated = ActiveSettingsSession(cycleID: session.cycleID, ownerPID: getpid(), target: exitTarget)
        do { try writeVerified(updated, to: activeURL) }
        catch {
            try restoreSystem(session.target)
            throw error
        }
        active = updated
        return target
    }

    func applyDock(_ configuration: DockConfiguration?) throws {
        try applyDock(target: configuration.map(DockTarget.custom) ?? .original)
    }

    func applyDock(target: DockTarget) throws {
        guard let active else { throw SystemDefaultsError.commandFailed("시작 백업이 완료되지 않았습니다.") }
        var configuration: DockConfiguration?
        if case .custom(let custom) = target { configuration = custom }
        guard configuration?.isValid != false else { throw SystemDefaultsError.invalidBackup }
        let old = try backend.captureDock()
        let desired: [PreferenceBackup]
        if target == .macOSDefault {
            desired = []
        } else if let configuration {
            var values: [(String, Any)] = [("autohide", configuration.autoHide)]
            if let delay = configuration.delay { values.append(("autohide-delay", delay)) }
            if let duration = configuration.duration { values.append(("autohide-time-modifier", duration)) }
            if let size = configuration.tileSize { values.append(("tilesize", size)) }
            if let enabled = configuration.magnification { values.append(("magnification", enabled)) }
            if let size = configuration.largeSize { values.append(("largesize", size)) }
            let changedSizeKeys = Set(values.map { $0.0 }).intersection(SystemDefaultsService.dockSizeKeys)
            let preserved = old.filter { SystemDefaultsService.dockSizeKeys.contains($0.address.key) && !changedSizeKeys.contains($0.address.key) }
            desired = preserved + (try values.map { PreferenceBackup(address: .init(domain: "com.apple.dock", currentHost: false, key: $0.0), value: try PropertyListSerialization.data(fromPropertyList: ["value": $0.1], format: .binary, options: 0)) })
        } else {
            desired = active.target.system.preferences.filter { $0.address.domain == "com.apple.dock" && SystemDefaultsService.dockKeys.contains($0.address.key) }
        }
        try transition(old: old, desired: desired, label: "Dock", capture: backend.captureDock)
    }

    func applyLanguageShortcut(_ target: LanguageTarget) throws {
        guard let active else { throw SystemDefaultsError.commandFailed("시작 백업이 완료되지 않았습니다.") }
        let old = try backend.captureSymbolicHotKeys()
        let desired: [PreferenceBackup]
        switch target {
        case .original: desired = active.target.system.preferences.filter { $0.address == SystemDefaultsService.symbolicHotKeysAddress }
        case .macOSDefault: desired = []
        case .custom: desired = try target.preference().map { [$0] } ?? []
        }
        try transition(old: old, desired: desired, label: "한/영 단축키", capture: backend.captureSymbolicHotKeys, finishing: backend.activateHotKeys)
    }

    /// Replaces the current values of one managed preference group with `desired`, rolling back on any failure.
    private func transition(old: [PreferenceBackup], desired: [PreferenceBackup], label: String,
                            capture: () throws -> [PreferenceBackup], finishing: (() throws -> Void)? = nil) throws {
        func finish() throws { if let finishing { try finishing() } else { try backend.finish() } }
        let currentScope = SystemSettingsBackup(createdAt: Date(), machineName: label, preferences: old, hidMappings: [])
        let targetScope = SystemSettingsBackup(createdAt: Date(), machineName: label, preferences: desired, hidMappings: [])
        if try currentScope.hasSameSettings(as: targetScope) { return }
        do {
            for item in old { try backend.write(item, removing: true) }
            for item in desired { try backend.write(item, removing: false) }
            try finish()
            let actual = try capture()
            guard try SystemSettingsBackup(createdAt: Date(), machineName: label, preferences: actual, hidMappings: []).hasSameSettings(as: targetScope) else { throw SystemDefaultsError.commandFailed("\(label) 적용 상태를 확인하지 못했습니다.") }
        } catch {
            let original = error
            do {
                for item in try capture() { try backend.write(item, removing: true) }
                for item in old { try backend.write(item, removing: false) }
                try finish()
                let restored = SystemSettingsBackup(createdAt: Date(), machineName: label, preferences: try capture(), hidMappings: [])
                guard try restored.hasSameSettings(as: currentScope) else {
                    throw SystemDefaultsError.commandFailed("\(label) 자동 복구 결과를 확인하지 못했습니다.")
                }
            } catch {
                throw SystemDefaultsError.commandFailed("\(label) 변경 실패: \(original.localizedDescription)\n자동 복구 실패: \(error.localizedDescription)")
            }
            throw original
        }
    }

    /// While the app's own hot corners run, macOS' corner actions would fire as well. Corners the app uses are set to
    /// "disabled" and the rest return to the macOS default; `nil` restores what was there when the session started.
    func applyHotCorners(_ appCorners: Set<CornerPosition>?) throws {
        guard let active else { throw SystemDefaultsError.commandFailed("시작 백업이 완료되지 않았습니다.") }
        let old = try backend.captureHotCorners()
        let desired: [PreferenceBackup]
        if let appCorners {
            desired = try appCorners.sorted { $0.rawValue < $1.rawValue }.flatMap { position -> [PreferenceBackup] in
                try [("corner", 1), ("modifier", 0)].map { suffix, value in
                    PreferenceBackup(address: .init(domain: "com.apple.dock", currentHost: false, key: "wvous-\(position.dockPrefix)-\(suffix)"),
                                     value: try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0))
                }
            }
        } else {
            desired = active.target.system.preferences.filter { $0.address.domain == "com.apple.dock" && SystemDefaultsService.hotCornerKeys.contains($0.address.key) }
        }
        try transition(old: old, desired: desired, label: "핫 코너", capture: backend.captureHotCorners)
    }

    /// The settings captured when this session started, which are restored on exit.
    func sessionBaseline() -> (system: SystemSettingsBackup, functionKeys: Bool?)? {
        active.map { ($0.target.system, $0.target.functionKeys) }
    }

    func liveSystem() throws -> SystemSettingsBackup { try backend.capture() }

    func list() throws -> [SettingsSnapshot] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.pathExtension == "json" }
            .map { try read($0) }.sorted { $0.createdAt > $1.createdAt }
    }

    func directory() -> URL { root }

    func rebase(app: AppConfigurationSnapshot) throws {
        guard let active else { throw SystemDefaultsError.noBackup }
        let target = try checkpoint(app: app, name: "시스템 복원 시점", kind: .manual)
        let updated = ActiveSettingsSession(cycleID: active.cycleID, ownerPID: getpid(), target: target)
        try writeVerified(updated, to: activeURL)
        self.active = updated
    }

    private func capture(kind: SettingsSnapshot.Kind, name: String, app: AppConfigurationSnapshot) throws -> SettingsSnapshot {
        let snapshot = SettingsSnapshot(kind: kind, name: name, system: try backend.capture(), app: app, functionKeys: try? readFunctionKeys())
        try snapshot.validate()
        return snapshot
    }
    private func restoreSystem(_ snapshot: SettingsSnapshot) throws {
        try snapshot.validate()
        let before = try backend.capture()
        let originalFunctionKeys = try? readFunctionKeys()
        do {
            try SystemSettingsTransaction(backend: backend).restore(snapshot.system)
            if let mode = snapshot.functionKeys { try writeFunctionKeys(mode) }
        } catch {
            do {
                try SystemSettingsTransaction(backend: backend).restore(before)
                if let mode = originalFunctionKeys { try writeFunctionKeys(mode) }
            } catch {
                throw SystemDefaultsError.commandFailed("복원과 이전 상태 복구에 실패했습니다. 자동 백업을 유지합니다: \(error.localizedDescription)")
            }
            throw error
        }
    }
    private func prune() throws {
        let completed = try list().filter { $0.kind == .automatic && $0.completedAt != nil && $0.id != active?.cycleID }
        for snapshot in completed.dropFirst(15) { try FileManager.default.removeItem(at: file(snapshot.id)) }
    }
    private func file(_ id: UUID) -> URL { root.appendingPathComponent("snapshot-\(id.uuidString).json") }
    private func read(_ url: URL) throws -> SettingsSnapshot {
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(contentsOf: url))
        try snapshot.validate()
        return snapshot
    }
    private func save(_ snapshot: SettingsSnapshot) throws { try snapshot.validate(); try writeVerified(snapshot, to: file(snapshot.id)) }
    private func writeVerified<T: Codable & Equatable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) == value else { throw SystemDefaultsError.invalidBackup }
    }
}
