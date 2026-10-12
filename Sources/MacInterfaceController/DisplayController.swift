import AppKit
import Foundation
import Combine
import CoreGraphics
import DisplaySupport
import Darwin

@MainActor
final class DisplayController: ObservableObject {
    static let shared = DisplayController()
    @Published private(set) var builtInOn: Bool?
    @Published private(set) var externalCount = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var error: String?
    private var requested = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var timer: Timer?
    private var lastResponse: TimeInterval = 0
    private var stopStarted: TimeInterval?
    private var recoveryHardware: LiveDisplayHardware?
    private var restartAfterStop = false

    private var screenObserver: NSObjectProtocol?

    init() {
        refreshIdleState()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process == nil else { return }
                self.refreshIdleState()
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        timer?.invalidate()
    }

    private func startHeartbeat() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopHeartbeat() {
        timer?.invalidate()
        timer = nil
    }

    func apply(_ enabled: Bool) {
        guard requested != enabled else { return }
        requested = enabled
        if enabled {
            if process != nil { restartAfterStop = true }
            else { start() }
        } else {
            restartAfterStop = false
            stop()
        }
    }

    func retry() {
        guard requested else { return }
        error = nil
        if process != nil { restartAfterStop = true; stop() }
        else { start() }
    }

    func shutdown() {
        requested = false
        restartAfterStop = false
        // EOF restoration is independent of the app's termination/run loop.
        stop()
    }

    private func start() {
        error = nil
        do {
            let id = try LiveDisplayHardware.activeBuiltInID()
            recoveryHardware = try LiveDisplayHardware(builtInID: id)
            guard let executable = Bundle.main.executableURL else { throw DisplayFailure("앱 실행 경로를 찾지 못했습니다.") }
            let child = Process()
            child.executableURL = executable.deletingLastPathComponent().appendingPathComponent("DisplayGuard")
            child.arguments = [String(id)]
            let input = Pipe(), output = Pipe()
            // Never block the UI or die on a broken pipe if the helper has exited.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1,
                  fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK) != -1,
                  fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
                throw DisplayFailure("화면 복구 프로세스의 안전한 연결을 준비하지 못했습니다.")
            }
            child.standardInput = input
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            try child.run()
            self.process = child
            self.input = input
            self.output = output
            buffer.removeAll()
            lastResponse = ProcessInfo.processInfo.systemUptime
            stopStarted = nil
            isStopping = false
            startHeartbeat()
            tick()
        } catch {
            self.error = error.localizedDescription
            isRunning = false
        }
    }

    private func stop() {
        guard process != nil, stopStarted == nil else { return }
        isStopping = true
        isRunning = false
        stopStarted = ProcessInfo.processInfo.systemUptime
        input?.fileHandleForWriting.closeFile()
        input = nil
    }

    private func tick() {
        guard let process else { stopHeartbeat(); return }
        readMessages()
        let now = ProcessInfo.processInfo.systemUptime
        if !process.isRunning {
            readMessages()
            let expected = stopStarted != nil
            if !expected && error == nil { error = "화면 제어 프로세스가 종료되었습니다. 내장 화면을 복구하고 자동 끄기를 중지했습니다." }
            // Covers a helper crash independently of its own cleanup code.
            do { try recoveryHardware?.setBuiltInEnabled(true) }
            catch { self.error = "내장 화면 복구를 확인하지 못했습니다: " + error.localizedDescription }
            input?.fileHandleForWriting.closeFile()
            output?.fileHandleForReading.closeFile()
            self.process = nil
            stopHeartbeat()
            input = nil
            output = nil
            isRunning = false
            isStopping = false
            stopStarted = nil
            refreshIdleState()
            if restartAfterStop && requested {
                restartAfterStop = false
                start()
            }
            return
        }
        if let stopStarted {
            // If even the helper stops responding, release its app-scoped changes.
            if now - stopStarted > 4 { _ = kill(process.processIdentifier, SIGKILL) }
            else if now - stopStarted > 2 { process.terminate() }
            return
        }
        if now - lastResponse > 5 {
            error = "화면 제어의 응답이 끊겨 내장 화면 복구를 실행합니다. 자동 끄기를 다시 켜 주세요."
            stop()
            return
        }
        if let input {
            var ping: UInt8 = 112
            if Darwin.write(input.fileHandleForWriting.fileDescriptor, &ping, 1) != 1 {
                error = "화면 복구 프로세스와 연결이 끊겼습니다."
                stop()
            }
        }
    }

    private func readMessages() {
        guard let output else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count <= 0 { break }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        guard buffer.count <= 65536 else { error = "화면 제어 상태를 읽지 못했습니다."; stop(); buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            lastResponse = ProcessInfo.processInfo.systemUptime
            if line == "ready" { isRunning = !isStopping }
            else if line == "restored" { builtInOn = true }
            else if line.hasPrefix("error ") { error = String(line.dropFirst(6)); stop() }
            else if line.hasPrefix("state ") {
                let parts = line.split(separator: " ")
                if parts.count == 3 {
                    let builtIn = parts[1] == "on", external = Int(parts[2]) ?? 0
                    if builtInOn != builtIn { builtInOn = builtIn }
                    if externalCount != external { externalCount = external }
                }
            }
        }
    }

    private func refreshIdleState() {
        guard let ids = try? LiveDisplayHardware.activeDisplays() else { builtInOn = nil; return }
        let builtIn = ids.contains { CGDisplayIsBuiltin($0) != 0 }
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }.count
        if builtInOn != builtIn { builtInOn = builtIn }
        if externalCount != external { externalCount = external }
    }
}
