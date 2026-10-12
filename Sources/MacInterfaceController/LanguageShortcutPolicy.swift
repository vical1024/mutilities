import Foundation

/// Input-source selection does not require an event tap. While remapping is unavailable,
/// avoid Command/Control combinations whose physical meaning may still be swapped.
enum LanguageShortcutPolicy {
    static func independentRules(from rules: [ShortcutRule]) -> [ShortcutRule] {
        rules.filter {
            $0.isEnabled && $0.action == .toggleInputSource
                && $0.modifiers.isDisjoint(with: [.command, .control])
        }
    }
}
