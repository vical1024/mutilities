import Foundation

public struct DisplaySnapshot: Equatable {
    public var builtInActive: Bool
    public var externalIDs: Set<UInt32>
    public init(builtInActive: Bool, externalIDs: Set<UInt32>) {
        self.builtInActive = builtInActive
        self.externalIDs = externalIDs
    }
}

public protocol DisplayHardware: AnyObject {
    func snapshot() throws -> DisplaySnapshot
    /// Implementations must verify the result, and recheck externals before disabling.
    func setBuiltInEnabled(_ enabled: Bool) throws
}

/// Runs only in the display-owning helper. No persisted "off" state exists.
public final class DisplaySession {
    public static let heartbeatTimeout: TimeInterval = 8
    public static let connectionDelay: TimeInterval = 2
    private let hardware: any DisplayHardware
    private var lastHeartbeat: TimeInterval
    private var externalIDs: Set<UInt32> = []
    private var stableSince: TimeInterval?
    private var restorationRequired = false
    public private(set) var stopped = false

    public init(hardware: any DisplayHardware, now: TimeInterval) {
        self.hardware = hardware
        lastHeartbeat = now
    }

    public func heartbeat(now: TimeInterval) { lastHeartbeat = now }

    public func tick(now: TimeInterval) throws -> DisplaySnapshot {
        guard !stopped else { return try hardware.snapshot() }
        guard now - lastHeartbeat < Self.heartbeatTimeout else {
            try stop()
            throw DisplayFailure("앱의 응답이 끊겨 내장 화면 복구를 실행했습니다. 자동 끄기를 다시 켜 주세요.")
        }
        do {
            let state = try hardware.snapshot()
            if state.externalIDs.isEmpty {
                stableSince = nil
                externalIDs = []
                if restorationRequired || !state.builtInActive {
                    try hardware.setBuiltInEnabled(true)
                    restorationRequired = false
                }
            } else {
                if state.externalIDs != externalIDs {
                    externalIDs = state.externalIDs
                    stableSince = now
                }
                if state.builtInActive, let stableSince, now - stableSince >= Self.connectionDelay {
                    // Set before calling: even a failed API call can partially change hardware.
                    restorationRequired = true
                    try hardware.setBuiltInEnabled(false)
                    // Cable removal may race the configuration transaction.
                    if try hardware.snapshot().externalIDs.isEmpty {
                        try hardware.setBuiltInEnabled(true)
                        restorationRequired = false
                        self.stableSince = nil
                        externalIDs = []
                    }
                }
            }
            return try hardware.snapshot()
        } catch {
            let cause = error.localizedDescription
            do { try stop() }
            catch { throw DisplayFailure(cause + " / 복구 실패: " + error.localizedDescription) }
            throw DisplayFailure(cause)
        }
    }

    public func stop() throws {
        stopped = true
        // Always attempt ON on stop, including an earlier failed restore.
        try hardware.setBuiltInEnabled(true)
        restorationRequired = false
    }
}

public struct DisplayFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
