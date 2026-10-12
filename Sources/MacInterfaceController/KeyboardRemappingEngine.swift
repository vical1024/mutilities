import AppKit
import ApplicationServices
import Carbon
import Foundation
import IOKit.hidsystem

final class KeyboardRemappingEngine {
    static let shared = KeyboardRemappingEngine()

    private(set) var isActive = false
    private var swapCommandControl = false
    private var windowsFinderMode = false
    private var finderFeatures = Set(FinderFeature.allCases)
    private var windowSwitcherEnabled = false
    private var finderCut = FinderCutState()
    private var consumedKeys: Set<Int> = []
    private var heldCloseKey: Int?
    private let windowSwitcher: WindowSwitching
    private var rewrittenKeys: [Int: (Int, CGEventFlags)] = [:]
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    enum FinderContext { case files, text, otherApplication }

    init(swapCommandControl: Bool = false, windowsFinderMode: Bool = false, finderFeatures: Set<FinderFeature> = Set(FinderFeature.allCases),
         windowSwitcherEnabled: Bool = false, windowSwitcher: WindowSwitching = WindowSwitcherController.shared) {
        self.swapCommandControl = swapCommandControl
        self.windowsFinderMode = windowsFinderMode
        self.finderFeatures = finderFeatures
        self.windowSwitcherEnabled = windowSwitcherEnabled
        self.windowSwitcher = windowSwitcher
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    var isOperational: Bool {
        guard isActive, let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func requestInputMonitoringPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    func configure(
        swapCommandControl: Bool,
        windowsFinderMode: Bool,
        finderFeatures: Set<FinderFeature> = Set(FinderFeature.allCases),
        windowSwitcherEnabled: Bool,
        macrosEnabled: Bool = false
    ) -> String? {
        if self.windowsFinderMode != windowsFinderMode || self.finderFeatures != finderFeatures { finderCut.cancel() }
        if !windowSwitcherEnabled { windowSwitcher.cancel() }
        self.swapCommandControl = swapCommandControl
        self.windowsFinderMode = windowsFinderMode
        self.finderFeatures = finderFeatures
        self.windowSwitcherEnabled = windowSwitcherEnabled

        guard swapCommandControl || windowsFinderMode || windowSwitcherEnabled || macrosEnabled else {
            stop()
            return nil
        }
        guard accessibilityGranted, inputMonitoringGranted else {
            stop()
            return "접근성과 입력 모니터링 권한을 모두 허용해 주세요."
        }
        if isOperational { return nil }
        if isActive { stop() }

        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.keyUp.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return AXIsProcessTrusted() && CGPreflightListenEventAccess()
                ? "키 리매핑 이벤트 탭을 만들지 못했습니다. 다른 입력 엔진과의 충돌을 확인해 주세요."
                : "접근성 및 입력 모니터링 권한을 확인해 주세요."
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        isActive = true
        return nil
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        finderCut.cancel()
        rewrittenKeys.removeAll()
        consumedKeys.removeAll()
        heldCloseKey = nil
        windowSwitcher.cancel()
        isActive = false
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<KeyboardRemappingEngine>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = engine.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return engine.transform(type: type, event: event)
    }

    func transform(type: CGEventType, event: CGEvent, finderContext: FinderContext? = nil) -> Unmanaged<CGEvent>? {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == LiveMacroBackend.eventTag {
            return Unmanaged.passUnretained(event)
        }
        let originalKey = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown && originalKey == kVK_Escape && MacroRunner.shared.isRunning {
            MacroRunner.shared.cancel()
            consumedKeys.insert(originalKey)
            return nil
        }
        // Keep the held close key consumed even after closing hides the overlay.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
           heldCloseKey == originalKey { return nil }
        if type == .keyUp, heldCloseKey == originalKey { heldCloseKey = nil }
        if type == .keyUp, consumedKeys.remove(originalKey) != nil { return nil }
        if type == .keyUp, let rewritten = rewrittenKeys.removeValue(forKey: originalKey) {
            rewrite(event, keyCode: rewritten.0, modifiers: rewritten.1)
            return Unmanaged.passUnretained(event)
        }

        // Normalize once. Every shortcut below and Carbon registration use the
        // resulting macOS key meaning, never the original physical modifier.
        if swapCommandControl { applyCommandControlSwap(to: event) }

        if windowSwitcherEnabled {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = relevantModifiers(event.flags)

            if windowSwitcher.isVisible {
                if type == .keyDown && Self.isWindowCloseShortcut(keyCode: keyCode, modifiers: modifiers) {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        heldCloseKey = keyCode
                        windowSwitcher.closeSelection()
                    }
                    consumedKeys.insert(keyCode)
                    return nil
                }
                if type == .keyDown && keyCode == kVK_UpArrow {
                    windowSwitcher.showOrCycle(reverse: true)
                    consumedKeys.insert(keyCode)
                    return nil
                }
                if type == .keyDown && keyCode == kVK_DownArrow {
                    windowSwitcher.showOrCycle(reverse: false)
                    consumedKeys.insert(keyCode)
                    return nil
                }
                if type == .keyDown && (keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter) {
                    windowSwitcher.commitSelection()
                    consumedKeys.insert(keyCode)
                    return nil
                }
                if type == .keyDown && keyCode == kVK_Escape {
                    windowSwitcher.cancel()
                    consumedKeys.insert(keyCode)
                    return nil
                }
            }

            if type == .keyDown && Self.isWindowSwitcherShortcut(keyCode: keyCode, modifiers: modifiers) {
                let reverse = modifiers.contains(.maskShift)
                windowSwitcher.showOrCycle(reverse: reverse)
                consumedKeys.insert(keyCode)
                return nil
            }
        }

        let context: FinderContext = finderContext ?? (windowsFinderMode && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
            ? (finderHasFocusedTextInput() ? .text : .files) : .otherApplication)
        if windowsFinderMode, context != .otherApplication {
            let handled = context == .text
                ? applyFinderTextEditingMapping(event: event)
                : applyFinderMapping(type: type, event: event)
            if handled {
                if type == .keyDown {
                    rewrittenKeys[originalKey] = (Int(event.getIntegerValueField(.keyboardEventKeycode)), relevantModifiers(event.flags))
                }
                return Unmanaged.passUnretained(event)
            }
        }

        if swapCommandControl {
            if type == .keyDown {
                rewrittenKeys[originalKey] = (Int(event.getIntegerValueField(.keyboardEventKeycode)), relevantModifiers(event.flags))
            }
        }
        return Unmanaged.passUnretained(event)
    }

    static func isWindowCloseShortcut(keyCode: Int, modifiers: CGEventFlags) -> Bool {
        keyCode == kVK_ANSI_W
            && (modifiers.isEmpty || modifiers == .maskControl || modifiers == [.maskControl, .maskShift])
    }

    static func isWindowSwitcherShortcut(keyCode: Int, modifiers: CGEventFlags) -> Bool {
        keyCode == kVK_Tab && modifiers.contains(.maskControl)
            && modifiers.subtracting([.maskControl, .maskShift]).isEmpty
    }

    private func applyCommandControlSwap(to event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Command: event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Control))
        case kVK_RightCommand: event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_RightControl))
        case kVK_Control: event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Command))
        case kVK_RightControl: event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_RightCommand))
        default: break
        }

        let original = event.flags
        var rewritten = original
        rewritten.remove([.maskCommand, .maskControl])
        if original.contains(.maskCommand) { rewritten.insert(.maskControl) }
        if original.contains(.maskControl) { rewritten.insert(.maskCommand) }
        // Some apps inspect the left/right device flags as well as the aggregate flags.
        var raw = rewritten.rawValue
        for (control, command) in [(NX_DEVICELCTLKEYMASK, NX_DEVICELCMDKEYMASK), (NX_DEVICERCTLKEYMASK, NX_DEVICERCMDKEYMASK)] {
            let c = UInt64(control), m = UInt64(command)
            raw &= ~(c | m)
            if original.rawValue & c != 0 { raw |= m }
            if original.rawValue & m != 0 { raw |= c }
        }
        event.flags = CGEventFlags(rawValue: raw)
    }

    private func applyFinderMapping(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = relevantModifiers(event.flags)
        let isKeyDown = type == .keyDown

        if finderFeatures.contains(.open), modifiers.isEmpty && (keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter) {
            rewrite(event, keyCode: kVK_ANSI_O, modifiers: [.maskCommand])
            return true
        }
        if finderFeatures.contains(.rename), modifiers.isEmpty && keyCode == kVK_F2 {
            rewrite(event, keyCode: kVK_Return, modifiers: [])
            return true
        }
        if finderFeatures.contains(.trash), modifiers.isEmpty && keyCode == kVK_ForwardDelete {
            rewrite(event, keyCode: kVK_Delete, modifiers: [.maskCommand])
            return true
        }
        if finderFeatures.contains(.navigation), modifiers == [.maskCommand] && keyCode == kVK_LeftArrow {
            rewrite(event, keyCode: kVK_ANSI_LeftBracket, modifiers: [.maskCommand])
            return true
        }
        if finderFeatures.contains(.navigation), modifiers == [.maskCommand] && keyCode == kVK_RightArrow {
            rewrite(event, keyCode: kVK_ANSI_RightBracket, modifiers: [.maskCommand])
            return true
        }
        if finderFeatures.contains(.navigation), modifiers == [.maskCommand] && keyCode == kVK_UpArrow {
            rewrite(event, keyCode: kVK_UpArrow, modifiers: [.maskCommand])
            return true
        }
        if finderFeatures.contains(.info), modifiers == [.maskAlternate] && (keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter) {
            rewrite(event, keyCode: kVK_ANSI_I, modifiers: [.maskCommand])
            return true
        }

        if modifiers == [.maskControl] {
            switch keyCode {
            case kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_F, kVK_ANSI_N, kVK_ANSI_W, kVK_ANSI_Z:
                guard finderFeatures.contains(.editing) else { return false }
                if isKeyDown && keyCode == kVK_ANSI_C { finderCut.cancel() }
                rewrite(event, keyCode: keyCode, modifiers: [.maskCommand])
                return true
            case kVK_ANSI_X:
                guard finderFeatures.contains(.move) else { return false }
                if isKeyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    let token = finderCut.begin(copyChangeCount: NSPasteboard.general.changeCount)
                    observeCopiedFiles(token: token, attempts: 10)
                }
                rewrite(event, keyCode: kVK_ANSI_C, modifiers: [.maskCommand])
                return true
            case kVK_ANSI_V:
                guard finderFeatures.contains(.editing) || finderFeatures.contains(.move) else { return false }
                let move = isKeyDown && finderCut.consume(changeCount: NSPasteboard.general.changeCount)
                let pasteModifiers: CGEventFlags = move ? [.maskCommand, .maskAlternate] : [.maskCommand]
                rewrite(event, keyCode: kVK_ANSI_V, modifiers: pasteModifiers)
                return true
            case kVK_ANSI_Y:
                guard finderFeatures.contains(.editing) else { return false }
                rewrite(event, keyCode: kVK_ANSI_Z, modifiers: [.maskCommand, .maskShift])
                return true
            case kVK_ANSI_L:
                guard finderFeatures.contains(.location) else { return false }
                rewrite(event, keyCode: kVK_ANSI_G, modifiers: [.maskCommand, .maskShift])
                return true
            default: break
            }
        }

        if finderFeatures.contains(.newFolder), modifiers == [.maskControl, .maskShift] && keyCode == kVK_ANSI_N {
            rewrite(event, keyCode: kVK_ANSI_N, modifiers: [.maskCommand, .maskShift])
            return true
        }
        return false
    }

    private func applyFinderTextEditingMapping(event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard finderFeatures.contains(.editing), relevantModifiers(event.flags) == [.maskControl] else { return false }
        switch keyCode {
        case kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_F, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z:
            if keyCode == kVK_ANSI_C || keyCode == kVK_ANSI_X { finderCut.cancel() }
            rewrite(event, keyCode: keyCode, modifiers: [.maskCommand])
            return true
        case kVK_ANSI_Y:
                guard finderFeatures.contains(.editing) else { return false }
            rewrite(event, keyCode: kVK_ANSI_Z, modifiers: [.maskCommand, .maskShift])
            return true
        default:
            return false
        }
    }

    private func finderHasFocusedTextInput() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else { return false }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success, let role = roleValue as? String else { return false }

        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private func relevantModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }


    private func observeCopiedFiles(token: UUID, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isActive, self.windowsFinderMode, self.finderCut.token == token else { return }
            self.finderCut.observe(changeCount: NSPasteboard.general.changeCount)
            if self.finderCut.isAwaitingCopy {
                if attempts > 1 { self.observeCopiedFiles(token: token, attempts: attempts - 1) }
                else { self.finderCut.cancel() }
            }
        }
    }

    private func rewrite(_ event: CGEvent, keyCode: Int, modifiers: CGEventFlags) {
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        let deviceModifiers = UInt64(NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK | NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK
            | NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK | NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK)
        let unrelated = event.flags.subtracting([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        event.flags = CGEventFlags(rawValue: unrelated.rawValue & ~deviceModifiers).union(modifiers)
    }
}
