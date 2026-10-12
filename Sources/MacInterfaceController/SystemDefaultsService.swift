import Foundation

struct ManagedSettingsState: Sendable {
    var customMenuShortcutsPresent = false
    var symbolicHotKeysPresent = false
    var hotCornerKeysPresent = false
    var modifierMappingsPresent = false
    var warnings: [String] = []
    var error: String?
}

struct KeyMappingState: Sendable, Equatable {
    var mappingsPresent = false
    var error: String?
    var allowsRemapping: Bool { !mappingsPresent && error == nil }
}

enum SystemDefaultsError: LocalizedError {
    case commandFailed(String)
    case preparationFailed(String)
    case noBackup
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .preparationFailed(let message): "백업 준비에 실패해 시스템 설정을 변경하지 않았습니다: \(message)"
        case .noBackup: "복원할 백업이 없습니다."
        case .invalidBackup: "백업 형식 또는 저장된 설정을 확인할 수 없습니다. 변경하지 않았습니다."
        }
    }
}

struct PreferenceAddress: Codable, Hashable, Sendable {
    let domain: String
    let currentHost: Bool
    let key: String
}

struct PreferenceBackup: Codable, Equatable, Sendable {
    let address: PreferenceAddress
    // A wrapper preserves plist types, including dictionaries and integer values.
    let value: Data
}

struct HIDMapping: Codable, Equatable, Sendable {
    let source: UInt64
    let destination: UInt64

    var property: [String: UInt64] {
        ["HIDKeyboardModifierMappingSrc": source, "HIDKeyboardModifierMappingDst": destination]
    }
}

struct PreferenceDomain: Codable, Hashable, Sendable {
    let domain: String
    let currentHost: Bool
}

struct SystemSettingsBackup: Codable, Equatable, Sendable {
    var version = 5
    let createdAt: Date
    let machineName: String
    let preferences: [PreferenceBackup]
    let hidMappings: [HIDMapping]
    var excludedDomains: [PreferenceDomain]? = nil

    func manages(_ address: PreferenceAddress) -> Bool {
        SystemDefaultsService.isManaged(address) && (version >= 4 || !SystemDefaultsService.isExtended(address))
            && (version >= 5 || !(address.domain == "com.apple.dock" && SystemDefaultsService.dockSizeKeys.contains(address.key)))
    }

    func excludes(_ address: PreferenceAddress) -> Bool {
        (excludedDomains ?? []).contains(PreferenceDomain(domain: address.domain, currentHost: address.currentHost))
    }

    /// Compare only the recorded scope. A previously excluded domain becoming
    /// readable must neither be cleared nor cause unrelated rollback writes.
    func hasSameSettings(as reference: Self) throws -> Bool {
        guard Set(excludedDomains ?? []).isSubset(of: Set(reference.excludedDomains ?? [])),
              hidMappings.sorted(by: { $0.source < $1.source }) == reference.hidMappings.sorted(by: { $0.source < $1.source }) else { return false }
        let actual = preferences.filter { reference.manages($0.address) && !reference.excludes($0.address) }
        guard actual.count == reference.preferences.count else { return false }
        let expected = Dictionary(uniqueKeysWithValues: reference.preferences.map { ($0.address, $0.value) })
        for item in actual {
            guard let data = expected[item.address],
                  let left = try PropertyListSerialization.propertyList(from: item.value, format: nil) as? NSDictionary,
                  let right = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary,
                  left == right else { return false }
        }
        return true
    }

    func validate() throws {
        guard [2, 3, 4, 5].contains(version), Set(preferences.map(\.address)).count == preferences.count,
              version >= 3 || (excludedDomains ?? []).isEmpty else { throw SystemDefaultsError.invalidBackup }
        let exclusions = excludedDomains ?? []
        guard Set(exclusions).count == exclusions.count,
              exclusions.allSatisfy({ !$0.domain.isEmpty && !["NSGlobalDomain", ".GlobalPreferences", "com.apple.dock", "com.apple.symbolichotkeys"].contains($0.domain) }) else {
            throw SystemDefaultsError.invalidBackup
        }
        for item in preferences {
            guard !excludes(item.address), manages(item.address),
                  let value = try PropertyListSerialization.propertyList(from: item.value, format: nil) as? [String: Any],
                  value["value"] != nil else { throw SystemDefaultsError.invalidBackup }
        }
    }
}

// Injected storage lets tests exercise backup/rollback without touching the user's keyboard.
protocol SystemSettingsBackend {
    func capture() throws -> SystemSettingsBackup
    func captureDock() throws -> [PreferenceBackup]
    func write(_ item: PreferenceBackup, removing: Bool) throws
    func setHIDMappings(_ mappings: [HIDMapping]) throws
    func finish() throws
}

extension SystemSettingsBackend {
    func captureDock() throws -> [PreferenceBackup] {
        try capture().preferences.filter { $0.address.domain == "com.apple.dock" && SystemDefaultsService.dockKeys.contains($0.address.key) }
    }
}

struct SystemSettingsTransaction {
    let backend: any SystemSettingsBackend

    func reset(saveAndVerify: (SystemSettingsBackup) throws -> Void) throws {
        let before: SystemSettingsBackup
        do {
            before = try backend.capture()
            try before.validate()
            try saveAndVerify(before) // No mutation is allowed before durable backup verification.
        } catch { throw SystemDefaultsError.preparationFailed(error.localizedDescription) }
        do {
            for item in before.preferences { try backend.write(item, removing: true) }
            if !before.hidMappings.isEmpty { try backend.setHIDMappings([]) }
            try backend.finish()
            let after = try backend.capture()
            let expected = SystemSettingsBackup(createdAt: before.createdAt, machineName: before.machineName,
                                                preferences: [], hidMappings: [], excludedDomains: before.excludedDomains)
            guard try after.hasSameSettings(as: expected) else {
                throw SystemDefaultsError.commandFailed("일부 시스템 설정이 남아 있습니다. 기존 설정으로 되돌립니다.")
            }
        } catch {
            try rollback(before, original: error)
        }
    }

    func restore(_ backup: SystemSettingsBackup) throws {
        try backup.validate() // Validate every item before the first write.
        let before = try backend.capture()
        guard !backup.preferences.contains(where: { before.excludes($0.address) }) else {
            throw SystemDefaultsError.commandFailed("백업의 일부 설정에 현재 접근할 수 없어 복원을 시작하지 않았습니다.")
        }
        if try before.hasSameSettings(as: backup) { return }
        var restoreScope = backup
        restoreScope.version = backup.version
        restoreScope.excludedDomains = Array(Set((backup.excludedDomains ?? []) + (before.excludedDomains ?? [])))
        do {
            for item in before.preferences where restoreScope.manages(item.address) && !restoreScope.excludes(item.address) { try backend.write(item, removing: true) }
            for item in backup.preferences { try backend.write(item, removing: false) }
            try backend.setHIDMappings(backup.hidMappings)
            try backend.finish()
            guard try backend.capture().hasSameSettings(as: restoreScope) else {
                throw SystemDefaultsError.commandFailed("복원한 설정이 백업과 일치하지 않습니다.")
            }
        } catch {
            try rollback(before, original: error)
        }
    }

    private func rollback(_ before: SystemSettingsBackup, original: Error) throws {
        do {
            let current = try backend.capture()
            guard !before.preferences.contains(where: { current.excludes($0.address) }) else {
                throw SystemDefaultsError.commandFailed("이전 설정에 대한 접근 권한이 변경되어 자동 복구를 완료할 수 없습니다.")
            }
            for item in current.preferences where !before.excludes(item.address) { try backend.write(item, removing: true) }
            for item in before.preferences { try backend.write(item, removing: false) }
            try backend.setHIDMappings(before.hidMappings)
            try backend.finish()
            guard try backend.capture().hasSameSettings(as: before) else {
                throw SystemDefaultsError.commandFailed("자동 복구 결과를 확인하지 못했습니다.")
            }
        } catch {
            throw SystemDefaultsError.commandFailed("변경 실패: \(original.localizedDescription)\n자동 복구도 실패했습니다: \(error.localizedDescription). 저장된 백업으로 다시 복원해 주세요.")
        }
        throw SystemDefaultsError.commandFailed("변경을 완료하지 못해 기존 설정으로 복구했습니다: \(original.localizedDescription)")
    }
}

struct LocalSystemSettingsBackend: SystemSettingsBackend {
    private func application(_ domain: String) -> CFString {
        domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : domain as CFString
    }
    private func host(_ current: Bool) -> CFString {
        current ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
    }

    func capture() throws -> SystemSettingsBackup {
        try snapshot().backup
    }

    func captureDock() throws -> [PreferenceBackup] {
        var result: [PreferenceBackup] = []
        let domain = "com.apple.dock" as CFString
        for currentHost in [false, true] {
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, host(currentHost)) else {
                throw SystemDefaultsError.commandFailed("Dock 설정을 읽지 못했습니다.")
            }
            for key in SystemDefaultsService.dockKeys.sorted() {
                guard let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, host(currentHost)) else { continue }
                result.append(PreferenceBackup(address: .init(domain: "com.apple.dock", currentHost: currentHost, key: key),
                    value: try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)))
            }
        }
        return result
    }

    func snapshot() throws -> (backup: SystemSettingsBackup, warnings: [String]) {
        var result: [PreferenceBackup] = []
        var warnings: [String] = []
        var exclusions: [PreferenceDomain] = []
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        var hostUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&hostUUID, &timeout) == 0 else {
            throw SystemDefaultsError.commandFailed("현재 Mac의 기기별 설정 식별자를 읽지 못했습니다.")
        }
        let hostIdentifier = UUID(uuid: hostUUID).uuidString
        for currentHost in [false, true] {
            let discovered = try MenuShortcutDiscovery.scan(
                directory: currentHost ? preferences.appendingPathComponent("ByHost") : preferences,
                hostIdentifier: currentHost ? hostIdentifier : nil, deniedFiles: .shared)
            warnings += discovered.warnings
            exclusions += discovered.excludedDomains.sorted().map { PreferenceDomain(domain: $0, currentHost: currentHost) }
            var domains = discovered.domains
            domains.formUnion(["NSGlobalDomain", "com.apple.symbolichotkeys", "com.apple.dock"])
            for domain in domains.sorted() {
                let app = application(domain)
                guard CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, host(currentHost)) else {
                    throw SystemDefaultsError.commandFailed("설정을 읽지 못했습니다: \(domain)")
                }
                let keys: [String]
                switch domain {
                case "NSGlobalDomain":
                    keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, host(currentHost)) as? [String] ?? []
                case "com.apple.symbolichotkeys": keys = ["AppleSymbolicHotKeys", "NSUserKeyEquivalents"]
                case "com.apple.dock": keys = Array(SystemDefaultsService.hotCornerKeys.union(SystemDefaultsService.dockKeys)) + ["NSUserKeyEquivalents"]
                default: keys = ["NSUserKeyEquivalents"]
                }
                for key in keys.sorted() {
                    let address = PreferenceAddress(domain: domain, currentHost: currentHost, key: key)
                    guard SystemDefaultsService.isManaged(address),
                          let value = CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, host(currentHost)) else { continue }
                    let data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
                    result.append(PreferenceBackup(address: address, value: data))
                }
            }
        }
        let backup = SystemSettingsBackup(createdAt: Date(), machineName: Host.current().localizedName ?? "Mac",
                                          preferences: result, hidMappings: try readHIDMappings(), excludedDomains: exclusions)
        try backup.validate()
        return (backup, warnings)
    }

    func write(_ item: PreferenceBackup, removing: Bool) throws {
        let a = item.address
        let wrapper = try PropertyListSerialization.propertyList(from: item.value, format: nil) as? [String: Any]
        CFPreferencesSetValue(a.key as CFString, removing ? nil : wrapper?["value"] as CFPropertyList?, application(a.domain), kCFPreferencesCurrentUser, host(a.currentHost))
        guard CFPreferencesSynchronize(application(a.domain), kCFPreferencesCurrentUser, host(a.currentHost)) else {
            throw SystemDefaultsError.commandFailed("설정을 저장하지 못했습니다: \(a.domain) / \(a.key)")
        }
    }

    func readHIDMappings() throws -> [HIDMapping] {
        let data = try SystemDefaultsService.run("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"])
        return try HIDMappingParser.parse(data).commonMappings()
    }

    func hasHIDMappings() throws -> Bool {
        let data = try SystemDefaultsService.run("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"])
        return try HIDMappingParser.parse(data).hasMappings
    }

    func setHIDMappings(_ mappings: [HIDMapping]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["UserKeyMapping": mappings.map(\.property)], options: [.sortedKeys])
        _ = try SystemDefaultsService.run("/usr/bin/hidutil", ["property", "--set", String(decoding: data, as: UTF8.self)])
        guard try readHIDMappings() == mappings.sorted(by: { $0.source < $1.source }) else {
            throw SystemDefaultsError.commandFailed("HID 키 매핑 적용을 확인하지 못했습니다.")
        }
    }

    func finish() throws {
        _ = try SystemDefaultsService.run("/usr/bin/killall", ["-u", NSUserName(), "Dock"], acceptedExitCodes: [0, 1])
    }
}

enum SystemDefaultsService {
    static let hotCornerKeys: Set<String> = ["wvous-tl-corner", "wvous-tl-modifier", "wvous-tr-corner", "wvous-tr-modifier", "wvous-bl-corner", "wvous-bl-modifier", "wvous-br-corner", "wvous-br-modifier"]

    static let dockSizeKeys: Set<String> = ["tilesize", "magnification", "largesize"]
    static let dockKeys: Set<String> = ["autohide", "autohide-delay", "autohide-time-modifier", "tilesize", "magnification", "largesize"]
    static func isExtended(_ a: PreferenceAddress) -> Bool {
        (a.domain == "com.apple.dock" && dockKeys.contains(a.key)) || (a.domain == "NSGlobalDomain" && a.key == "com.apple.keyboard.fnState")
    }

    static func isManaged(_ a: PreferenceAddress) -> Bool {
        isExtended(a) || a.key == "NSUserKeyEquivalents"
        || (a.domain == "NSGlobalDomain" && a.key.hasPrefix("com.apple.keyboard.modifiermapping."))
        || (a.domain == "com.apple.symbolichotkeys" && a.key == "AppleSymbolicHotKeys")
        || (a.domain == "com.apple.dock" && hotCornerKeys.contains(a.key))
    }

    // Runtime safety depends only on global/host modifier mappings and HID.
    // Enumerating every preference domain can block on network directories;
    // reserve that scan for the independent full inspection and backup path.
    static func inspectKeyMappings() async -> KeyMappingState {
        await Task.detached {
            do {
                var present = false
                for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
                    guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host) else {
                        throw SystemDefaultsError.commandFailed("시스템 보조 키 설정을 읽지 못했습니다.")
                    }
                    let keys = CFPreferencesCopyKeyList(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host) as? [String] ?? []
                    present = present || keys.contains { $0.hasPrefix("com.apple.keyboard.modifiermapping.") }
                }
                let hidPresent = try LocalSystemSettingsBackend().hasHIDMappings()
                return KeyMappingState(mappingsPresent: present || hidPresent)
            } catch { return KeyMappingState(error: error.localizedDescription) }
        }.value
    }

    static func inspect() async -> ManagedSettingsState {
        await Task.detached {
            do {
                let snapshot = try LocalSystemSettingsBackend().snapshot()
                let backup = snapshot.backup
                let keys = backup.preferences.map(\.address.key)
                return ManagedSettingsState(
                    customMenuShortcutsPresent: keys.contains("NSUserKeyEquivalents"),
                    symbolicHotKeysPresent: keys.contains("AppleSymbolicHotKeys"),
                    hotCornerKeysPresent: keys.contains(where: hotCornerKeys.contains),
                    modifierMappingsPresent: keys.contains(where: { $0.hasPrefix("com.apple.keyboard.modifiermapping.") }) || !backup.hidMappings.isEmpty,
                    warnings: snapshot.warnings
                )
            } catch { return ManagedSettingsState(error: error.localizedDescription) }
        }.value
    }

    static func resetManagedSettings() async throws -> URL {
        try await Task.detached {
            let url: URL
            do { url = try newBackupURL() }
            catch { throw SystemDefaultsError.preparationFailed(error.localizedDescription) }
            try SystemSettingsTransaction(backend: LocalSystemSettingsBackend()).reset { backup in
                try saveVerified(backup, to: url)
            }
            return url
        }.value
    }

    static func restoreBackup(at url: URL) async throws {
        try await Task.detached {
            let backup = try JSONDecoder().decode(SystemSettingsBackup.self, from: Data(contentsOf: url))
            try backup.validate()
            // Keep the current state as well, so an explicit restore can itself be undone.
            try saveVerified(LocalSystemSettingsBackend().capture(), to: newBackupURL())
            try SystemSettingsTransaction(backend: LocalSystemSettingsBackend()).restore(backup)
        }.value
    }

    static func backupURLs() -> [URL] {
        guard let root = try? backupsDirectory(), let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func backupsDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MacInterfaceController/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func newBackupURL() throws -> URL {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return try backupsDirectory().appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).json")
    }

    static func saveVerified(_ backup: SystemSettingsBackup, to url: URL) throws {
        try backup.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(backup).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try JSONDecoder().decode(SystemSettingsBackup.self, from: Data(contentsOf: url)) == backup else {
            throw SystemDefaultsError.invalidBackup
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], acceptedExitCodes: Set<Int32> = [0]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain before waiting, otherwise a full pipe can deadlock the process.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard acceptedExitCodes.contains(process.terminationStatus) else {
            throw SystemDefaultsError.commandFailed(String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
