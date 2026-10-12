import Carbon
import Foundation

enum InputSourceError: LocalizedError {
    case unavailable(String)
    case selectionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable(let language):
            "활성화된 \(language) 입력 소스를 찾지 못했습니다. 시스템 설정의 키보드 > 텍스트 입력에서 추가해 주세요."
        case .selectionFailed(let status):
            "입력 소스를 선택하지 못했습니다. 오류 코드: \(status)"
        }
    }
}

@MainActor
final class InputSourceManager {
    static let shared = InputSourceManager()

    private let lastKoreanKey = "lastKoreanInputSourceID"
    private let lastEnglishKey = "lastEnglishInputSourceID"
    private let defaults = UserDefaults.standard

    private init() {}

    /// Switches by input-source identity rather than typing a synthetic shortcut.
    /// This keeps working even when the current keyboard layout is Korean.
    func toggleKoreanEnglish() throws {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        remember(current)

        let switchingToKorean = !isKorean(current)
        let candidates = selectableInputSources().filter {
            switchingToKorean ? isKorean($0) : isEnglish($0)
        }

        guard let target = preferredSource(from: candidates, korean: switchingToKorean) else {
            throw InputSourceError.unavailable(switchingToKorean ? "한국어" : "영어")
        }

        let status = TISSelectInputSource(target)
        guard status == noErr else { throw InputSourceError.selectionFailed(status) }
        remember(target)
    }

    func availabilityWarning() -> String? {
        let sources = selectableInputSources()
        guard sources.contains(where: isKorean), sources.contains(where: isEnglish) else {
            return "한/영 전환에는 한국어와 영어 입력 소스가 필요합니다. 시스템 설정 > 키보드 > 텍스트 입력에서 추가해 주세요."
        }
        return nil
    }

    private func selectableInputSources() -> [TISInputSource] {
        let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        return list.compactMap { item in
            let source = item as! TISInputSource
            guard boolProperty(source, key: kTISPropertyInputSourceIsEnabled),
                  boolProperty(source, key: kTISPropertyInputSourceIsSelectCapable) else { return nil }
            return source
        }
    }

    private func preferredSource(from sources: [TISInputSource], korean: Bool) -> TISInputSource? {
        let rememberedKey = korean ? lastKoreanKey : lastEnglishKey
        if let rememberedID = defaults.string(forKey: rememberedKey),
           let remembered = sources.first(where: { sourceID($0) == rememberedID }) {
            return remembered
        }

        if korean {
            return sources.first(where: { sourceID($0).localizedCaseInsensitiveContains("2SetKorean") })
                ?? sources.first
        }

        return sources.first(where: { sourceID($0) == "com.apple.keylayout.ABC" })
            ?? sources.first(where: { sourceID($0) == "com.apple.keylayout.US" })
            ?? sources.first
    }

    private func remember(_ source: TISInputSource) {
        let id = sourceID(source)
        guard !id.isEmpty else { return }
        if isKorean(source) {
            defaults.set(id, forKey: lastKoreanKey)
        } else if isEnglish(source) {
            defaults.set(id, forKey: lastEnglishKey)
        }
    }

    private func isKorean(_ source: TISInputSource) -> Bool {
        languages(source).contains(where: { $0 == "ko" || $0.hasPrefix("ko-") })
            || sourceID(source).localizedCaseInsensitiveContains("korean")
    }

    private func isEnglish(_ source: TISInputSource) -> Bool {
        languages(source).contains(where: { $0 == "en" || $0.hasPrefix("en-") })
            || sourceID(source).localizedCaseInsensitiveContains("keylayout.ABC")
            || sourceID(source).localizedCaseInsensitiveContains("keylayout.US")
    }

    private func languages(_ source: TISInputSource) -> [String] {
        property(source, key: kTISPropertyInputSourceLanguages) as? [String] ?? []
    }

    private func sourceID(_ source: TISInputSource) -> String {
        property(source, key: kTISPropertyInputSourceID) as? String ?? ""
    }

    private func boolProperty(_ source: TISInputSource, key: CFString) -> Bool {
        property(source, key: key) as? Bool ?? false
    }

    private func property(_ source: TISInputSource, key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}
