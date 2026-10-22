import AppKit
import Foundation

/// Keeps the last few days of input-source diagnostics on disk; the unified log drops info messages quickly.
final class InputSourceFileLog: @unchecked Sendable {
    static let shared = InputSourceFileLog()

    static let retention: TimeInterval = 3 * 24 * 3600
    private let url: URL
    private let queue = DispatchQueue(label: "dev.local.MacInterfaceController.input-source-log", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacInterfaceController/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("input-source.log")
    }

    /// Call once at launch: drops old lines and starts recording which app is in front.
    func start() {
        queue.async { [self] in prune() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.write("activate \(app?.bundleIdentifier ?? "-")")
        }
        write("launch pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { [self] in
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private func prune() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            guard let stamp = line.split(separator: " ", maxSplits: 1).first,
                  let date = formatter.date(from: String(stamp)) else { return false }
            return date >= cutoff
        }
        try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }
}
