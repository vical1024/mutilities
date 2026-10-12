import Carbon
import Foundation
import Testing
@testable import MacInterfaceController

struct ModelsTests {
    @Test func terminalShortcutUsesPhysicalQuoteAndSurvivesPersistence() throws {
        let rule = ShortcutRule(key: .quote, modifiers: [.command, .shift], action: .toggleApplication)
        #expect(rule.key.keyCode == UInt32(kVK_ANSI_Quote))
        #expect(rule.key.karabinerCode == "quote")
        #expect(rule.displayText == "⇧⌘'")
        #expect(rule.carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(try JSONDecoder().decode(ShortcutRule.self, from: JSONEncoder().encode(rule)) == rule)
    }

    @Test func legacyTerminalRuleKeepsTerminalTarget() throws {
        let old = ShortcutRule(key: .quote, modifiers: [.command, .shift], action: .toggleApplication)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "targetApplication")
        let migrated = try JSONDecoder().decode(ShortcutRule.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated.targetApplication == .terminal)
        #expect(migrated.id == old.id)
        #expect(migrated.key == old.key)
    }

    @Test func applicationSelectionAndUnconfiguredRuleSurviveSaving() throws {
        var rule = ShortcutRule(isEnabled: false, key: .quote, modifiers: [.command, .shift], action: .toggleApplication)
        let empty = try JSONDecoder().decode(ShortcutRule.self, from: JSONEncoder().encode(rule))
        #expect(!empty.targetApplication.isConfigured)
        rule.targetApplication = ApplicationTarget(bundleIdentifier: "com.apple.Safari", name: "Safari")
        let selected = try JSONDecoder().decode(ShortcutRule.self, from: JSONEncoder().encode(rule))
        #expect(selected == rule)
        #expect(selected.actionTitle == AppAction.toggleApplication.title)
        #expect(selected.targetApplication.displayName == "Safari")
    }

    @Test func detectsExistingSystemCommandControlSwap() {
        let mappings: [[String: Any]] = [
            ["HIDKeyboardModifierMappingSrc": NSNumber(value: 30_064_771_296), "HIDKeyboardModifierMappingDst": NSNumber(value: 30_064_771_299)],
            ["HIDKeyboardModifierMappingSrc": NSNumber(value: 30_064_771_299), "HIDKeyboardModifierMappingDst": NSNumber(value: 30_064_771_296)],
            ["HIDKeyboardModifierMappingSrc": NSNumber(value: 30_064_771_300), "HIDKeyboardModifierMappingDst": NSNumber(value: 30_064_771_303)],
            ["HIDKeyboardModifierMappingSrc": NSNumber(value: 30_064_771_303), "HIDKeyboardModifierMappingDst": NSNumber(value: 30_064_771_300)]
        ]
        #expect(ModifierKeyService.hasPersistentCommandControlSwap(in: [
            "com.apple.keyboard.modifiermapping.0-0-0": mappings
        ]))
    }

    @Test func shortcutDisplayUsesStableModifierOrder() {
        let rule = ShortcutRule(key: .f, modifiers: [.command, .option, .control], action: .finder)
        #expect(rule.displayText == "⌃⌥⌘F")
    }

    @Test func everyCornerHasAUniqueIdentifier() {
        #expect(Set(CornerPosition.allCases.map(\.id)).count == 4)
    }

    @Test func defaultModelsRoundTripThroughJSON() throws {
        let input = ShortcutRule(key: .m, modifiers: [.command, .shift], action: .missionControl)
        let output = try JSONDecoder().decode(ShortcutRule.self, from: JSONEncoder().encode(input))
        #expect(input == output)
    }

    @Test func inputSourceShortcutUsesPhysicalSpaceKey() {
        let rule = ShortcutRule(
            key: .space,
            modifiers: [.control, .option],
            action: .toggleInputSource
        )
        #expect(rule.key.keyCode == UInt32(kVK_Space))
        #expect(rule.displayText == "⌃⌥Space")
    }

    @Test func detectsMatchingKarabinerComplexModification() {
        let json = #"""
        {
          "profiles": [{
            "name": "Test",
            "selected": true,
            "complex_modifications": {
              "rules": [{
                "description": "Toggle language",
                "manipulators": [{
                  "type": "basic",
                  "from": {
                    "key_code": "spacebar",
                    "modifiers": { "mandatory": ["left_control", "left_option"] }
                  },
                  "to": [{ "key_code": "spacebar" }]
                }]
              }]
            }
          }]
        }
        """#
        let shortcut = ShortcutRule(
            key: .space,
            modifiers: [.control, .option],
            action: .toggleInputSource
        )
        let issues = EngineConflictDetector.karabinerConflicts(
            configuration: Data(json.utf8),
            shortcuts: [shortcut]
        )
        #expect(issues.count == 1)
        #expect(issues.first?.severity == .blocking)
    }

    @Test func ignoresUnrelatedKarabinerCombination() {
        let json = #"""
        {
          "profiles": [{
            "selected": true,
            "complex_modifications": {
              "rules": [{
                "description": "Different key",
                "manipulators": [{
                  "from": { "key_code": "j", "modifiers": { "mandatory": ["command"] } },
                  "to": [{ "key_code": "down_arrow" }]
                }]
              }]
            }
          }]
        }
        """#
        let shortcut = ShortcutRule(key: .space, modifiers: [.control, .option], action: .toggleInputSource)
        let issues = EngineConflictDetector.karabinerConflicts(
            configuration: Data(json.utf8),
            shortcuts: [shortcut]
        )
        #expect(issues.isEmpty)
    }

    @Test func windowSwitcherSelectionWrapsInBothDirections() {
        #expect(WindowSwitcherController.nextIndex(current: 2, count: 3, reverse: false) == 0)
        #expect(WindowSwitcherController.nextIndex(current: 0, count: 3, reverse: true) == 2)
        #expect(WindowSwitcherController.nextIndex(current: 0, count: 0, reverse: false) == 0)
    }
}
