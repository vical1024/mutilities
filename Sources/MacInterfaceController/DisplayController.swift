import AppKit
import Foundation
import Combine
import CoreGraphics
import DisplaySupport
import Darwin
import IOKit

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
    private var lastBuiltInID: CGDirectDisplayID?
    private var restartAfterStop = false
    /// After wake the built-in panel stays on for this long before the guard may switch it off again.
    static let wakeGrace: TimeInterval = 30
    private var graceUntil = Date.distantPast
    private var graceTimer: Timer?
    private var tickCount = 0

    private var screenObserver: NSObjectProtocol?

    init() {
        refreshIdleState()
        observeSleepAndWake()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.process != nil { self.restoreIfExternalGone(); return }
                self.refreshIdleState()
                // The guard exits on any failure; an external display appearing again is the cue to resume.
                if self.requested, !self.isStopping, self.builtInOn == true, self.externalCount > 0 { self.start() }
            }
        }
    }

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The guard's app-scoped change ends with the process, so the panel is on when the Mac wakes.
                self.restartAfterStop = false
                self.stop()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.graceUntil = Date().addingTimeInterval(Self.wakeGrace)
                self.restartAfterStop = false
                self.stop()
                self.scheduleStartAfterGrace()
            }
        }
    }

    private func scheduleStartAfterGrace() {
        graceTimer?.invalidate()
        guard requested else { return }
        let remaining = max(0.1, graceUntil.timeIntervalSinceNow)
        graceTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.requested, self.process == nil else { return }
                self.start()
            }
        }
    }

    /// DisplayGuard's own display list never refreshes after a hotplug, but this app's does. Once the guard has
    /// switched the panel off and the last external screen is gone, end the guard (its app-scoped change reverts)
    /// and start a fresh one.
    private func restoreIfExternalGone() {
        guard process != nil, isRunning, !isStopping, builtInOn == false, Self.externalDisplayCount() == 0 else { return }
        note("no external screen left; restarting guard to restore the built-in panel")
        restartAfterStop = requested
        stop()
        // The change is app-scoped: WindowServer turns the panel back on the moment the guard process is gone, which is
        // faster and more certain than waiting for the guard's own (display-list based) restore.
        if let process { kill(process.processIdentifier, SIGKILL) }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        graceTimer?.invalidate()
        timer?.invalidate()
    }

    private func startHeartbeat() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
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
        if graceUntil.timeIntervalSinceNow > 0 { scheduleStartAfterGrace(); return }
        error = nil
        do {
            let id = try LiveDisplayHardware.builtInID(remembered: lastBuiltInID)
            let hardware = try LiveDisplayHardware(builtInID: id)
            // An earlier guard that died without restoring leaves the panel off; turn it back on before guarding.
            if try !hardware.snapshot().builtInActive { try hardware.setBuiltInEnabled(true) }
            lastBuiltInID = id
            recoveryHardware = hardware
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
        tickCount += 1
        if tickCount % 5 == 0 { restoreIfExternalGone() }
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

    /// With the built-in panel off, unplugging the last external screen leaves WindowServer with no display to
    /// reconfigure, so NSScreen and CoreGraphics keep reporting the vanished screen. The IORegistry reflects the
    /// hardware: Apple silicon publishes one DCPAVServiceProxy with Location "External" per connected screen.
    private static func externalDisplayCount() -> Int {
        #if arch(arm64)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return -1 }
        defer { IOObjectRelease(iterator) }
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               location == "External" { count += 1 }
        }
        return count
        #else
        return NSScreen.screens.filter {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) == 0
        }.count
        #endif
    }

    private func note(_ message: String) {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: false)
            .appendingPathComponent("MacInterfaceController", isDirectory: true),
              let handle = try? FileHandle(forWritingTo: folder.appendingPathComponent("display-guard.log")) else { return }
        _ = try? handle.seekToEnd()
        handle.write(Data("\(ISO8601DateFormatter().string(from: Date())) app: \(message)\n".utf8))
        try? handle.close()
    }

    private func refreshIdleState() {
        guard let ids = try? LiveDisplayHardware.activeDisplays() else { builtInOn = nil; return }
        let builtIn = ids.contains { CGDisplayIsBuiltin($0) != 0 }
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }.count
        if builtInOn != builtIn { builtInOn = builtIn }
        if externalCount != external { externalCount = external }
    }
}
