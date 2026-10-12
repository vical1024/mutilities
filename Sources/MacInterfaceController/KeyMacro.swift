import Foundation

struct MacroStep: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case key, wait }
    var id = UUID()
    var kind: Kind = .key
    var key: ShortcutKey = .tab
    var modifiers: Set<ShortcutModifier> = []
    var milliseconds = 100
}

struct KeyMacro: Codable, Equatable {
    var steps: [MacroStep] = []
    var name: String? = nil

    var validationError: String? {
        do { try validate(); return nil }
        catch { return error.localizedDescription }
    }

    func validate(allowEmpty: Bool = false) throws {
        guard steps.count <= 100, Set(steps.map(\.id)).count == steps.count,
              steps.allSatisfy({ (0...5000).contains($0.milliseconds) }),
              steps.reduce(0, { $0 + $1.milliseconds }) <= 30_000 else {
            throw ProfileError.invalid("매크로는 최대 100단계, 단계별 대기 0~5초, 전체 대기 30초까지 지정할 수 있습니다.")
        }
        if !allowEmpty && !steps.contains(where: { $0.kind == .key }) {
            throw ProfileError.invalid("매크로에 키 입력을 한 개 이상 추가해 주세요.")
        }
    }
}
