import Foundation

struct PortableProfile: Codable, Equatable {
    var version = 3
    var name: String
    var shortcuts: [ShortcutRule]
    var corners: [HotCornerRule]
    var swapCommandControl: Bool
    var windowsFinderMode: Bool
    var windowSwitcherEnabled: Bool
    var standardFunctionKeys: Bool? = nil
    var finderFeatures: Set<FinderFeature>? = nil

    func validated() throws -> Self {
        guard [1, 2, 3].contains(version) else { throw ProfileError.invalid("지원하지 않는 설정 버전입니다: \(version)") }
        guard !name.isEmpty, name.count <= 100, shortcuts.filter({ $0.templateID == nil }).count <= 100,
              shortcuts.count <= 100 + KeyboardTemplates.actions.count,
              Set(shortcuts.map(\.id)).count == shortcuts.count,
              corners.count == 4, Set(corners.map(\.position)).count == 4,
              corners.allSatisfy({ $0.dwellSeconds.isFinite && (0.15...1).contains($0.dwellSeconds) }),
              shortcuts.allSatisfy({ !$0.modifiers.isEmpty }) else {
            throw ProfileError.invalid("설정에 중복 식별자, 빠진 코너 또는 잘못된 키/시간 값이 있습니다.")
        }
        guard corners.allSatisfy({ $0.action != .macro }) else {
            throw ProfileError.invalid("매크로는 자체 단축키에서 지정해 주세요.")
        }
        for rule in shortcuts {
            if rule.isEnabled && rule.action == .toggleApplication && !rule.targetApplication.isConfigured {
                throw ProfileError.invalid("표시 / 숨기기 단축키에서 앱을 선택해 주세요.")
            }
            if [rule.windowHeightPercent, rule.windowWidthPercent].compactMap({ $0 }).contains(where: { !$0.isFinite || !(30...100).contains($0) }) {
                throw ProfileError.invalid("창 너비·높이 비율은 30~100%여야 합니다.")
            }
            if let macro = rule.macro { try macro.validate(allowEmpty: !rule.isEnabled || rule.action != .macro) }
            else if rule.isEnabled && rule.action == .macro { throw ProfileError.invalid("매크로 입력 순서가 비어 있습니다.") }
        }
        let templates = shortcuts.compactMap(\.templateID)
        guard Set(templates).count == templates.count, shortcuts.allSatisfy({ $0.templateID == nil || $0.templateID == $0.action.rawValue && KeyboardTemplates.actions.contains($0.action) }) else {
            throw ProfileError.invalid("고정 템플릿 구성이 잘못되었습니다.")
        }
        let active = shortcuts.filter(\.isEnabled)
        let combinations = active.map { "\($0.key.rawValue):\($0.carbonModifiers)" }
        guard Set(combinations).count == combinations.count else {
            throw ProfileError.invalid("동일한 단축키에 여러 동작이 지정되어 있습니다.")
        }
        return self
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw ProfileError.invalid("설정 파일이 너무 큽니다.") }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(validated())
    }
}

enum ProfileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
