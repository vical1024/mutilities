import Carbon
import Foundation
import AppKit
import os

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

    private static let useSystemShortcutKey = "inputSource.useSystemShortcut"
    private let lastKoreanKey = "lastKoreanInputSourceID"
    private let lastEnglishKey = "lastEnglishInputSourceID"
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "dev.local.MacInterfaceController", category: "input-source")

    /// The system can lag behind a selection, so rapid toggles must build on the last request.
    private var lastRequest: (id: Int, korean: Bool, at: ContinuousClock.Instant)?
    private var requestCounter = 0
    private var cachedSources: (sources: [TISInputSource], at: ContinuousClock.Instant)?
    private static let requestTrustWindow: Duration = .milliseconds(400)
    private static let sourceCacheLifetime: Duration = .seconds(10)

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cachedSources = nil }
        }
    }

    /// Selects the input source directly. With `inputSource.useSystemShortcut` set, types the system's
    /// "Select the previous input source" shortcut instead so macOS notifies the focused app itself;
    /// that mode falls back to direct selection when the shortcut is off.
    func toggleKoreanEnglish() throws {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        remember(current)

        if defaults.bool(forKey: Self.useSystemShortcutKey), let shortcut = Self.systemSwitchShortcut() {
            postSystemSwitchShortcut(shortcut)
            record("toggle via system shortcut keyCode=\(shortcut.keyCode) flags=\(shortcut.flags.rawValue) tisKorean=\(isKorean(current)) secureInput=\(IsSecureEventInputEnabled()) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
            return
        }

        var currentIsKorean = isKorean(current)
        if let last = lastRequest, last.at.duration(to: .now) < Self.requestTrustWindow {
            currentIsKorean = last.korean
        }
        let switchingToKorean = !currentIsKorean
        let candidates = selectableInputSources().filter {
            switchingToKorean ? isKorean($0) : isEnglish($0)
        }

        guard let target = preferredSource(from: candidates, korean: switchingToKorean) else {
            throw InputSourceError.unavailable(switchingToKorean ? "한국어" : "영어")
        }

        let started = ContinuousClock.now
        let status = TISSelectInputSource(target)
        let after = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        record("toggle toKorean=\(switchingToKorean) tisKorean=\(isKorean(current)) trusted=\(currentIsKorean) status=\(status) took=\(started.duration(to: .now).description) nowKorean=\(isKorean(after)) secureInput=\(IsSecureEventInputEnabled()) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        guard status == noErr else { throw InputSourceError.selectionFailed(status) }
        remember(target)
        requestCounter += 1
        lastRequest = (requestCounter, switchingToKorean, .now)
    }

    /// Symbolic hot key 60 is "Select the previous input source"; parameters are [character, key code, modifier flags].
    private static func systemSwitchShortcut() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
              let entry = all["60"] as? [String: Any],
              entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count >= 3,
              parameters[1] >= 0, parameters[1] != 65535 else { return nil }
        return (CGKeyCode(parameters[1]), CGEventFlags(rawValue: UInt64(parameters[2])))
    }

    private func postSystemSwitchShortcut(_ shortcut: (keyCode: CGKeyCode, flags: CGEventFlags)) {
        let modifiers: [(CGEventFlags, CGKeyCode)] = [
            (.maskShift, CGKeyCode(kVK_Shift)), (.maskControl, CGKeyCode(kVK_Control)),
            (.maskAlternate, CGKeyCode(kVK_Option)), (.maskCommand, CGKeyCode(kVK_Command)),
        ].filter { shortcut.flags.contains($0.0) }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: LiveMacroBackend.eventTag)
            event.post(tap: .cghidEventTap)
        }
        var held = CGEventFlags()
        for (flag, key) in modifiers { held.insert(flag); post(key, down: true, flags: held) }
        post(shortcut.keyCode, down: true, flags: shortcut.flags)
        post(shortcut.keyCode, down: false, flags: shortcut.flags)
        for (flag, key) in modifiers.reversed() { held.remove(flag); post(key, down: false, flags: held) }
    }

    private func record(_ message: String) {
        log.info("\(message, privacy: .public)")
        InputSourceFileLog.shared.write(message)
    }

    func availabilityWarning() -> String? {
        let sources = selectableInputSources()
        guard sources.contains(where: isKorean), sources.contains(where: isEnglish) else {
            return "한/영 전환에는 한국어와 영어 입력 소스가 필요합니다. 시스템 설정 > 키보드 > 텍스트 입력에서 추가해 주세요."
        }
        return nil
    }

    private func selectableInputSources() -> [TISInputSource] {
        if let cached = cachedSources, cached.at.duration(to: .now) < Self.sourceCacheLifetime { return cached.sources }
        let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        let sources: [TISInputSource] = list.compactMap { item in
            let source = item as! TISInputSource
            guard boolProperty(source, key: kTISPropertyInputSourceIsEnabled),
                  boolProperty(source, key: kTISPropertyInputSourceIsSelectCapable) else { return nil }
            return source
        }
        cachedSources = (sources, .now)
        return sources
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
