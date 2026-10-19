import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Security
import SwiftUI

enum EnglishAssistDefaults {
    static let enabledKey = "englishAssist.enabled"
    static let delayKey = "englishAssist.delay"
    static let appsKey = "englishAssist.apps"
    static let defaultDelay = 3.5
    static let defaultApps = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.kakao.KakaoTalkMac"]
    static let model = "claude-haiku-5-5"

    static var delay: Double {
        let value = UserDefaults.standard.object(forKey: delayKey) as? Double ?? defaultDelay
        return value.isFinite ? min(10, max(1, value)) : defaultDelay
    }
    static var apps: [String] { UserDefaults.standard.stringArray(forKey: appsKey) ?? defaultApps }
}

enum EnglishAssistKeychain {
    private static let service = "dev.local.MacInterfaceController.anthropic"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        let item = query.merging([kSecValueData as String: Data(key.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

struct EnglishSuggestion: Decodable, Equatable {
    struct Word: Decodable, Equatable {
        let ko: String
        let en: String
        let note: String?
    }
    let translation: String
    let alternatives: [String]?
    let words: [Word]?
}

/// Reads the Korean sentence being typed, and after a pause offers an English version and word notes.
@MainActor
final class EnglishAssistController: ObservableObject {
    static let shared = EnglishAssistController()

    enum State: Equatable {
        case hidden
        case loading(source: String)
        case ready(source: String, suggestion: EnglishSuggestion)
        case failed(String)
    }

    @Published private(set) var state: State = .hidden

    private var keyMonitor: Any?
    private var idleTimer: Timer?
    private var hideTimer: Timer?
    private var request: Task<Void, Never>?
    private var lastSource = ""
    private var manualAccessibilityPIDs: Set<pid_t> = []
    private lazy var panel = EnglishAssistPanel(controller: self)

    func start() {
        refresh()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: EnglishAssistDefaults.enabledKey) }

    private func refresh() {
        if isEnabled, keyMonitor == nil {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
                Task { @MainActor in self?.noteTyping() }
            }
        } else if !isEnabled, keyMonitor != nil {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            idleTimer?.invalidate()
            dismiss()
        }
    }

    private func noteTyping() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: EnglishAssistDefaults.delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.typingPaused() }
        }
    }

    func dismiss() {
        request?.cancel()
        hideTimer?.invalidate()
        state = .hidden
        panel.hide()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func typingPaused() {
        guard isEnabled, let app = NSWorkspace.shared.frontmostApplication,
              let identifier = app.bundleIdentifier, EnglishAssistDefaults.apps.contains(identifier),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !IsSecureEventInputEnabled(),
              let source = currentKoreanSentence(pid: app.processIdentifier), source != lastSource else { return }
        guard let key = EnglishAssistKeychain.read(), !key.isEmpty else {
            show(.failed(L10n.text("Anthropic API 키를 설정에서 등록해 주세요.")))
            lastSource = source
            return
        }
        lastSource = source
        show(.loading(source: source))
        request?.cancel()
        request = Task { [weak self] in
            do {
                let suggestion = try await Self.translate(source, apiKey: key)
                guard !Task.isCancelled else { return }
                self?.show(.ready(source: source, suggestion: suggestion))
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(.failed(error.localizedDescription))
            }
        }
    }

    private func show(_ newState: State) {
        state = newState
        panel.show()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    // MARK: Reading the focused text field

    private func currentKoreanSentence(pid: pid_t) -> String? {
        if manualAccessibilityPIDs.insert(pid).inserted {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue else { return nil }
        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.3)

        func string(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }
        guard let role = string(kAXRoleAttribute as String),
              [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role),
              string(kAXSubroleAttribute as String) != (kAXSecureTextFieldSubrole as String),
              let text = string(kAXValueAttribute as String) else { return nil }

        var typed = text as NSString
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                typed = typed.substring(to: min(max(range.location, 0), typed.length)) as NSString
            }
        }
        return Self.lastSentence(in: typed as String)
    }

    static func lastSentence(in text: String) -> String? {
        guard var line = text.split(whereSeparator: \.isNewline).last.map(String.init) else { return nil }
        line = line.trimmingCharacters(in: .whitespaces)
        let ends: Set<Character> = [".", "?", "!", "。"]
        var body = line
        while let last = body.last, ends.contains(last) { body.removeLast() }
        if let split = body.lastIndex(where: { ends.contains($0) }) { body = String(body[body.index(after: split)...]) }
        let sentence = String(body.trimmingCharacters(in: .whitespaces).suffix(240))
        let hangul = sentence.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }.count
        let letters = sentence.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard hangul >= 2, letters > 0, Double(hangul) / Double(letters) >= 0.3 else { return nil }
        return sentence
    }

    // MARK: Anthropic API

    private struct APIError: LocalizedError { let errorDescription: String? }

    nonisolated static func translate(_ sentence: String, apiKey: String) async throws -> EnglishSuggestion {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let system = """
        You help a Korean speaker write natural English. The user message is one Korean sentence they are typing. \
        Reply with ONLY a JSON object: {"translation": "<natural English>", "alternatives": ["<up to 2 other phrasings, different tone>"], \
        "words": [{"ko": "<Korean word>", "en": "<English word or phrase>", "note": "<short Korean usage note>"}]}. \
        Include at most 4 useful words. No markdown, no extra text.
        """
        let body: [String: Any] = ["model": EnglishAssistDefaults.model, "max_tokens": 700, "system": system,
                                   "messages": [["role": "user", "content": sentence]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (root?["error"] as? [String: Any])?["message"] as? String
            throw APIError(errorDescription: message ?? "API 요청이 실패했습니다.")
        }
        guard let content = root?["content"] as? [[String: Any]], let text = content.first?["text"] as? String,
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = String(text[start...end]).data(using: .utf8),
              let suggestion = try? JSONDecoder().decode(EnglishSuggestion.self, from: json) else {
            throw APIError(errorDescription: "응답을 해석하지 못했습니다.")
        }
        return suggestion
    }
}

// MARK: Floating panel

@MainActor
final class EnglishAssistPanel {
    private let panel: NSPanel
    private let host: NSHostingView<EnglishAssistPanelView>

    init(controller: EnglishAssistController) {
        host = NSHostingView(rootView: EnglishAssistPanelView(controller: controller))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = host
    }

    func show() {
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: 380, height: min(host.fittingSize.height, 520))
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: area.minX + 16, y: area.minY + 16, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

struct EnglishAssistPanelView: View {
    @ObservedObject var controller: EnglishAssistController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.text("영작 제안"), systemImage: "character.bubble").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            switch controller.state {
            case .hidden:
                EmptyView()
            case .loading(let source):
                Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack { ProgressView().controlSize(.small); Text(L10n.text("영작 중…")).font(.callout).foregroundStyle(.secondary) }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.orange)
            case .ready(let source, let suggestion):
                Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(alignment: .top) {
                    Text(suggestion.translation).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { controller.copy(suggestion.translation) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help(L10n.text("복사"))
                }
                ForEach(suggestion.alternatives ?? [], id: \.self) { alternative in
                    Text("• " + alternative).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let words = suggestion.words, !words.isEmpty {
                    Divider()
                    ForEach(words, id: \.ko) { word in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(word.ko) → \(word.en)").font(.callout.weight(.medium))
                            if let note = word.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}

// MARK: Settings

struct EnglishAssistSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @AppStorage(EnglishAssistDefaults.enabledKey) private var enabled = false
    @AppStorage(EnglishAssistDefaults.delayKey) private var delay = EnglishAssistDefaults.defaultDelay
    @State private var apps = EnglishAssistDefaults.apps
    @State private var apiKey = ""
    @State private var hasKey = false

    var body: some View {
        let _ = uiLanguage
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                SettingsToggleRow(title: "영작 도우미", detail: "한국어 입력이 멈추면 영작과 단어 설명을 왼쪽 아래에 띄웁니다.", symbol: "character.bubble", isOn: $enabled, showsDetailInline: true)
                if enabled {
                    HStack {
                        SecureField(L10n.text(hasKey ? "API 키 저장됨 (바꾸려면 새 키 입력)" : "Anthropic API 키"), text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button(L10n.text("저장")) {
                            hasKey = EnglishAssistKeychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)) && !apiKey.isEmpty
                            apiKey = ""
                        }.disabled(apiKey.isEmpty)
                        if hasKey { Button(L10n.text("삭제")) { EnglishAssistKeychain.save(""); hasKey = false } }
                    }
                    HStack {
                        Text(L10n.text("입력이 멈춘 뒤 대기"))
                        Slider(value: $delay, in: 1...8)
                        Text(String(format: "%.1f", (delay * 2).rounded() / 2) + L10n.text("초")).monospacedDigit().frame(width: 55, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("동작할 앱")).foregroundStyle(.secondary)
                        ForEach(apps, id: \.self) { identifier in
                            HStack {
                                Text(name(of: identifier)); Spacer()
                                Button { apps.removeAll { $0 == identifier }; save() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            }
                        }
                        Menu(L10n.text("앱 추가")) {
                            ForEach(runningApplications, id: \.bundleIdentifier) { application in
                                Button(application.localizedName ?? application.bundleIdentifier ?? "") {
                                    if let id = application.bundleIdentifier, !apps.contains(id) { apps.append(id); save() }
                                }
                            }
                        }.fixedSize()
                    }
                    Text(L10n.text("선택한 앱에서 입력한 한국어 문장이 Anthropic API로 전송됩니다. 비밀번호 등 보안 입력창은 읽지 않습니다."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { hasKey = EnglishAssistKeychain.read() != nil }
    }

    private var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !apps.contains($0.bundleIdentifier!)
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func name(of identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func save() { UserDefaults.standard.set(apps, forKey: EnglishAssistDefaults.appsKey) }
}
