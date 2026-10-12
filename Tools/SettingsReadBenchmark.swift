import Foundation

/// Read-only comparison; never writes preferences, restarts Dock, or changes HID.
@main
struct SettingsReadBenchmark {
    static func main() throws {
        let backend = LocalSystemSettingsBackend()
        var fullTimes: [Double] = [], dockTimes: [Double] = []
        for _ in 0..<3 {
            var start = ProcessInfo.processInfo.systemUptime
            let full = try backend.capture()
            fullTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            start = ProcessInfo.processInfo.systemUptime
            let dock = try backend.captureDock()
            dockTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let expected = SystemSettingsBackup(createdAt: Date(), machineName: "benchmark",
                preferences: full.preferences.filter { $0.address.domain == "com.apple.dock" && SystemDefaultsService.dockKeys.contains($0.address.key) }, hidMappings: [])
            let actual = SystemSettingsBackup(createdAt: Date(), machineName: "benchmark", preferences: dock, hidMappings: [])
            guard try actual.hasSameSettings(as: expected) else {
                throw SystemDefaultsError.commandFailed("Dock changed during the read-only benchmark; rerun when settings are stable.")
            }
        }
        print("Matching Dock values across 3 read-only comparisons")
        print("Full capture milliseconds: \(fullTimes.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
        print("Dock-only milliseconds: \(dockTimes.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
    }
}
