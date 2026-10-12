import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    enum SetupPhase: String { case needsSetup, awaitingVerification, ready }

    @Published var engineEnabled: Bool { didSet { persistAndApply() } }
    @Published var shortcuts: [ShortcutRule] { didSet { persistAndApply() } }
    @Published var corners: [HotCornerRule] { didSet { persistAndApply() } }
    @Published var swapCommandControl: Bool { didSet { persistAndApply() } }
    @Published var windowsFinderMode: Bool { didSet { persistAndApply() } }
    @Published var finderFeatures: Set<FinderFeature> { didSet { persistAndApply() } }
    @Published var windowSwitcherEnabled: Bool { didSet { persistAndApply() } }
    @Published var standardFunctionKeys: Bool? { didSet { persistAndApply() } }
    @Published var autoDisableBuiltInDisplay: Bool { didSet { persistAndApply() } }
    @Published private(set) var dockConfiguration: DockConfiguration?
    @Published private(set) var history: [SettingsSnapshot] = []
    @Published private(set) var historyError: String?
    @Published private(set) var historyMessage: String?
    @Published private(set) var sessionReady = false
    private var startupTask: Task<Void, Never>?
    private lazy var dockUpdates = LatestSettingsUpdate<DockConfiguration?>(
        write: { try await SettingsHistory.shared.applyDock($0) },
        onError: { [weak self] error in self?.historyError = error.localizedDescription })
    private var terminating = false
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var shortcutError: String?
    @Published private(set) var activeShortcutIDs: Set<UUID> = []
    @Published private(set) var remappingError: String?
    @Published private(set) var remappingActive = false
    @Published private(set) var engineRunning = false
    @Published private(set) var accessibilityGranted = KeyboardRemappingEngine.shared.accessibilityGranted
    @Published private(set) var inputMonitoringGranted = KeyboardRemappingEngine.shared.inputMonitoringGranted
    @Published private(set) var setupPhase: SetupPhase
    @Published private(set) var systemState: ManagedSettingsState?
    @Published private(set) var setupError: String?
    @Published private(set) var isWorking = false
    @Published private(set) var conflictReport: ConflictReport?
    @Published private(set) var isScanning = false
    @Published private(set) var inputSourceWarning: String?

    private let defaults = UserDefaults.standard
    private var hasFinishedInitialization = false
    private var keyMappingState: KeyMappingState?
    private var isInspectingSystem = false
    private var systemGeneration = UUID()
    private var configurationRevision = UUID()
    private var monitor: Task<Void, Never>?
    private var systemMonitor: Task<Void, Never>?

    var requiresInputPermissions: Bool {
        swapCommandControl || (windowsFinderMode && !finderFeatures.isEmpty) || windowSwitcherEnabled
            || shortcuts.contains { $0.isEnabled && $0.action == .macro }
    }

    var profile: PortableProfile {
        PortableProfile(name: "내 키 설정", shortcuts: shortcuts, corners: corners,
                        swapCommandControl: swapCommandControl, windowsFinderMode: windowsFinderMode,
                        windowSwitcherEnabled: windowSwitcherEnabled, standardFunctionKeys: standardFunctionKeys, finderFeatures: finderFeatures)
    }

    var statusText: String {
        if isWorking { return "설정 변경 중" }
        if !sessionReady { return "시작 백업 확인 필요" }
        if MacroRunner.shared.isRunning { return "매크로 실행 중" }
        if !engineEnabled { return "꺼짐" }
        if setupPhase != .ready { return activeShortcutIDs.isEmpty ? "초기 설정 필요" : "한/영 실행 · 초기 설정 대기" }
        if !engineRunning { return activeShortcutIDs.isEmpty ? "시작 대기" : "한/영 실행 · 리매핑 대기" }
        return shortcutError == nil ? "실행 중" : "일부 단축키 충돌"
    }

    var languageShortcutStatus: String {
        let rules = shortcuts.filter { $0.isEnabled && $0.action == .toggleInputSource }
        guard !rules.isEmpty else { return "활성화된 한/영 단축키가 없습니다." }
        if !engineEnabled { return "앱 엔진이 꺼져 있어 한/영 단축키도 중지되어 있습니다." }
        if isWorking { return "시스템 설정 변경 중에는 단축키를 잠시 중지합니다." }
        if MacroRunner.shared.isRunning { return "매크로 실행 중에는 단축키를 잠시 중지합니다. Esc로 매크로를 중지할 수 있습니다." }
        let registered = rules.filter { activeShortcutIDs.contains($0.id) }
        if !registered.isEmpty {
            return "한/영 단축키 사용 중: " + registered.map(\.displayText).joined(separator: ", ")
        }
        if let shortcutError { return shortcutError }
        if LanguageShortcutPolicy.independentRules(from: rules).isEmpty && !engineRunning {
            return "리매핑 대기 중에는 Command/Control을 포함하지 않는 조합(예: Shift+Space)으로 한/영 전환을 사용할 수 있습니다."
        }
        return "한/영 단축키를 등록하지 못했습니다. 엔진을 다시 확인해 주세요."
    }

    init() {
        let saved = defaults.data(forKey: "profile.v1").flatMap { try? JSONDecoder().decode(PortableProfile.self, from: $0) }
        engineEnabled = defaults.object(forKey: "engineEnabled") as? Bool ?? true
        setupPhase = SetupPhase(rawValue: defaults.string(forKey: "setupPhase.v2") ?? "") ?? .needsSetup
        swapCommandControl = saved?.swapCommandControl ?? defaults.object(forKey: "swapCommandControl") as? Bool ?? false
        windowsFinderMode = saved?.windowsFinderMode ?? defaults.object(forKey: "windowsFinderMode") as? Bool ?? false
        windowSwitcherEnabled = saved?.windowSwitcherEnabled ?? defaults.object(forKey: "windowSwitcherEnabled") as? Bool ?? true
        standardFunctionKeys = saved?.standardFunctionKeys
        finderFeatures = saved?.finderFeatures ?? Set(FinderFeature.allCases)
        dockConfiguration = defaults.data(forKey: "dock.configuration.v2").flatMap { try? JSONDecoder().decode(DockConfiguration.self, from: $0) }
        // Display safety preferences belong to this Mac, not imported keyboard profiles.
        autoDisableBuiltInDisplay = defaults.bool(forKey: "autoDisableBuiltInDisplay.v1")
        shortcuts = saved?.shortcuts ?? Self.decode([ShortcutRule].self, from: defaults.data(forKey: "customShortcuts.v1")) ?? [
            ShortcutRule(key: .space, modifiers: [.shift], action: .toggleInputSource),
            ShortcutRule(key: .f, modifiers: [.command, .option], action: .finder),
            ShortcutRule(key: .m, modifiers: [.command, .option], action: .missionControl),
            ShortcutRule(key: .l, modifiers: [.command, .option], action: .launchpad)
        ]
        corners = saved?.corners ?? Self.decode([HotCornerRule].self, from: defaults.data(forKey: "hotCorners.v1")) ?? [
            HotCornerRule(position: .topLeft, isEnabled: true, dwellSeconds: 0.35, action: .missionControl),
            HotCornerRule(position: .topRight, isEnabled: false, dwellSeconds: 0.35, action: .launchpad),
            HotCornerRule(position: .bottomLeft, isEnabled: false, dwellSeconds: 0.35, action: .screenSaver),
            HotCornerRule(position: .bottomRight, isEnabled: true, dwellSeconds: 0.35, action: .finder)
        ]
        shortcuts = KeyboardTemplates.migrating(shortcuts)
        MacroRunner.shared.onStart = { [weak self] in
            HotKeyCenter.shared.stop()
            self?.activeShortcutIDs.removeAll()
            self?.publishRuntimeStatus()
        }
        MacroRunner.shared.onFinish = { [weak self] in self?.apply() }
        hasFinishedInitialization = true
        startupTask = Task { await beginSession() }
        monitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.refreshRemappingPermission()
                FunctionKeyController.shared.refresh()
                if tick % 5 == 0 {
                    await self?.refreshKeyMappingState()
                    await self?.scanConflicts()
                }
                self?.publishRuntimeStatus()
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
        systemMonitor = Task { [weak self] in
            // Full preference discovery is for startup and explicit/foreground
            // inspection. Runtime mapping safety still runs every 15 seconds.
            await self?.refreshSystemState()
        }
    }

    @discardableResult
    func addShortcut(action: AppAction = .applications) -> UUID {
        let rule = ShortcutRule(isEnabled: false, key: action == .toggleApplication ? .quote : action == .toggleInputSource ? .space : .k,
                                modifiers: action == .toggleApplication ? [.command, .shift] : action == .toggleInputSource ? [.shift] : [.command, .option], action: action)
        shortcuts.append(rule)
        return rule.id
    }

    func removeShortcuts(at offsets: IndexSet) { shortcuts.remove(atOffsets: offsets) }

    func apply() {
        guard hasFinishedInitialization, sessionReady, !terminating, !isWorking else { return }
        let desiredDock = engineEnabled && !isWorking ? dockConfiguration : nil
        dockUpdates.submit(desiredDock)
        defer { publishRuntimeStatus() }
        FunctionKeyController.shared.apply(engineEnabled && !isWorking ? standardFunctionKeys : nil)
        DisplayController.shared.apply(engineEnabled && !isWorking && autoDisableBuiltInDisplay)
        stopEngines()
        shortcutError = nil
        remappingError = nil
        inputSourceWarning = InputSourceManager.shared.availabilityWarning()
        guard engineEnabled, !isWorking, !MacroRunner.shared.isRunning else { return }
        guard setupPhase == .ready, let keyMappingState else {
            configureIndependentLanguageShortcuts()
            return
        }
        guard keyMappingState.allowsRemapping else {
            remappingError = "시스템 키 매핑이 남아 있거나 상태를 읽을 수 없습니다. ‘설정 점검 → 초기 설정·백업·복구’에서 확인해 주세요."
            configureIndependentLanguageShortcuts()
            return
        }
        let engine = KeyboardRemappingEngine.shared
        remappingError = engine.configure(swapCommandControl: swapCommandControl,
                                          windowsFinderMode: windowsFinderMode && !finderFeatures.isEmpty,
                                          finderFeatures: finderFeatures,
                                          windowSwitcherEnabled: windowSwitcherEnabled,
                                          macrosEnabled: shortcuts.contains { $0.isEnabled && $0.action == .macro })
        accessibilityGranted = engine.accessibilityGranted
        inputMonitoringGranted = engine.inputMonitoringGranted
        remappingActive = engine.isOperational
        guard remappingError == nil else {
            stopEngines()
            configureIndependentLanguageShortcuts()
            return
        }
        shortcutError = HotKeyCenter.shared.configure(shortcuts)
        activeShortcutIDs = HotKeyCenter.shared.registeredRuleIDs
        HotCornerMonitor.shared.configure(corners)
        engineRunning = true
    }

    private func configureIndependentLanguageShortcuts() {
        shortcutError = HotKeyCenter.shared.configure(LanguageShortcutPolicy.independentRules(from: shortcuts))
        activeShortcutIDs = HotKeyCenter.shared.registeredRuleIDs
    }

    private func publishRuntimeStatus() {
        let status: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "accessibilityGranted": accessibilityGranted,
            "inputMonitoringGranted": inputMonitoringGranted,
            "keyMappingError": keyMappingState?.error ?? "",
            "keyMappingCheckComplete": keyMappingState != nil,
            "systemInspectionError": systemState?.error ?? "",
            "systemInspectionWarningCount": systemState?.warnings.count ?? 0,
            "windowFocusError": WindowSwitcherController.shared.focusController.lastError ?? "",
            "functionKeyMode": FunctionKeyController.shared.actualStandard.map { $0 ? "standard" : "special" } ?? "unknown",
            "functionKeyManaged": FunctionKeyController.shared.appliedStandard != nil,
            "functionKeyError": FunctionKeyController.shared.error ?? "",
            "builtInDisplayOn": DisplayController.shared.builtInOn as Any? ?? "unknown",
            "displayAutoRequested": autoDisableBuiltInDisplay,
            "displayGuardRunning": DisplayController.shared.isRunning,
            "displayError": DisplayController.shared.error ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "setupPhase": setupPhase.rawValue,
            "engineRunning": engineRunning,
            "remappingActive": remappingActive,
            "registeredShortcuts": shortcuts.filter { activeShortcutIDs.contains($0.id) }.map(\.displayText),
            "languageShortcutStatus": languageShortcutStatus,
            "shortcutError": shortcutError ?? "",
            "remappingError": remappingError ?? ""
        ]
        defaults.set(status, forKey: "diagnostic.runtime.v1")
    }

    private func stopEngines() {
        MacroRunner.shared.cancel()
        HotKeyCenter.shared.stop()
        activeShortcutIDs.removeAll()
        HotCornerMonitor.shared.stop()
        KeyboardRemappingEngine.shared.stop()
        remappingActive = false
        engineRunning = false
    }

    func refreshRemappingPermission() {
        let engine = KeyboardRemappingEngine.shared
        let changed = accessibilityGranted != engine.accessibilityGranted || inputMonitoringGranted != engine.inputMonitoringGranted
        let stopped = remappingActive && !engine.isOperational
        if accessibilityGranted != engine.accessibilityGranted { accessibilityGranted = engine.accessibilityGranted }
        if inputMonitoringGranted != engine.inputMonitoringGranted { inputMonitoringGranted = engine.inputMonitoringGranted }
        if changed || stopped { apply() }
    }

    func refreshKeyMappingState() async {
        guard !isWorking else { return }
        let generation = systemGeneration
        let state = await SystemDefaultsService.inspectKeyMappings()
        guard !isWorking, generation == systemGeneration else { return }
        let changed = keyMappingState != state
        keyMappingState = state
        if changed { apply() }
    }

    func refreshSystemState() async {
        await refreshKeyMappingState()
        guard !isInspectingSystem else { return }
        guard !isWorking else { return }
        isInspectingSystem = true
        defer { isInspectingSystem = false }
        let generation = systemGeneration
        let state = await SystemDefaultsService.inspect()
        guard !isWorking, generation == systemGeneration else { return }
        systemState = state
    }

    func prepareSystem() async {
        guard sessionReady, !isWorking, !operationInProgress else { return }
        operationInProgress = true
        defer {
            operationInProgress = false
            let waiters = operationWaiters
            operationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        isWorking = true
        await dockUpdates.flush()
        let previousPhase = setupPhase
        DisplayController.shared.apply(false)
        systemGeneration = UUID()
        setupError = nil
        stopEngines()
        setPhase(.needsSetup)
        do {
            _ = try await SystemDefaultsService.resetManagedSettings()
            setPhase(.awaitingVerification)
        } catch {
            if case SystemDefaultsError.preparationFailed = error { setPhase(previousPhase) }
            setupError = error.localizedDescription
        }
        isWorking = false
        await refreshSystemState()
        dockUpdates.invalidate()
        apply()
    }

    func confirmDefaults() async {
        await refreshSystemState()
        guard systemState?.error == nil, systemState?.modifierMappingsPresent == false else {
            setupError = "키 매핑이 남아 있습니다. 다른 입력 앱을 종료한 뒤 기본값 전환을 다시 실행해 주세요."
            return
        }
        setupError = nil
        setPhase(.ready)
        apply()
        await scanConflicts()
    }

    func restoreSystem(from url: URL) async {
        guard sessionReady, !isWorking, !operationInProgress else { return }
        operationInProgress = true
        defer {
            operationInProgress = false
            let waiters = operationWaiters
            operationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        isWorking = true
        systemGeneration = UUID()
        setupError = nil
        engineEnabled = false
        stopEngines()
        FunctionKeyController.shared.apply(nil)
        DisplayController.shared.apply(false)
        setPhase(.needsSetup)
        await dockUpdates.flush()
        do {
            try await SystemDefaultsService.restoreBackup(at: url)
            try await SettingsHistory.shared.rebase(app: configurationSnapshot)
        }
        catch { setupError = error.localizedDescription }
        isWorking = false
        await refreshSystemState()
    }

    func scanConflicts() async {
        guard !isScanning else { return }
        isScanning = true
        let revision = configurationRevision
        let report = await EngineConflictDetector.scan(shortcuts: shortcuts, registrationError: shortcutError, windowSwitcherEnabled: windowSwitcherEnabled, windowsFinderMode: windowsFinderMode)
        if revision != configurationRevision {
            isScanning = false
            await scanConflicts()
            return
        }
        conflictReport = report
        inputSourceWarning = InputSourceManager.shared.availabilityWarning()
        isScanning = false
    }

    func importProfile(_ profile: PortableProfile) throws {
        let profile = try profile.validated()
        let directory = try SystemDefaultsService.backupsDirectory().deletingLastPathComponent().appendingPathComponent("Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Local edits may temporarily contain duplicate shortcuts; preserve those too.
        try JSONEncoder().encode(self.profile).write(to: directory.appendingPathComponent("before-import-\(UUID().uuidString).json"), options: .atomic)
        hasFinishedInitialization = false
        shortcuts = KeyboardTemplates.migrating(profile.shortcuts)
        corners = profile.corners
        swapCommandControl = profile.swapCommandControl
        windowsFinderMode = profile.windowsFinderMode
        windowSwitcherEnabled = profile.windowSwitcherEnabled
        standardFunctionKeys = profile.standardFunctionKeys
        finderFeatures = profile.finderFeatures ?? Set(FinderFeature.allCases)
        hasFinishedInitialization = true
        persistAndApply()
    }

    var configurationSnapshot: AppConfigurationSnapshot {
        AppConfigurationSnapshot(profile: profile, engineEnabled: engineEnabled,
            autoDisableBuiltInDisplay: autoDisableBuiltInDisplay, dock: dockConfiguration,
            loginEnabled: SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval)
    }

    func beginSession() async {
        guard !sessionReady, !isWorking, !operationInProgress else { return }
        operationInProgress = true
        defer {
            operationInProgress = false
            let waiters = operationWaiters
            operationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        isWorking = true
        historyError = nil
        do {
            try await SettingsHistory.shared.begin(app: configurationSnapshot)
            sessionReady = true
        } catch { historyError = "시작 백업 실패: \(error.localizedDescription)" }
        isWorking = false
        if sessionReady { apply() }
        await refreshHistory()
    }

    func finishSession() async throws {
        await startupTask?.value
        if operationInProgress {
            await withCheckedContinuation { continuation in operationWaiters.append(continuation) }
        }
        terminating = true
        isWorking = true
        await dockUpdates.flush()
        DisplayController.shared.shutdown()
        stopEngines()
        FunctionKeyController.shared.apply(nil)
        do {
            try await SettingsHistory.shared.finish()
            monitor?.cancel()
            systemMonitor?.cancel()
            MacroRunner.shared.onFinish = nil
            sessionReady = false
        } catch {
            sessionReady = false
            terminating = false
            isWorking = false
            historyError = "종료 복원 실패: \(error.localizedDescription)"
            throw error
        }
    }

    func setDockConfiguration(_ configuration: DockConfiguration?) {
        guard configuration?.isValid != false, sessionReady, !isWorking, !terminating,
              dockConfiguration != configuration else { return }
        dockConfiguration = configuration
        defaults.set(try? JSONEncoder().encode(configuration), forKey: "dock.configuration.v2")
        // Dock edits do not rebuild keyboard taps, macros, or shortcut registrations.
        dockUpdates.submit(engineEnabled ? configuration : nil)
    }

    func refreshHistory() async {
        do { history = try await SettingsHistory.shared.list() }
        catch { historyError = error.localizedDescription }
    }

    func createCheckpoint(name: String) async {
        guard sessionReady, !isWorking, !operationInProgress else { return }
        operationInProgress = true
        defer {
            operationInProgress = false
            let waiters = operationWaiters
            operationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        isWorking = true
        historyError = nil
        await dockUpdates.flush()
        do {
            _ = try await SettingsHistory.shared.checkpoint(app: configurationSnapshot, name: name)
            historyMessage = "현재 시점의 설정을 백업했습니다."
        } catch { historyError = error.localizedDescription }
        isWorking = false
        await refreshHistory()
    }

    func restoreCheckpoint(_ id: UUID) async {
        guard sessionReady, !isWorking, !operationInProgress else { return }
        operationInProgress = true
        defer {
            operationInProgress = false
            let waiters = operationWaiters
            operationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let before = configurationSnapshot
        let beforeFunctionKeys = FunctionKeyController.shared.actualStandard
        isWorking = true
        historyError = nil
        await dockUpdates.flush()
        stopEngines()
        FunctionKeyController.shared.apply(nil)
        DisplayController.shared.apply(false)
        do {
            let snapshot = try await SettingsHistory.shared.restore(id: id, currentApp: before, currentFunctionKeys: beforeFunctionKeys)
            hasFinishedInitialization = false
            shortcuts = KeyboardTemplates.migrating(snapshot.app.profile.shortcuts)
            corners = snapshot.app.profile.corners
            swapCommandControl = snapshot.app.profile.swapCommandControl
            windowsFinderMode = snapshot.app.profile.windowsFinderMode
            finderFeatures = snapshot.app.profile.finderFeatures ?? Set(FinderFeature.allCases)
            windowSwitcherEnabled = snapshot.app.profile.windowSwitcherEnabled
            standardFunctionKeys = snapshot.app.profile.standardFunctionKeys
            autoDisableBuiltInDisplay = snapshot.app.autoDisableBuiltInDisplay
            dockConfiguration = snapshot.app.dock
            engineEnabled = snapshot.app.engineEnabled
            hasFinishedInitialization = true
            if snapshot.app.loginEnabled != before.loginEnabled {
                do {
                    if snapshot.app.loginEnabled { try SMAppService.mainApp.register() }
                    else { try await SMAppService.mainApp.unregister() }
                } catch { historyError = "설정은 복원했지만 로그인 자동 실행은 확인이 필요합니다: \(error.localizedDescription)" }
            }
            historyMessage = "선택한 시점으로 복원했습니다."
            dockUpdates.invalidate()
        } catch { historyError = error.localizedDescription }
        isWorking = false
        await refreshKeyMappingState()
        persistAndApply()
        await refreshHistory()
    }

    private func setPhase(_ phase: SetupPhase) {
        setupPhase = phase
        defaults.set(phase.rawValue, forKey: "setupPhase.v2")
    }

    private func persistAndApply() {
        guard hasFinishedInitialization else { return }
        configurationRevision = UUID()
        defaults.set(engineEnabled, forKey: "engineEnabled")
        defaults.set(try? JSONEncoder().encode(dockConfiguration), forKey: "dock.configuration.v2")
        defaults.set(autoDisableBuiltInDisplay, forKey: "autoDisableBuiltInDisplay.v1")
        defaults.set(try? JSONEncoder().encode(profile), forKey: "profile.v1")
        apply()
        Task { await scanConflicts() }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
