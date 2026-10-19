import AppKit
import Carbon
import Testing
@testable import MacInterfaceController

@MainActor
struct KeyboardMappingTests {
    private func event(_ key: Int, _ flags: CGEventFlags = [], down: Bool = true) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down))
        event.flags = flags
        return event
    }

    @Test func controlCopyBecomesCommandCopyWithoutSystemMutation() throws {
        let engine = KeyboardRemappingEngine(swapCommandControl: true)
        let input = try event(kVK_ANSI_C, [.maskControl, .maskShift])
        _ = engine.transform(type: .keyDown, event: input, finderContext: .otherApplication)
        #expect(input.flags.contains(.maskCommand))
        #expect(!input.flags.contains(.maskControl))
        #expect(input.flags.contains(.maskShift))
        #expect(!engine.isActive) // Transformation itself never installs a system mapping or event tap.
    }

    @Test func commandBecomesControlAndBothTogetherStayBoth() throws {
        let engine = KeyboardRemappingEngine(swapCommandControl: true)
        let command = try event(kVK_ANSI_C, [.maskCommand])
        _ = engine.transform(type: .keyDown, event: command, finderContext: .otherApplication)
        #expect(command.flags.contains(.maskControl))
        #expect(!command.flags.contains(.maskCommand))
        let both = try event(kVK_ANSI_C, [.maskControl, .maskCommand])
        _ = engine.transform(type: .keyDown, event: both, finderContext: .otherApplication)
        #expect(both.flags.contains([.maskControl, .maskCommand]))
    }

    @Test func finderNavigationUsesCommandAfterSwap() throws {
        let engine = KeyboardRemappingEngine(swapCommandControl: true, windowsFinderMode: true)
        let input = try event(kVK_LeftArrow, [.maskControl])
        _ = engine.transform(type: .keyDown, event: input, finderContext: .files)
        #expect(input.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_LeftBracket))
        #expect(input.flags.contains(.maskCommand))
        #expect(!input.flags.contains(.maskControl))
    }

    @Test func finderEnterHasMatchingReleaseEvenAfterFocusChanges() throws {
        let engine = KeyboardRemappingEngine(windowsFinderMode: true)
        let press = try event(kVK_Return)
        _ = engine.transform(type: .keyDown, event: press, finderContext: .files)
        #expect(press.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_O))
        let release = try event(kVK_Return, down: false)
        _ = engine.transform(type: .keyUp, event: release, finderContext: .otherApplication)
        #expect(release.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_O))
        #expect(release.flags.contains(.maskCommand))
    }

    @Test func textEditingDoesNotOpenOrDeleteFinderFiles() throws {
        let engine = KeyboardRemappingEngine(windowsFinderMode: true)
        for key in [kVK_Return, kVK_ForwardDelete, kVK_F2] {
            let input = try event(key)
            _ = engine.transform(type: .keyDown, event: input, finderContext: .text)
            #expect(input.getIntegerValueField(.keyboardEventKeycode) == Int64(key))
        }
    }

    @Test func stopClearsHeldKeyTranslations() throws {
        let engine = KeyboardRemappingEngine(windowsFinderMode: true)
        let press = try event(kVK_Return)
        _ = engine.transform(type: .keyDown, event: press, finderContext: .files)
        engine.stop()
        let release = try event(kVK_Return, down: false)
        _ = engine.transform(type: .keyUp, event: release, finderContext: .otherApplication)
        #expect(release.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Return))
    }
}

@MainActor
struct LogicalShortcutTests {
    private func event(_ key: Int, flags: CGEventFlags, down: Bool = true) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down))
        event.flags = flags
        return event
    }

    @Test func allActionTriggersUsePostSwapControlAndCommand() throws {
        for action in AppAction.allCases {
            for swapped in [false, true] {
                for logical: CGEventFlags in [.maskControl, .maskCommand, [.maskControl, .maskCommand]] {
                    let physical: CGEventFlags
                    if swapped && logical == .maskControl { physical = .maskCommand }
                    else if swapped && logical == .maskCommand { physical = .maskControl }
                    else { physical = logical }
                    let engine = KeyboardRemappingEngine(swapCommandControl: swapped)
                    let input = try event(kVK_ANSI_K, flags: physical.union([.maskAlternate, .maskShift]))
                    _ = engine.transform(type: .keyDown, event: input, finderContext: .otherApplication)
                    #expect(input.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift]) == logical.union([.maskAlternate, .maskShift]))
                    let modifiers: Set<ShortcutModifier> = logical == .maskControl ? [.control, .option, .shift] : logical == .maskCommand ? [.command, .option, .shift] : [.control, .command, .option, .shift]
                    let rule = ShortcutRule(key: .k, modifiers: modifiers, action: action)
                    var actual: UInt32 = UInt32(optionKey) | UInt32(shiftKey)
                    if input.flags.contains(.maskControl) { actual |= UInt32(controlKey) }
                    if input.flags.contains(.maskCommand) { actual |= UInt32(cmdKey) }
                    #expect(actual == rule.carbonModifiers)
                }
            }
        }
    }

    @Test func windowSwitcherRecognizesOptionWithAndWithoutSwap() throws {
        for swapped in [false, true] {
            let engine = KeyboardRemappingEngine(swapCommandControl: swapped)
            for (physical, expected) in [(CGEventFlags.maskAlternate, true), (.maskCommand, false), (.maskControl, false),
                                         ([.maskAlternate, .maskShift], true), ([.maskAlternate, .maskCommand], false),
                                         ([.maskAlternate, .maskControl], false), (CGEventFlags(), false)] {
                let input = try event(kVK_Tab, flags: physical)
                _ = engine.transform(type: .keyDown, event: input, finderContext: .otherApplication)
                #expect(KeyboardRemappingEngine.isWindowSwitcherShortcut(keyCode: kVK_Tab, modifiers: input.flags) == expected)
                #expect(!KeyboardRemappingEngine.isWindowSwitcherShortcut(keyCode: kVK_ANSI_T, modifiers: input.flags))
                let release = try event(kVK_Tab, flags: [], down: false)
                _ = engine.transform(type: .keyUp, event: release, finderContext: .otherApplication)
            }
        }
    }

    @Test func windowsCtrlArrowsFollowTheSwappedCommandKey() throws {
        let engine = KeyboardRemappingEngine(windowsEditorMode: true, windowsCtrlIsCommand: true)
        let input = try event(kVK_LeftArrow, flags: .maskCommand)
        _ = engine.transform(type: .keyDown, event: input, finderContext: .otherApplication, textFocused: false)
        #expect(input.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == .maskAlternate)
    }

    @Test func windowsEditorKeysMapInTextInputsAndTabsAnywhere() throws {
        func mapped(_ key: Int, _ flags: CGEventFlags, text: Bool) throws -> (Int, CGEventFlags) {
            let engine = KeyboardRemappingEngine(windowsEditorMode: true)
            let input = try event(key, flags: flags)
            _ = engine.transform(type: .keyDown, event: input, finderContext: .otherApplication, textFocused: text)
            return (Int(input.getIntegerValueField(.keyboardEventKeycode)),
                    input.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]))
        }
        #expect(try mapped(kVK_Home, [], text: true) == (kVK_LeftArrow, [.maskCommand]))
        #expect(try mapped(kVK_End, .maskShift, text: true) == (kVK_RightArrow, [.maskCommand, .maskShift]))
        #expect(try mapped(kVK_Home, .maskControl, text: true) == (kVK_UpArrow, [.maskCommand]))
        #expect(try mapped(kVK_End, [.maskControl, .maskShift], text: true) == (kVK_DownArrow, [.maskCommand, .maskShift]))
        #expect(try mapped(kVK_LeftArrow, .maskControl, text: true) == (kVK_LeftArrow, [.maskAlternate]))
        #expect(try mapped(kVK_RightArrow, [.maskControl, .maskShift], text: true) == (kVK_RightArrow, [.maskAlternate, .maskShift]))
        // Outside text inputs Home and friends keep their macOS meaning (page scroll).
        #expect(try mapped(kVK_Home, [], text: false) == (kVK_Home, []))
        #expect(try mapped(kVK_LeftArrow, .maskControl, text: false) == (kVK_LeftArrow, .maskAlternate))
        // Tab switching does not depend on focus.
        #expect(try mapped(kVK_PageUp, .maskControl, text: false) == (kVK_Tab, [.maskControl, .maskShift]))
        #expect(try mapped(kVK_PageDown, .maskControl, text: false) == (kVK_Tab, .maskControl))
        // Plain Page Up/Down are untouched.
        #expect(try mapped(kVK_PageUp, [], text: true) == (kVK_PageUp, []))
    }

    @Test func windowSwitcherConflictsReserveOptionTabAndReverseOnly() {
        let rules = [ShortcutRule(key: .tab, modifiers: [.option], action: .finder),
                     ShortcutRule(key: .tab, modifiers: [.option, .shift], action: .finder),
                     ShortcutRule(key: .tab, modifiers: [.command], action: .finder),
                     ShortcutRule(key: .tab, modifiers: [.control, .shift], action: .finder),
                     ShortcutRule(key: .tab, modifiers: [.option, .command], action: .finder),
                     ShortcutRule(isEnabled: false, key: .tab, modifiers: [.option], action: .finder)]
        let issues = EngineConflictDetector.windowSwitcherIssues(shortcuts: rules, enabled: true)
        #expect(issues.count == 2)
        #expect(issues.allSatisfy { $0.severity == .blocking })
        #expect(issues[0].title.contains("⌥Tab"))
        #expect(issues[1].title.contains("⌥⇧Tab"))
        #expect(EngineConflictDetector.windowSwitcherIssues(shortcuts: rules, enabled: false).isEmpty)
    }

    @Test func finderLocationAndRedoUsePostSwapControl() throws {
        let engine = KeyboardRemappingEngine(swapCommandControl: true, windowsFinderMode: true)
        let location = try event(kVK_ANSI_L, flags: .maskCommand)
        _ = engine.transform(type: .keyDown, event: location, finderContext: .files)
        #expect(location.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_G))
        #expect(location.flags.contains([.maskCommand, .maskShift]))
        #expect(!location.flags.contains(.maskControl))
        let redo = try event(kVK_ANSI_Y, flags: .maskCommand)
        _ = engine.transform(type: .keyDown, event: redo, finderContext: .text)
        #expect(redo.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_Z))
        #expect(redo.flags.contains([.maskCommand, .maskShift]))
    }

    @Test func finderDoesNotTreatPhysicalCommandAsLogicalCommandAfterSwap() throws {
        let engine = KeyboardRemappingEngine(swapCommandControl: true, windowsFinderMode: true)
        let input = try event(kVK_LeftArrow, flags: .maskCommand)
        _ = engine.transform(type: .keyDown, event: input, finderContext: .files)
        #expect(input.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_LeftArrow))
        #expect(input.flags.contains(.maskControl))
    }

    @Test func finderReleaseKeepsFinalMappingWithoutSecondSwap() throws {
        let engine = KeyboardRemappingEngine(swapCommandControl: true, windowsFinderMode: true)
        let press = try event(kVK_LeftArrow, flags: .maskControl)
        _ = engine.transform(type: .keyDown, event: press, finderContext: .files)
        let release = try event(kVK_LeftArrow, flags: [], down: false)
        _ = engine.transform(type: .keyUp, event: release, finderContext: .otherApplication)
        #expect(release.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_LeftBracket))
        #expect(release.flags.contains(.maskCommand))
        #expect(!release.flags.contains(.maskControl))
    }

    @Test func shiftSpaceLanguageToggleIsHandledByTheTap() throws {
        let rule = ShortcutRule(key: .space, modifiers: [.shift], action: .toggleInputSource)
        let engine = KeyboardRemappingEngine(languageShortcuts: [rule])
        let press = try event(kVK_Space, flags: .maskShift)
        #expect(engine.transform(type: .keyDown, event: press, finderContext: .otherApplication) == nil)
        let plainSpace = try event(kVK_Space, flags: [])
        #expect(engine.transform(type: .keyDown, event: plainSpace, finderContext: .otherApplication) != nil)
    }
}
