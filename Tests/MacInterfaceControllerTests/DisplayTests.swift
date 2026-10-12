import Foundation
import Testing
import DisplaySupport

private final class MemoryDisplays: DisplayHardware {
    var state = DisplaySnapshot(builtInActive: true, externalIDs: [])
    var writes: [Bool] = []
    var failRead = false
    var failDisable = false
    var failRestore = false
    var detachDuringDisable = false
    func snapshot() throws -> DisplaySnapshot {
        if failRead { throw DisplayFailure("snapshot failed") }
        return state
    }
    func setBuiltInEnabled(_ enabled: Bool) throws {
        writes.append(enabled)
        if enabled && failRestore { throw DisplayFailure("restore failed") }
        state.builtInActive = enabled
        if !enabled && detachDuringDisable { state.externalIDs = [] }
        if !enabled && failDisable { throw DisplayFailure("partial disable failure") }
    }
}

struct DisplayTests {
    @Test func noExternalNeverDisablesInternal() throws {
        let hardware = MemoryDisplays()
        let session = DisplaySession(hardware: hardware, now: 0)
        for time in [0.0, 1, 5, 10] {
            session.heartbeat(now: time)
            #expect(try session.tick(now: time).builtInActive)
        }
        #expect(hardware.writes.isEmpty)
    }

    @Test func stableExternalDisablesAndDisconnectRestores() throws {
        let hardware = MemoryDisplays()
        let session = DisplaySession(hardware: hardware, now: 0)
        hardware.state.externalIDs = [2]
        #expect(try session.tick(now: 0).builtInActive)
        #expect(try session.tick(now: 1.9).builtInActive)
        #expect(try !session.tick(now: 2).builtInActive)
        hardware.state.externalIDs = []
        #expect(try session.tick(now: 2.1).builtInActive)
        #expect(hardware.writes == [false, true])
    }

    @Test func oneOfMultipleExternalsCanDisconnect() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2, 3]
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        _ = try session.tick(now: 2)
        hardware.state.externalIDs = [3]
        #expect(try !session.tick(now: 2.2).builtInActive)
        hardware.state.externalIDs = []
        #expect(try session.tick(now: 2.3).builtInActive)
    }

    @Test func connectionFlappingRestartsSettlingPeriod() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        hardware.state.externalIDs = []
        _ = try session.tick(now: 1)
        hardware.state.externalIDs = [2]
        _ = try session.tick(now: 1.1)
        #expect(try session.tick(now: 2.1).builtInActive)
        #expect(try !session.tick(now: 3.2).builtInActive)
    }

    @Test func replacingExternalAlsoRestartsSettlingPeriod() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        hardware.state.externalIDs = [3]
        _ = try session.tick(now: 1.5)
        #expect(try session.tick(now: 2).builtInActive)
        #expect(try !session.tick(now: 3.5).builtInActive)
    }

    @Test func cableRemovalRacingDisableImmediatelyRestores() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        hardware.detachDuringDisable = true
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        #expect(try session.tick(now: 2).builtInActive)
        #expect(hardware.writes == [false, true])
    }

    @Test func partialDisableFailureRestoresAndLatchesStopped() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        hardware.failDisable = true
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        #expect(throws: DisplayFailure.self) { try session.tick(now: 2) }
        #expect(hardware.state.builtInActive)
        #expect(hardware.writes == [false, true])
        #expect(session.stopped)
        _ = try session.tick(now: 3)
        #expect(hardware.writes == [false, true])
    }

    @Test func unreadableTopologyAttemptsRestoreInsteadOfDisabling() {
        let hardware = MemoryDisplays()
        hardware.failRead = true
        let session = DisplaySession(hardware: hardware, now: 0)
        #expect(throws: DisplayFailure.self) { try session.tick(now: 0) }
        #expect(hardware.writes == [true])
        #expect(session.stopped)
    }

    @Test func stoppedHeartbeatRestoresEvenWithExternalAttached() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        _ = try session.tick(now: 2)
        #expect(throws: DisplayFailure.self) { try session.tick(now: 8) }
        #expect(hardware.state.builtInActive)
        #expect(session.stopped)
        session.heartbeat(now: 9)
        _ = try session.tick(now: 10)
        #expect(hardware.writes == [false, true])
    }

    @Test func renewedHeartbeatKeepsSessionAlive() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        _ = try session.tick(now: 2)
        session.heartbeat(now: 7)
        #expect(try !session.tick(now: 9).builtInActive)
        #expect(!session.stopped)
    }

    @Test func explicitStopRestoresAndNeverReapplies() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        _ = try session.tick(now: 2)
        try session.stop()
        #expect(try session.tick(now: 3).builtInActive)
        #expect(hardware.writes == [false, true])
    }

    @Test func failedRestoreCanBeRetriedAfterStop() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        _ = try session.tick(now: 2)
        hardware.failRestore = true
        #expect(throws: DisplayFailure.self) { try session.stop() }
        #expect(session.stopped)
        #expect(!hardware.state.builtInActive)
        hardware.failRestore = false
        try session.stop()
        #expect(hardware.state.builtInActive)
    }

    @Test func restoreFailureIsReportedAlongWithOriginalFailure() throws {
        let hardware = MemoryDisplays()
        hardware.state.externalIDs = [2]
        hardware.failDisable = true
        hardware.failRestore = true
        let session = DisplaySession(hardware: hardware, now: 0)
        _ = try session.tick(now: 0)
        do { _ = try session.tick(now: 2); Issue.record("Expected error") }
        catch {
            #expect(error.localizedDescription.contains("partial disable failure"))
            #expect(error.localizedDescription.contains("restore failed"))
        }
    }
}
