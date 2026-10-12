import Carbon
import Foundation

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var references: [EventHotKeyRef] = []
    private(set) var registeredRuleIDs: Set<UUID> = []
    private var actions: [UInt32: ShortcutRule] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x4D49434B // "MICK"

    private init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                Task { @MainActor in
                    HotKeyCenter.shared.fire(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
    }

    func configure(_ rules: [ShortcutRule]) -> String? {
        stop()
        var failures: [String] = []

        let active = rules.filter(\.isEnabled)
        let counts = Dictionary(grouping: active) { "\($0.key.rawValue):\($0.carbonModifiers)" }
        for rule in active {
            guard counts["\(rule.key.rawValue):\(rule.carbonModifiers)"]?.count == 1 else {
                failures.append("\(rule.displayText) (앱 내부 중복)")
                continue
            }
            if rule.action == .toggleApplication && !rule.targetApplication.isConfigured {
                failures.append("\(rule.displayText): 표시할 앱을 선택해 주세요.")
                continue
            }
            if rule.action == .macro {
                do {
                    guard let macro = rule.macro else { throw ProfileError.invalid("입력 순서 없음") }
                    try macro.validate()
                } catch {
                    failures.append("\(rule.displayText): \(error.localizedDescription)")
                    continue
                }
            }
            let id = nextID
            nextID &+= 1
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: id)
            let status = RegisterEventHotKey(
                rule.key.keyCode,
                rule.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                references.append(reference)
                registeredRuleIDs.insert(rule.id)
                actions[id] = rule
            } else {
                failures.append(rule.displayText)
            }
        }

        return failures.isEmpty ? nil : "등록하지 못한 단축키: \(failures.joined(separator: ", "))"
    }

    func stop() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        registeredRuleIDs.removeAll()
        actions.removeAll()
    }

    private func fire(id: UInt32) {
        guard !MacroRunner.shared.isRunning, let action = actions[id] else { return }
        ActionRunner.run(action)
    }
}
