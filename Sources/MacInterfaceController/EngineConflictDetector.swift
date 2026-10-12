import Foundation

enum ConflictSeverity: Int, Sendable {
    case info = 0
    case warning = 1
    case blocking = 2

    var title: String {
        switch self {
        case .info: "참고"
        case .warning: "확인 필요"
        case .blocking: "충돌"
        }
    }
}

struct ConflictIssue: Identifiable, Sendable {
    let id = UUID()
    let severity: ConflictSeverity
    let engine: String
    let title: String
    let detail: String
}

struct DetectedEngine: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let isRunning: Bool
    let detail: String
}

struct ConflictReport: Sendable {
    let issues: [ConflictIssue]
    let engines: [DetectedEngine]
    let checkedAt: Date

    var blockingCount: Int { issues.filter { $0.severity == .blocking }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
}

enum EngineConflictDetector {
    private struct KnownEngine {
        let name: String
        let processTokens: [String]
        let detail: String
    }

    private static let knownEngines = [
        KnownEngine(
            name: "Karabiner-Elements",
            processTokens: ["karabiner_console_user_server", "karabiner-core-service"],
            detail: "키를 앱보다 먼저 변환할 수 있습니다. 선택된 프로필의 매핑도 함께 검사합니다."
        ),
        KnownEngine(
            name: "BetterTouchTool",
            processTokens: ["bettertouchtool"],
            detail: "전역 단축키와 트리거를 등록할 수 있습니다."
        ),
        KnownEngine(
            name: "Keyboard Maestro",
            processTokens: ["keyboard maestro engine"],
            detail: "매크로 단축키를 선점할 수 있습니다."
        ),
        KnownEngine(
            name: "Hammerspoon",
            processTokens: ["hammerspoon.app/contents/macos/hammerspoon"],
            detail: "Lua 설정에서 전역 단축키와 키 이벤트 탭을 사용할 수 있습니다."
        ),
        KnownEngine(
            name: "Raycast",
            processTokens: ["raycast.app/contents/macos/raycast"],
            detail: "확장 명령에 전역 단축키가 지정될 수 있습니다."
        ),
        KnownEngine(
            name: "Alfred",
            processTokens: ["alfred 5.app", "alfred 4.app"],
            detail: "워크플로 단축키와 시스템 단축키를 사용할 수 있습니다."
        ),
        KnownEngine(
            name: "skhd",
            processTokens: ["/skhd", " skhd"],
            detail: "설정 파일의 전역 단축키와 겹칠 수 있습니다."
        ),
        KnownEngine(
            name: "Logitech Options / G HUB",
            processTokens: ["logi options", "logitech g hub", "lghub"],
            detail: "키보드 장치 수준 매핑이 앱에 도달하는 키를 바꿀 수 있습니다."
        )
    ]

    static func windowSwitcherIssues(shortcuts: [ShortcutRule], enabled: Bool) -> [ConflictIssue] {
        guard enabled else { return [] }
        return shortcuts.filter {
            $0.isEnabled && $0.key == .tab && ($0.modifiers == [.control] || $0.modifiers == [.control, .shift])
        }.map { rule in
            ConflictIssue(severity: .blocking, engine: "이 앱", title: "\(rule.displayText)는 창 전환기가 사용 중",
                          detail: "창 전환 탭에서 창 전환기를 끄거나 단축키를 다른 조합으로 바꿔 주세요.")
        }
    }

    static func scan(shortcuts: [ShortcutRule], registrationError: String?, windowSwitcherEnabled: Bool = false, windowsFinderMode: Bool = false) async -> ConflictReport {
        await Task.detached {
            var issues = internalDuplicateIssues(shortcuts: shortcuts)
            issues.append(contentsOf: windowSwitcherIssues(shortcuts: shortcuts, enabled: windowSwitcherEnabled))
            if windowsFinderMode {
                let finderControlKeys: Set<ShortcutKey> = [.a, .c, .f, .n, .w, .z, .x, .v, .y, .l]
                for rule in shortcuts where rule.isEnabled && ((rule.modifiers == [.control] && finderControlKeys.contains(rule.key)) || (rule.modifiers == [.control, .shift] && rule.key == .n)) {
                    issues.append(ConflictIssue(severity: .blocking, engine: "이 앱 / Finder", title: "\(rule.displayText)는 Finder 매핑과 겹침", detail: "Finder가 앞에 있으면 파일 조작 매핑이 먼저 처리됩니다. 다른 단축키를 선택하거나 Finder Windows 모드를 꺼 주세요."))
                }
            }
            if let registrationError, !registrationError.isEmpty {
                issues.append(ConflictIssue(
                    severity: .blocking,
                    engine: "macOS 전역 단축키",
                    title: "단축키 등록이 거부됨",
                    detail: registrationError
                ))
            }

            let processList = runningProcessList().lowercased()
            let engines = knownEngines.map { engine in
                let running = engine.processTokens.contains { processList.contains($0) }
                return DetectedEngine(name: engine.name, isRunning: running, detail: engine.detail)
            }

            if engines.first(where: { $0.name == "Karabiner-Elements" })?.isRunning == true {
                issues.append(ConflictIssue(
                    severity: .warning,
                    engine: "Karabiner-Elements",
                    title: "키보드 변환 엔진 실행 중",
                    detail: "매핑과 직접 겹치지 않아도 Karabiner가 변환한 키를 이 앱이 받습니다."
                ))
            }

            let karabinerURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/karabiner/karabiner.json")
            if let data = try? Data(contentsOf: karabinerURL) {
                let running = engines.first(where: { $0.name == "Karabiner-Elements" })?.isRunning == true
                issues.append(contentsOf: karabinerConflicts(configuration: data, shortcuts: shortcuts).map { issue in
                    guard !running else { return issue }
                    return ConflictIssue(severity: .warning, engine: issue.engine, title: issue.title,
                                         detail: "현재 실행은 감지되지 않았습니다. 다시 실행할 경우의 충돌 가능성입니다. " + issue.detail)
                })
            }

            for engine in engines where engine.isRunning && engine.name != "Karabiner-Elements" {
                issues.append(ConflictIssue(
                    severity: .warning,
                    engine: engine.name,
                    title: "다른 입력 엔진 실행 중",
                    detail: engine.detail
                ))
            }

            return ConflictReport(
                issues: issues.sorted { $0.severity.rawValue > $1.severity.rawValue },
                engines: engines,
                checkedAt: Date()
            )
        }.value
    }

    static func karabinerConflicts(configuration data: Data, shortcuts: [ShortcutRule]) -> [ConflictIssue] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]],
              let profile = profiles.first(where: { ($0["selected"] as? Bool) == true }) else { return [] }

        let profileName = profile["name"] as? String ?? "선택된 프로필"
        var issues: [ConflictIssue] = []
        let simpleMappings = (profile["simple_modifications"] as? [[String: Any]] ?? []).map { ($0, false) }
            + (profile["devices"] as? [[String: Any]] ?? []).flatMap { device in
                (device["simple_modifications"] as? [[String: Any]] ?? []).map { ($0, true) }
            }

        for (mapping, deviceSpecific) in simpleMappings {
            guard let from = mapping["from"] as? [String: Any],
                  let keyCode = from["key_code"] as? String else { continue }
            for shortcut in shortcuts where shortcut.isEnabled && (shortcut.key.karabinerCode == keyCode || shortcut.modifiers.map(\.karabinerCode).contains(normalizeModifier(keyCode))) {
                issues.append(ConflictIssue(
                    severity: deviceSpecific ? .warning : .blocking,
                    engine: "Karabiner-Elements",
                    title: "\(shortcut.displayText) 키가 단순 변경됨",
                    detail: "‘\(profileName)’ 프로필이 \(keyCode) 키를 먼저 변경합니다. 이 앱의 \(shortcut.action.title) 동작에 다른 키가 전달될 수 있습니다."
                ))
            }
        }

        let complex = profile["complex_modifications"] as? [String: Any]
        let rules = complex?["rules"] as? [[String: Any]] ?? []
        for rule in rules {
            let description = rule["description"] as? String ?? "설명 없는 규칙"
            for manipulator in rule["manipulators"] as? [[String: Any]] ?? [] {
                guard let from = manipulator["from"] as? [String: Any] else { continue }
                for shortcut in shortcuts where shortcut.isEnabled && matches(from: from, shortcut: shortcut) {
                    issues.append(ConflictIssue(
                        severity: (manipulator["conditions"] as? [Any])?.isEmpty == false ? .warning : .blocking,
                        engine: "Karabiner-Elements",
                        title: "\(shortcut.displayText) 조합이 복합 규칙과 겹침",
                        detail: "‘\(profileName)’ 프로필의 ‘\(description)’ 규칙이 같은 입력을 받을 수 있습니다."
                    ))
                }
            }
        }
        return deduplicated(issues)
    }

    private static func matches(from: [String: Any], shortcut: ShortcutRule) -> Bool {
        guard from["key_code"] as? String == shortcut.key.karabinerCode else { return false }
        let modifiers = from["modifiers"] as? [String: Any]
        let mandatory = Set((modifiers?["mandatory"] as? [String] ?? []).map(normalizeModifier))
        let optionalValues = modifiers?["optional"] as? [String] ?? []
        let optional = Set(optionalValues.map(normalizeModifier))
        let pressed = Set(shortcut.modifiers.map(\.karabinerCode))

        guard mandatory.isSubset(of: pressed) else { return false }
        let extra = pressed.subtracting(mandatory)
        return optional.contains("any") || extra.isSubset(of: optional)
    }

    private static func normalizeModifier(_ value: String) -> String {
        value.replacingOccurrences(of: "left_", with: "")
            .replacingOccurrences(of: "right_", with: "")
    }

    private static func internalDuplicateIssues(shortcuts: [ShortcutRule]) -> [ConflictIssue] {
        let active = shortcuts.filter(\.isEnabled)
        let groups = Dictionary(grouping: active) { "\($0.key.rawValue):\($0.carbonModifiers)" }
        return groups.values.compactMap { group in
            guard group.count > 1, let first = group.first else { return nil }
            let actions = group.map(\.action.title).joined(separator: ", ")
            return ConflictIssue(
                severity: .blocking,
                engine: "이 앱",
                title: "\(first.displayText) 단축키 중복",
                detail: "같은 조합에 여러 동작이 지정되어 있습니다: \(actions)"
            )
        }
    }

    private static func runningProcessList() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func deduplicated(_ issues: [ConflictIssue]) -> [ConflictIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert("\($0.engine)|\($0.title)|\($0.detail)").inserted }
    }
}

extension ShortcutKey {
    var karabinerCode: String {
        switch self {
        case .quote: "quote"
        case .space: "spacebar"
        case .tab: "tab"
        case .enter: "return_or_enter"; case .escape: "escape"
        case .backspace: "delete_or_backspace"; case .forwardDelete: "delete_forward"
        case .left: "left_arrow"; case .right: "right_arrow"; case .up: "up_arrow"; case .down: "down_arrow"
        case .pageUp: "page_up"; case .pageDown: "page_down"
        case .one: "1"; case .two: "2"; case .three: "3"; case .four: "4"
        case .five: "5"; case .six: "6"; case .seven: "7"; case .eight: "8"
        case .nine: "9"; case .zero: "0"
        default: rawValue
        }
    }
}

extension ShortcutModifier {
    var karabinerCode: String {
        switch self {
        case .command: "command"
        case .option: "option"
        case .control: "control"
        case .shift: "shift"
        }
    }
}
