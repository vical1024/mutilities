import AppKit
import Foundation
import ServiceManagement

/// Runs the Control/Command swap below the event tap through the bundled root SwapHelper and the
/// Karabiner-DriverKit-VirtualHIDDevice virtual keyboard, so the swap also works in Secure Input
/// (password) fields. The app keeps a lease file fresh while it wants the swap; when the app quits
/// or hangs, the helper releases the keyboard by itself. While the helper is not actively holding
/// the keyboard, AppSettings keeps using the event-tap swap.
@MainActor
final class SecureInputSwapHelper {
    enum State: Equatable {
        case off                      // swap not requested, or the app was not built with the helper
        case driverMissing
        case notRegistered
        case requiresApproval
        case starting
        case inputMonitoringRequired
        case disabledByShortcut
        case waiting
        case active
    }

    static let shared = SecureInputSwapHelper()
    static let controlDirectory = "/Users/Shared/MacInterfaceController"
    static let driverDirectory = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice"
    static let driverReleasesURL = URL(string: "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases")!
    private static let plistName = "dev.local.MacInterfaceController.swaphelper.plist"

    private let service = SMAppService.daemon(plistName: plistName)
    private(set) var state: State = .off
    var onChange: ((State) -> Void)?
    private var timer: Timer?
    private var wanted = false
    private var standardFunctionKeys = true
    private var writtenFunctionKeyState: String?

    var isActive: Bool { state == .active }
    var helperPath: String { Bundle.main.bundlePath + "/Contents/MacOS/SwapHelper" }
    private var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/Library/LaunchDaemons/" + Self.plistName)
    }

    /// Called from AppSettings.apply(). Changing `wanted` starts or stops the lease; the state change
    /// is reported asynchronously so apply() is never re-entered.
    func update(wanted: Bool, standardFunctionKeys: Bool) {
        self.standardFunctionKeys = standardFunctionKeys
        writeFunctionKeyState()
        let wanted = wanted && isBundled
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        timer?.invalidate()
        timer = nil
        if wanted {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in SecureInputSwapHelper.shared.tick() }
            }
            Task { @MainActor in self.tick() }
        } else {
            // Removing the lease releases the keyboard on the helper's next 0.2 s check.
            try? FileManager.default.removeItem(atPath: path("lease"))
            setState(.off)
        }
    }

    func register() {
        do { try service.register() } catch { /* requiresApproval is reported through status */ }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        tick()
    }

    func reenable() {
        try? FileManager.default.removeItem(atPath: path("disable"))
        tick()
    }

    private func tick() {
        guard wanted else { return }
        let fd = open(path("lease"), O_CREAT | O_WRONLY, 0o666)
        if fd >= 0 { futimes(fd, nil); close(fd) }
        writeFunctionKeyState()  // retried here because the helper creates the control directory
        setState(evaluate())
    }

    private func evaluate() -> State {
        guard FileManager.default.fileExists(atPath: Self.driverDirectory) else { return .driverMissing }
        switch service.status {
        case .notRegistered, .notFound: return .notRegistered
        case .requiresApproval: return .requiresApproval
        default: break
        }
        // The helper rewrites `status` at least once a second; an old file means it is not running.
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path("status")))?[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 5,
              let text = try? String(contentsOfFile: path("status"), encoding: .utf8) else {
            healIfNeeded()
            return .starting
        }
        staleSince = nil
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "active": return .active
        case "denied": return .inputMonitoringRequired
        case "disabled": return .disabledByShortcut
        case "waiting", "idle": return .waiting
        default: return .starting
        }
    }

    /// A rebuilt app has a new binary, and launchd then refuses to start the registered daemon (EX_CONFIG)
    /// until it is registered again. A helper that stays silent while approved is re-registered.
    private var staleSince: Date?
    private var lastHeal: Date?
    private func healIfNeeded() {
        let now = Date()
        if staleSince == nil { staleSince = now }
        guard service.status == .enabled, now.timeIntervalSince(staleSince!) > 10,
              lastHeal.map({ now.timeIntervalSince($0) > 120 }) ?? true else { return }
        lastHeal = now
        let service = service
        Task.detached {
            try? await service.unregister()
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // registering immediately after is rejected
            try? service.register()
        }
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        Task { @MainActor in self.onChange?(newState) }
    }

    /// Mirrors macOS' F-key mode so the helper maps Fn+F1… (or F1…) to media keys like an Apple keyboard.
    private func writeFunctionKeyState() {
        let value = standardFunctionKeys ? "on" : "off"
        guard value != writtenFunctionKeyState,
              (try? (value + "\n").write(toFile: path("fnstate"), atomically: true, encoding: .utf8)) != nil else { return }
        writtenFunctionKeyState = value
    }

    private func path(_ name: String) -> String { Self.controlDirectory + "/" + name }
}
