import AppKit
import Carbon
import Foundation

@MainActor
protocol MacroBackend {
    var canPost: Bool { get }
    var frontmostPID: pid_t? { get }
    func triggerReleased(_ key: ShortcutKey) -> Bool
    func send(_ step: MacroStep) throws
    func sleep(milliseconds: Int) async throws
}

struct LiveMacroBackend: MacroBackend {
    nonisolated init() {}
    nonisolated static let eventTag: Int64 = 0x4D49434D4143524F
    var canPost: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func triggerReleased(_ key: ShortcutKey) -> Bool {
        !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode))
            && CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    func send(_ step: MacroStep) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(step.key.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(step.key.keyCode), keyDown: false) else {
            throw ProfileError.invalid("매크로 키 입력을 만들지 못했습니다.")
        }
        var flags: CGEventFlags = []
        for modifier in step.modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .shift: flags.insert(.maskShift)
            }
        }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.post(tap: .cgSessionEventTap)
        }
    }

    func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

// All access occurs on the main run loop, including the CGEvent tap's Escape handler.
final class MacroRunner: ObservableObject {
    static let shared = MacroRunner(backend: LiveMacroBackend())
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    private var task: Task<Void, Never>?
    private let backend: any MacroBackend
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    init(backend: any MacroBackend) { self.backend = backend }

    @MainActor
    func start(_ macro: KeyMacro, trigger: ShortcutKey) {
        guard !isRunning else { return }
        do {
            try macro.validate()
            guard backend.canPost else { throw ProfileError.invalid("키 입력 매크로에는 접근성 권한이 필요합니다.") }
            guard let pid = backend.frontmostPID else { throw ProfileError.invalid("매크로를 실행할 앱을 찾지 못했습니다.") }
            isRunning = true
            status = "단축키에서 손을 떼면 매크로를 시작합니다. Esc로 중지할 수 있습니다."
            onStart?() // Unregister global shortcuts before generating events; prevents recursive macros.
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isRunning = false
                    self.task = nil
                    self.onFinish?()
                }
                do {
                    var released = false
                    for _ in 0..<40 {
                        try Task.checkCancellation()
                        if self.backend.triggerReleased(trigger) { released = true; break }
                        try await self.backend.sleep(milliseconds: 50)
                    }
                    guard released else { throw ProfileError.invalid("단축키가 계속 눌려 있어 매크로를 취소했습니다.") }
                    for (index, step) in macro.steps.enumerated() {
                        try Task.checkCancellation()
                        guard self.backend.frontmostPID == pid else {
                            throw ProfileError.invalid("다른 앱으로 이동해 매크로를 중지했습니다.")
                        }
                        guard self.backend.canPost else { throw ProfileError.invalid("입력 권한이 없어 매크로를 중지했습니다.") }
                        self.status = "매크로 실행 중: \(index + 1)/\(macro.steps.count) · Esc로 중지"
                        if step.kind == .key { try self.backend.send(step) }
                        try await self.backend.sleep(milliseconds: max(step.milliseconds, step.kind == .key ? 20 : 0))
                    }
                    // Drain the last generated event before restoring global shortcuts.
                    try await self.backend.sleep(milliseconds: 100)
                    self.status = "매크로 실행 완료"
                } catch is CancellationError { self.status = "매크로를 중지했습니다." }
                catch { self.status = error.localizedDescription }
            }
        } catch { status = error.localizedDescription }
    }

    func cancel() { task?.cancel() }

    @MainActor
    func waitUntilFinished() async { await task?.value }
}
