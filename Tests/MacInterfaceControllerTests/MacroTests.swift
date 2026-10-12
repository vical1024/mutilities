import AppKit
import Carbon
import Foundation
import Testing
@testable import MacInterfaceController

@MainActor
private final class RecordingMacroBackend: MacroBackend {
    var canPost = true
    var frontmostPID: pid_t? = 10
    var released = true
    var events: [String] = []
    var onSleep: (() -> Void)?
    func triggerReleased(_ key: ShortcutKey) -> Bool { released }
    func send(_ step: MacroStep) throws { events.append("key:\(step.key.rawValue)") }
    func sleep(milliseconds: Int) async throws {
        events.append("wait:\(milliseconds)")
        onSleep?()
        await Task.yield()
        try Task.checkCancellation()
    }
}

@MainActor
struct MacroTests {
    private var sample: KeyMacro {
        KeyMacro(steps: [MacroStep(key: .c, modifiers: [.command], milliseconds: 50),
                         MacroStep(kind: .wait, milliseconds: 300),
                         MacroStep(key: .v, modifiers: [.command], milliseconds: 100)])
    }

    @Test func macroRunsInOrderAndDoesNotReenter() async {
        let backend = RecordingMacroBackend()
        let runner = MacroRunner(backend: backend)
        runner.onStart = { backend.events.append("suspend") }
        runner.onFinish = { backend.events.append("restore") }
        runner.start(sample, trigger: .k)
        runner.start(sample, trigger: .k)
        await runner.waitUntilFinished()
        #expect(backend.events == ["suspend", "key:c", "wait:50", "wait:300", "key:v", "wait:100", "wait:100", "restore"])
        #expect(!runner.isRunning)
    }

    @Test func cancellationStopsBeforeNextKeyAndRestoresShortcuts() async {
        let backend = RecordingMacroBackend()
        let runner = MacroRunner(backend: backend)
        backend.onSleep = { runner.cancel() }
        runner.onFinish = { backend.events.append("restore") }
        runner.start(sample, trigger: .k)
        await runner.waitUntilFinished()
        #expect(backend.events == ["key:c", "wait:50", "restore"])
        #expect(runner.status == "매크로를 중지했습니다.")
    }

    @Test func changingTargetAppStopsSequence() async {
        let backend = RecordingMacroBackend()
        let runner = MacroRunner(backend: backend)
        backend.onSleep = { backend.frontmostPID = 20 }
        runner.start(sample, trigger: .k)
        await runner.waitUntilFinished()
        #expect(!backend.events.contains("key:v"))
        #expect(runner.status?.contains("다른 앱") == true)
    }

    @Test func deniedPermissionDoesNotSuspendOrSendAnything() async {
        let backend = RecordingMacroBackend()
        backend.canPost = false
        let runner = MacroRunner(backend: backend)
        runner.onStart = { backend.events.append("suspend") }
        runner.start(sample, trigger: .k)
        await runner.waitUntilFinished()
        #expect(backend.events.isEmpty)
        #expect(!runner.isRunning)
        #expect(runner.status?.contains("권한") == true)
    }

    @Test func heldTriggerTimesOutWithoutTyping() async {
        let backend = RecordingMacroBackend()
        backend.released = false
        let runner = MacroRunner(backend: backend)
        runner.start(sample, trigger: .k)
        await runner.waitUntilFinished()
        #expect(!backend.events.contains(where: { $0.hasPrefix("key:") }))
        #expect(runner.status?.contains("계속 눌려") == true)
    }

    @Test func macrosRejectEmptyAndExcessiveWaits() {
        #expect(throws: (any Error).self) { try KeyMacro().validate() }
        let tooLong = KeyMacro(steps: [MacroStep(milliseconds: 5001)])
        #expect(throws: (any Error).self) { try tooLong.validate() }
        let total = KeyMacro(steps: (0..<7).map { _ in MacroStep(milliseconds: 5000) })
        #expect(throws: (any Error).self) { try total.validate() }
    }

    @Test func legacyShortcutWithoutMacroStillDecodes() throws {
        let json = #"{"id":"9966FC84-D58B-497D-89E7-4DD2EDE9E828","isEnabled":true,"key":"space","modifiers":["shift"],"action":"toggleInputSource"}"#
        let rule = try JSONDecoder().decode(ShortcutRule.self, from: Data(json.utf8))
        #expect(rule.macro == nil)
        #expect(rule.displayText == "⇧Space")
    }

    @Test func macroRoundTripsThroughPortableProfile() throws {
        var namedMacro = sample
        namedMacro.name = "복사 후 붙여넣기"
        let rule = ShortcutRule(key: .k, modifiers: [.control, .shift], action: .macro, macro: namedMacro)
        let profile = PortableProfile(name: "Macros", shortcuts: [rule], corners: CornerPosition.allCases.map {
            HotCornerRule(position: $0, isEnabled: false, dwellSeconds: 0.35, action: .finder)
        }, swapCommandControl: true, windowsFinderMode: true, windowSwitcherEnabled: true)
        #expect(try PortableProfile.decode(profile.encoded()) == profile)
        #expect(rule.actionTitle == "복사 후 붙여넣기")
    }

    @Test func existingMacroWithoutNameKeepsItsStepsAndLibraryAfterMigration() throws {
        let original = ShortcutRule(key: .k, modifiers: [.control, .shift], action: .macro, macro: sample)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var macroJSON = try #require(json["macro"] as? [String: Any])
        macroJSON.removeValue(forKey: "name")
        json["macro"] = macroJSON
        let decoded = try JSONDecoder().decode(ShortcutRule.self, from: JSONSerialization.data(withJSONObject: json))
        let migrated = KeyboardTemplates.migrating([decoded])
        #expect(migrated.filter(ShortcutLibrary.macros.includes) == [original])
        #expect(migrated.filter(ShortcutLibrary.shortcuts.includes).isEmpty)
        #expect(decoded.actionTitle == AppAction.macro.title)
        #expect(decoded.macro?.validationError == nil)
    }

    @Test func dormantMacroDataDoesNotMoveAnOrdinaryShortcutToMacros() {
        let shortcut = ShortcutRule(key: .k, modifiers: [.option], action: .finder, macro: sample)
        #expect(ShortcutLibrary.shortcuts.includes(shortcut))
        #expect(!ShortcutLibrary.macros.includes(shortcut))
        var unnamed = sample
        unnamed.name = " \n "
        #expect(ShortcutRule(key: .k, modifiers: [.option], action: .macro, macro: unnamed).actionTitle == AppAction.macro.title)
        #expect(KeyMacro().validationError != nil)
        #expect(KeyMacro(steps: [MacroStep(kind: .wait)]).validationError != nil)
    }

    @Test func invalidLargeWaitIsRejectedWithoutOverflow() {
        let macro = KeyMacro(steps: [MacroStep(milliseconds: Int.max), MacroStep(milliseconds: Int.max)])
        #expect(macro.validationError != nil)
    }

    @Test func syntheticMacroKeysAreNotRemappedAgain() throws {
        let engine = KeyboardRemappingEngine(swapCommandControl: true)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true))
        event.flags = [.maskCommand]
        event.setIntegerValueField(.eventSourceUserData, value: LiveMacroBackend.eventTag)
        _ = engine.transform(type: .keyDown, event: event, finderContext: .otherApplication)
        #expect(event.flags == [.maskCommand])
    }
}
