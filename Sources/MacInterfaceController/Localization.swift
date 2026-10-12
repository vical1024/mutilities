import Foundation

enum AppLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en"
    static let defaultsKey = "app.displayLanguage.v1"
    static var current: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .korean
    }
}

/// Translation is applied only at presentation boundaries. Stored profiles and diagnostic
/// messages keep their original values, so changing language cannot restart an engine or
/// rewrite user settings. Existing notices also update without recreating their source.
/// Views explicitly read their AppStorage language dependency to refresh without changing identity.
enum L10n {
    static func text(_ source: String, language: AppLanguage = .current) -> String {
        guard language == .english else { return source }
        return translate(source, depth: 0)
    }

    private struct MessageTemplate {
        let expression: NSRegularExpression
        let translation: String
        let specificity: Int
    }

    private static let placeholders = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    private static let templates: [MessageTemplate] = english.compactMap { key, value in
        let range = NSRange(key.startIndex..., in: key)
        let slots = placeholders.matches(in: key, range: range)
        guard !slots.isEmpty else { return nil }
        var pattern = "^"
        var cursor = key.startIndex
        for slot in slots {
            let slotRange = Range(slot.range, in: key)!
            pattern += NSRegularExpression.escapedPattern(for: String(key[cursor..<slotRange.lowerBound]))
            pattern += "([\\s\\S]*?)"
            cursor = slotRange.upperBound
        }
        pattern += NSRegularExpression.escapedPattern(for: String(key[cursor...])) + "$"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return MessageTemplate(expression: expression, translation: value, specificity: key.count - slots.count * 3)
    }.sorted { $0.specificity > $1.specificity }

    private static let prefixes = english.keys.filter { $0.hasSuffix(": ") || $0.hasSuffix(". ") }.sorted { $0.count > $1.count }

    private static func translate(_ source: String, depth: Int) -> String {
        guard depth < 8 else { return source }
        if let translated = english[source] { return translated }
        guard source.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        for template in templates {
            guard let match = template.expression.firstMatch(in: source, range: range) else { continue }
            let arguments = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: source).map { translate(String(source[$0]), depth: depth + 1) } ?? ""
            }
            return render(template.translation, arguments: arguments)
        }
        // Controllers may join several diagnostics, or prepend a stable contextual label.
        if source.contains("\n") {
            return source.components(separatedBy: "\n").map { translate($0, depth: depth + 1) }.joined(separator: "\n")
        }
        for key in prefixes {
            if source.hasPrefix(key) {
                return english[key]! + translate(String(source.dropFirst(key.count)), depth: depth + 1)
            }
        }
        return source
    }

    /// Substitute in one pass so a user-supplied filename containing “{1}” stays literal.
    private static func render(_ template: String, arguments: [String]) -> String {
        var result = ""
        var cursor = template.startIndex
        for slot in placeholders.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let slotRange = Range(slot.range, in: template), let indexRange = Range(slot.range(at: 1), in: template),
                  let index = Int(template[indexRange]), arguments.indices.contains(index) else { continue }
            result += template[cursor..<slotRange.lowerBound]
            result += arguments[index]
            cursor = slotRange.upperBound
        }
        result += template[cursor...]
        return result
    }
}
