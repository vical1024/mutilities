import Foundation
import Testing
@testable import MacInterfaceController

struct ProfileTests {
    private var profile: PortableProfile {
        PortableProfile(name: "Travel", shortcuts: [ShortcutRule(key: .space, modifiers: [.shift], action: .toggleInputSource)],
                        corners: CornerPosition.allCases.map { HotCornerRule(position: $0, isEnabled: true, dwellSeconds: 0.35, action: .finder) },
                        swapCommandControl: true, windowsFinderMode: true, windowSwitcherEnabled: true)
    }

    @Test func portableSettingsRoundTripWithoutMachineState() throws {
        let original = profile
        let data = try original.encoded()
        #expect(try PortableProfile.decode(data) == original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "name", "shortcuts", "corners", "swapCommandControl", "windowsFinderMode", "windowSwitcherEnabled"])
    }

    @Test func futureVersionRejected() throws {
        var p = profile
        p.version = 999
        #expect(throws: (any Error).self) { try PortableProfile.decode(JSONEncoder().encode(p)) }
    }

    @Test func duplicateEnabledShortcutRejected() {
        var p = profile
        p.shortcuts.append(ShortcutRule(key: .space, modifiers: [.shift], action: .finder))
        #expect(throws: (any Error).self) { try p.validated() }
    }

    @Test func disabledShortcutCanShareCombination() throws {
        var p = profile
        p.shortcuts.append(ShortcutRule(isEnabled: false, key: .space, modifiers: [.shift], action: .finder))
        #expect(try p.validated() == p)
    }

    @Test func missingCornerOrUnsafeDwellRejected() {
        var p = profile
        p.corners.removeLast()
        #expect(throws: (any Error).self) { try p.validated() }
        p = profile
        p.corners[0].dwellSeconds = -1
        #expect(throws: (any Error).self) { try p.validated() }
    }

    @Test func corruptProfileRejected() {
        #expect(throws: (any Error).self) { try PortableProfile.decode(Data("not json".utf8)) }
    }

    @Test func conditionalKarabinerRulesAreOnlyPotentialConflicts() throws {
        let config = #"{"profiles":[{"selected":true,"complex_modifications":{"rules":[{"manipulators":[{"from":{"key_code":"spacebar","modifiers":{"mandatory":["shift"]}},"conditions":[{"type":"frontmost_application_if","bundle_identifiers":["com.example.app"]}]}]}]}}]}"#
        let issues = EngineConflictDetector.karabinerConflicts(configuration: Data(config.utf8), shortcuts: profile.shortcuts)
        #expect(issues.count == 1)
        #expect(issues.first?.severity == .warning)
    }
}
