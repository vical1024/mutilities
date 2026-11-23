import Foundation

/// One macOS setting whose value now differs from what it was when the app started.
struct ManagedChange: Identifiable, Equatable {
    enum Kind: Equatable { case reset, set, changed }

    let id: String
    let title: String
    let before: String
    let now: String
    let kind: Kind

    static let defaultValue = "기본값"

    static func diff(before: SystemSettingsBackup, now: SystemSettingsBackup,
                     beforeFunctionKeys: Bool?, nowFunctionKeys: Bool?) -> [ManagedChange] {
        let old = Dictionary(uniqueKeysWithValues: before.preferences.map { ($0.address, $0.value) })
        let new = Dictionary(uniqueKeysWithValues: now.preferences.map { ($0.address, $0.value) })
        var changes: [ManagedChange] = []

        for address in Set(old.keys).union(new.keys) where SystemDefaultsService.isManaged(address) {
            let left = old[address].flatMap(plistValue), right = new[address].flatMap(plistValue)
            if let left, let right, isEqual(left, right) { continue }
            if left == nil && right == nil { continue }
            let kind: Kind = right == nil ? .reset : left == nil ? .set : .changed
            var beforeText = left.map(describe) ?? defaultValue
            var nowText = right.map(describe) ?? defaultValue
            if beforeText == nowText { beforeText += " · 이전 내용"; nowText += " · 변경됨" }
            changes.append(ManagedChange(id: "\(address.domain)/\(address.currentHost)/\(address.key)",
                                         title: title(for: address), before: beforeText, now: nowText, kind: kind))
        }

        let beforeMappings = before.hidMappings.count, nowMappings = now.hidMappings.count
        if beforeMappings != nowMappings {
            changes.append(ManagedChange(id: "hid-mappings", title: "보조 키 교체 (실행 중 키보드)",
                                         before: beforeMappings == 0 ? defaultValue : "\(beforeMappings)개",
                                         now: nowMappings == 0 ? defaultValue : "\(nowMappings)개",
                                         kind: nowMappings == 0 ? .reset : beforeMappings == 0 ? .set : .changed))
        }
        if let beforeFunctionKeys, let nowFunctionKeys, beforeFunctionKeys != nowFunctionKeys {
            changes.append(ManagedChange(id: "function-keys", title: "F1–F12 키 동작",
                                         before: beforeFunctionKeys ? "표준 F키" : "특수 기능 키",
                                         now: nowFunctionKeys ? "표준 F키" : "특수 기능 키", kind: .changed))
        }
        return changes.sorted { $0.title < $1.title }
    }

    static func title(for address: PreferenceAddress) -> String {
        let key = address.key
        if address.domain == "com.apple.dock" {
            switch key {
            case "autohide": return "Dock 자동 숨김"
            case "autohide-delay": return "Dock 숨김 지연"
            case "autohide-time-modifier": return "Dock 숨김 속도"
            case "tilesize": return "Dock 크기"
            case "magnification": return "Dock 확대"
            case "largesize": return "Dock 확대 크기"
            default: break
            }
            if key.hasPrefix("wvous-") {
                let corner = ["tl": "왼쪽 위", "tr": "오른쪽 위", "bl": "왼쪽 아래", "br": "오른쪽 아래"][String(key.dropFirst(6).prefix(2))] ?? key
                return "핫 코너 \(corner) · \(key.hasSuffix("modifier") ? "보조 키" : "동작")"
            }
        }
        if key == "com.apple.keyboard.fnState" { return "F1–F12 표준 기능 키" }
        if key.hasPrefix("com.apple.keyboard.modifiermapping.") { return "보조 키 교체 (\(key.dropFirst("com.apple.keyboard.modifiermapping.".count)))" }
        if key == "AppleSymbolicHotKeys" { return "macOS 시스템 단축키" }
        if key == "NSUserKeyEquivalents" { return address.domain == "NSGlobalDomain" ? "앱 메뉴 단축키 (모든 앱)" : "앱 메뉴 단축키 (\(address.domain))" }
        return "\(address.domain) · \(key)"
    }

    private static func plistValue(_ data: Data) -> Any? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["value"]
    }

    private static func isEqual(_ left: Any, _ right: Any) -> Bool {
        (left as AnyObject).isEqual(right)
    }

    static func describe(_ value: Any) -> String {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "켜짐" : "꺼짐" }
            return number.stringValue
        }
        if let text = value as? String { return text }
        if let dictionary = value as? [String: Any] { return "항목 \(dictionary.count)개" }
        if let array = value as? [Any] { return "\(array.count)개" }
        return String(describing: value)
    }
}
