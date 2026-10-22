import AppKit
import Foundation

/// Opens the Finder location in the terminal chosen under "Finder 연동" (used by the shortcut action).
@MainActor
final class OpenInTerminalController: ObservableObject {
    static let shared = OpenInTerminalController()
    @Published private(set) var lastError: String?

    func open() {
        lastError = nil
        Task { [weak self] in
            let output = await Self.readFinderLocation()
            guard let self else { return }
            switch output {
            case .failure(let failure): self.fail(failure.description)
            case .success(let text):
                let directories = FinderLocation.directories(fromScriptOutput: text)
                FinderActionRunner.openInTerminal(directories, bundleID: FinderPreferences.terminalBundleID()) { [weak self] message in
                    if let message { Task { @MainActor in self?.fail(message) } }
                }
            }
        }
    }

    private func fail(_ message: String) {
        lastError = message
        NSSound.beep()
        NSLog("Finder 위치 열기 실패: %@", message)
    }

    /// Apple Events block, so keep them off the main thread. Automation consent is requested for this app.
    private nonisolated static func readFinderLocation() async -> Result<String, ScriptFailure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorInfo: NSDictionary?
                guard let script = NSAppleScript(source: FinderLocation.script) else {
                    continuation.resume(returning: .failure(ScriptFailure("Finder 조회 스크립트를 만들지 못했습니다.")))
                    return
                }
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let number = errorInfo[NSAppleScript.errorNumber] as? Int
                    let message = number == -1743
                        ? "Finder 제어 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 허용해 주세요."
                        : "Finder 위치를 읽지 못했습니다. (\(errorInfo[NSAppleScript.errorMessage] as? String ?? "알 수 없는 오류"))"
                    continuation.resume(returning: .failure(ScriptFailure(message)))
                } else {
                    continuation.resume(returning: .success(result.stringValue ?? ""))
                }
            }
        }
    }
}

private struct ScriptFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
