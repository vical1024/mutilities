import Foundation
import CoreFoundation

/// Keep per-device values separate: a global backup must never flatten differing maps.
struct HIDMappingSnapshot {
    let values: [[HIDMapping]]
    var hasMappings: Bool { values.contains { !$0.isEmpty } }
    func commonMappings() throws -> [HIDMapping] {
        guard let first = values.first else { return [] }
        guard values.allSatisfy({ $0 == first }) else {
            throw SystemDefaultsError.commandFailed("장치별 HID 키 매핑이 서로 다릅니다. 현재 공통 매핑 백업으로는 안전하게 복원할 수 없어 변경하지 않습니다. 장치별 매핑을 설정한 앱에서 먼저 확인해 주세요.")
        }
        return first
    }
}

enum HIDMappingParser {
    static func parse(_ data: Data) throws -> HIDMappingSnapshot {
        guard let raw = String(data: data, encoding: .utf8) else { throw invalid() }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("RegistryID") {
            let lines = text.components(separatedBy: .newlines)
            guard lines[0].split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["RegistryID", "Key", "Value"] else { throw invalid() }
            let row = try NSRegularExpression(pattern: #"^\s*([0-9a-fA-Fx]+)\s+UserKeyMapping\s+(.+)$"#)
            var ids = Set<String>()
            var entries: [String] = []
            for line in lines.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let range = NSRange(line.startIndex..., in: line)
                if let match = row.firstMatch(in: line, range: range),
                   let idRange = Range(match.range(at: 1), in: line),
                   let valueRange = Range(match.range(at: 2), in: line) {
                    guard ids.insert(String(line[idRange])).inserted else { throw invalid() }
                    entries.append(String(line[valueRange]))
                } else {
                    guard !entries.isEmpty else { throw invalid() }
                    entries[entries.count - 1] += "\n" + line
                }
            }
            // A header with no devices is not proof that system mappings are empty.
            guard !entries.isEmpty else { throw invalid() }
            return try HIDMappingSnapshot(values: entries.map(decodeValue))
        }
        return try HIDMappingSnapshot(values: [decodeValue(text)])
    }

    private static func decodeValue(_ text: String) throws -> [HIDMapping] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "(null)" || text == "null" { return [] }
        let data = Data(text.utf8)
        let object: Any
        if let json = try? JSONSerialization.jsonObject(with: data) { object = json }
        else if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) { object = plist }
        else { throw invalid() }
        guard let array = object as? [[String: Any]] else { throw invalid() }
        var sources = Set<UInt64>()
        return try array.map { item in
            func number(_ key: String) throws -> UInt64 {
                guard let value = item[key] else { throw invalid() }
                if let n = value as? NSNumber {
                    guard CFGetTypeID(n) != CFBooleanGetTypeID(), let result = UInt64(n.stringValue) else { throw invalid() }
                    return result
                }
                if let s = value as? String {
                    let n = s.lowercased().hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16) : UInt64(s)
                    if let n { return n }
                }
                throw invalid()
            }
            let mapping = try HIDMapping(source: number("HIDKeyboardModifierMappingSrc"), destination: number("HIDKeyboardModifierMappingDst"))
            guard sources.insert(mapping.source).inserted else { throw invalid() }
            return mapping
        }.sorted { $0.source < $1.source }
    }

    private static func invalid() -> SystemDefaultsError {
        .commandFailed("HID 키 매핑 출력 형식을 읽지 못했습니다. 시스템 키 설정은 변경하지 않았습니다.")
    }
}
