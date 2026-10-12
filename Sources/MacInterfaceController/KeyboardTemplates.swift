import Foundation

enum FinderFeature: String, Codable, CaseIterable, Identifiable {
    case open, rename, trash, navigation, info, editing, move, location, newFolder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: "선택 항목 열기"
        case .rename: "이름 변경"
        case .trash: "휴지통으로 이동"
        case .navigation: "폴더 탐색"
        case .info: "정보 가져오기"
        case .editing: "복사·붙여넣기 등 기본 편집"
        case .move: "잘라내기·이동 붙여넣기"
        case .location: "폴더 위치로 이동"
        case .newFolder: "새 폴더 만들기"
        }
    }
    var keys: String {
        switch self {
        case .open: "Enter"
        case .rename: "F2"
        case .trash: "Delete"
        case .navigation: "⌘ ← / → / ↑"
        case .info: "⌥ Enter"
        case .editing: "⌃ A / C / V / F / N / W / Z / Y"
        case .move: "⌃ X / V"
        case .location: "⌃ L"
        case .newFolder: "⌃ ⇧ N"
        }
    }
}

enum KeyboardTemplates {
    static var rules: [ShortcutRule] {
        [ShortcutRule(key: .space, modifiers: [.shift], action: .toggleInputSource)] + WindowLayoutPresets.rules
    }
    static var actions: [AppAction] { rules.map(\.action) }
    /// Adopt existing customized rules; missing templates stay off until explicitly enabled.
    static func migrating(_ existing: [ShortcutRule]) -> [ShortcutRule] {
        var result = existing
        for var preset in rules {
            if result.contains(where: { $0.templateID == preset.action.rawValue }) { continue }
            if let index = result.firstIndex(where: { $0.action == preset.action && $0.templateID == nil }) {
                result[index].templateID = preset.action.rawValue
            } else {
                preset.isEnabled = false
                preset.templateID = preset.action.rawValue
                result.append(preset)
            }
        }
        return result
    }
}
