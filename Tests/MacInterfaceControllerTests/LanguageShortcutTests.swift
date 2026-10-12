import Carbon
import Foundation
import Testing
@testable import MacInterfaceController

struct LanguageShortcutTests {
    @Test func setupWaitKeepsShiftSpaceButExcludesOtherActions() {
        let language = ShortcutRule(key: .space, modifiers: [.shift], action: .toggleInputSource)
        let finder = ShortcutRule(key: .f, modifiers: [.option], action: .finder)
        #expect(LanguageShortcutPolicy.independentRules(from: [language, finder]) == [language])
    }

    @Test func fallbackDoesNotAssumeCommandControlState() {
        let rules = [
            ShortcutRule(key: .space, modifiers: [.command], action: .toggleInputSource),
            ShortcutRule(key: .space, modifiers: [.control, .option], action: .toggleInputSource),
            ShortcutRule(isEnabled: false, key: .space, modifiers: [.shift], action: .toggleInputSource)
        ]
        #expect(LanguageShortcutPolicy.independentRules(from: rules).isEmpty)
    }

    @Test @MainActor func languageShortcutRegistersWithoutEventTapAndStopsCleanly() {
        let rule = ShortcutRule(key: .zero, modifiers: [.shift, .option], action: .toggleInputSource)
        let hotkeys = HotKeyCenter.shared
        defer { hotkeys.stop() }
        let error = hotkeys.configure(LanguageShortcutPolicy.independentRules(from: [rule]))
        #expect(error == nil)
        #expect(hotkeys.registeredRuleIDs.contains(rule.id))
        #expect(!KeyboardRemappingEngine.shared.isActive)
        hotkeys.stop()
        #expect(hotkeys.registeredRuleIDs.isEmpty)
    }
}
