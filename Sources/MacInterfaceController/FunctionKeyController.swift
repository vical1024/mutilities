import Foundation
import Combine
import FunctionKeySupport

protocol FunctionKeyBackend: AnyObject {
    func read() throws -> Bool
    func begin(standard: Bool) throws
    func end() throws
    var isGuarded: Bool { get }
}

final class LiveFunctionKeyBackend: FunctionKeyBackend {
    private var helper: Process?
    private var input: Pipe?
    var isGuarded: Bool { helper?.isRunning == true }
    func read() throws -> Bool { try FunctionKeyHardware.read() }

    func begin(standard: Bool) throws {
        try end()
        let original = try read()
        let process = Process()
        guard let executable = Bundle.main.executableURL else { throw FunctionKeyHardware.Failure("앱 실행 경로를 찾지 못했습니다.") }
        process.executableURL = executable.deletingLastPathComponent().appendingPathComponent("FunctionKeyRestore")
        process.arguments = [original ? "1" : "0", standard ? "1" : "0"]
        let channel = Pipe()
        let ready = Pipe()
        process.standardInput = channel
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        try process.run()
        helper = process
        input = channel
        guard ready.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8), process.isRunning else {
            try? end()
            throw FunctionKeyHardware.Failure("기능 키 복원 프로세스를 시작하지 못해 설정을 변경하지 않았습니다.")
        }
        do { try FunctionKeyHardware.write(standard) }
        catch { try? end(); throw error }
    }

    func end() throws {
        guard let helper else { return }
        input?.fileHandleForWriting.closeFile()
        helper.waitUntilExit()
        self.helper = nil
        input = nil
        guard helper.terminationStatus == 0 else {
            throw FunctionKeyHardware.Failure("기존 기능 키 모드를 복원하지 못했습니다. macOS 키보드 설정을 확인해 주세요.")
        }
    }
}

final class FunctionKeyController: ObservableObject {
    static let shared = FunctionKeyController(backend: LiveFunctionKeyBackend())
    @Published private(set) var actualStandard: Bool?
    @Published private(set) var appliedStandard: Bool?
    @Published private(set) var error: String?
    private let backend: any FunctionKeyBackend
    init(backend: any FunctionKeyBackend) { self.backend = backend; refresh() }

    func apply(_ standard: Bool?) {
        do {
            if let standard {
                let current = try backend.read()
                if appliedStandard != standard || !backend.isGuarded || current != standard {
                    try backend.begin(standard: standard)
                    appliedStandard = standard
                }
            } else {
                try backend.end()
                appliedStandard = nil
            }
            actualStandard = try backend.read()
            error = nil
        } catch {
            appliedStandard = nil
            self.error = error.localizedDescription
            actualStandard = try? backend.read()
        }
    }

    func refresh() {
        do {
            let actual = try backend.read()
            if actualStandard != actual { actualStandard = actual }
            if let appliedStandard, actualStandard != appliedStandard || !backend.isGuarded {
                error = "기능 키 적용 상태가 달라졌습니다. 다시 적용하거나 이 앱의 기능 키 설정을 해제해 주세요."
            }
        } catch { self.error = error.localizedDescription }
    }
}
