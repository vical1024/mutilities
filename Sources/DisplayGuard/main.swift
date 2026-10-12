import Foundation
import DisplaySupport
import Darwin

// This process owns the temporary display configuration. Its stdin is a private
// pipe from the UI process. EOF, timeout and signals all take the restore path.
// SIGKILL cannot be handled; .forAppOnly provides the WindowServer fallback.
signal(SIGPIPE, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGHUP, SIG_IGN)
let signalQueue = DispatchQueue(label: "display-guard-signals")
let signalLock = NSLock()
var interrupted = false
let signals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler { signalLock.lock(); interrupted = true; signalLock.unlock() }
    source.resume()
    return source
}

func emit(_ message: String) {
    // A broken stdout must not interrupt restoration.
    let bytes = Array((message + "\n").utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
}

let args = CommandLine.arguments
guard args.count == 2, let id = UInt32(args[1]) else { exit(2) }
var session: DisplaySession?
let startedAt = ProcessInfo.processInfo.systemUptime
do {
    // Prevent separate app instances from owning conflicting display leases.
    let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
        .appendingPathComponent("MacInterfaceController", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let lockFD = open(folder.appendingPathComponent("display-guard.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        throw DisplayFailure("다른 화면 제어 프로세스가 이미 실행 중입니다. 잠시 후 다시 시도해 주세요.")
    }
    // Keep the descriptor open until process exit, including restoration.
    let hardware = try LiveDisplayHardware(builtInID: id)
    guard try hardware.snapshot().builtInActive else { throw DisplayFailure("내장 화면이 켜진 상태에서만 자동 끄기를 시작할 수 있습니다.") }
    let activeSession = DisplaySession(hardware: hardware, now: ProcessInfo.processInfo.systemUptime)
    session = activeSession
    emit("ready")
    var receivedHeartbeat = false
    while true {
        signalLock.lock(); let shouldStop = interrupted; signalLock.unlock()
        if shouldStop { break }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        let result = poll(&descriptor, 1, 250)
        if result < 0 {
            if errno == EINTR { continue }
            throw DisplayFailure("앱 연결 감시가 중단되었습니다.")
        }
        let now = ProcessInfo.processInfo.systemUptime
        if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { break }
            guard count > 0, bytes.prefix(count).allSatisfy({ $0 == 112 }) else { throw DisplayFailure("앱 연결 신호가 올바르지 않습니다.") }
            activeSession.heartbeat(now: now)
            receivedHeartbeat = true
        }
        if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { break }
        // Do not disable until the parent has successfully established its timer.
        let snapshot: DisplaySnapshot
        if receivedHeartbeat { snapshot = try activeSession.tick(now: now) }
        else {
            if now - startedAt >= DisplaySession.heartbeatTimeout { throw DisplayFailure("앱의 시작 신호를 받지 못했습니다.") }
            snapshot = try hardware.snapshot()
        }
        let state = "state \(snapshot.builtInActive ? "on" : "off") \(snapshot.externalIDs.count)"
        emit(state)
        // Pump WindowServer notifications without depending on the app's run loop.
        RunLoop.current.run(until: Date())
    }
    try activeSession.stop()
    emit("restored")
    exit(0)
} catch {
    emit("error " + error.localizedDescription.replacingOccurrences(of: "\n", with: " "))
    // Retry independently of the UI, then exit to release app-scoped configuration.
    if let session {
        for _ in 0..<5 {
            do { try session.stop(); emit("restored"); exit(1) }
            catch { Thread.sleep(forTimeInterval: 0.2) }
        }
    }
    exit(1)
}
