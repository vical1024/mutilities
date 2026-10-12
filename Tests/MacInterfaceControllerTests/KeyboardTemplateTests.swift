import AppKit
import Carbon
import Testing
@testable import MacInterfaceController

struct KeyboardTemplateTests {
    @Test func migrationPreservesEditsAndDoesNotActivateMissingTemplates() {
        let customized = ShortcutRule(isEnabled: false, key: .f3, modifiers: [.option], action: .windowLeft)
        let duplicate = ShortcutRule(key: .f4, modifiers: [.shift], action: .windowLeft)
        let migrated = KeyboardTemplates.migrating([customized, duplicate])
        #expect(migrated[0].id == customized.id)
        #expect(migrated[0].key == .f3)
        #expect(migrated[0].modifiers == [.option])
        #expect(!migrated[0].isEnabled)
        #expect(migrated[0].templateID == AppAction.windowLeft.rawValue)
        #expect(migrated[1] == duplicate)
        #expect(migrated.filter { $0.templateID != nil }.count == 7)
        #expect(migrated.dropFirst(2).allSatisfy { !$0.isEnabled })
        #expect(KeyboardTemplates.migrating(migrated) == migrated)
    }

    @Test func finderFeatureSelectionAndTemplatesSurviveExport() throws {
        let profile = PortableProfile(name: "Individual", shortcuts: KeyboardTemplates.migrating([]),
            corners: CornerPosition.allCases.map { HotCornerRule(position: $0, isEnabled: false, dwellSeconds: 0.35, action: .finder) },
            swapCommandControl: false, windowsFinderMode: true, windowSwitcherEnabled: false, finderFeatures: [.open, .rename])
        #expect(try PortableProfile.decode(profile.encoded()) == profile)
        var invalid = profile
        invalid.shortcuts[0].action = .finder
        #expect(throws: (any Error).self) { try invalid.validated() }
    }

    @Test @MainActor func finderIndividualSwitchesDoNotEnableOtherMappings() throws {
        let engine = KeyboardRemappingEngine(windowsFinderMode: true, finderFeatures: [.rename])
        for (key, expected) in [(kVK_F2, kVK_Return), (kVK_Return, kVK_Return), (kVK_ForwardDelete, kVK_ForwardDelete)] {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true))
            _ = engine.transform(type: .keyDown, event: event, finderContext: .files)
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(expected))
        }
        let copy = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true))
        copy.flags = .maskControl
        _ = engine.transform(type: .keyDown, event: copy, finderContext: .text)
        #expect(copy.flags.contains(.maskControl))
        #expect(!copy.flags.contains(.maskCommand))
    }

    @Test @MainActor func disabledFinderOverrideFallsBackToGlobalSwap() throws {
        let engine = KeyboardRemappingEngine(swapCommandControl: true, windowsFinderMode: true, finderFeatures: [.rename])
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: true))
        event.flags = .maskCommand
        _ = engine.transform(type: .keyDown, event: event, finderContext: .files)
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_LeftArrow))
        #expect(event.flags.contains(.maskControl))
    }

    @Test func dockRejectsInvalidTimesBeforeWriting() {
        #expect(DockTiming(delay: 0, duration: 0).isValid)
        #expect(!DockTiming(delay: .nan, duration: 1).isValid)
        #expect(!DockTiming(delay: 1, duration: .infinity).isValid)
        #expect(!DockTiming(delay: -1, duration: 1).isValid)
        #expect(!DockTiming(delay: 1, duration: 6).isValid)
    }
}
