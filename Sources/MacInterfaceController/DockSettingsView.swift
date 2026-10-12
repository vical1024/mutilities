import SwiftUI

struct DockTiming: Equatable {
    var delay: Double
    var duration: Double
    var isValid: Bool { delay.isFinite && duration.isFinite && (0...5).contains(delay) && (0...5).contains(duration) }
}

struct DockSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @State private var autoHide = false
    @State private var delay = 0.5
    @State private var duration = 0.5
    @State private var preset = "기본"
    @State private var tileSize: Double?
    @State private var largeSize: Double?
    @State private var magnification = false
    @State private var edge = "bottom"
    @State private var lastSubmitted: DockConfiguration?
    var body: some View {
        let _ = uiLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPageHeader(title: "Dock", symbol: "dock.rectangle", help: "설정을 비활성화하거나 앱을 종료하면 이전 Dock 설정으로 돌아갑니다. 변경할 때 Dock이 다시 시작될 수 있습니다.")
                GroupBox(L10n.text("표시 방식")) {
                    VStack(spacing: 14) {
                        Picker(L10n.text("표시 방식"), selection: $autoHide) {
                            Text(L10n.text("상시 표시")).tag(false)
                            Text(L10n.text("자동 숨기기")).tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                        if autoHide { DockEdgePreview(edge: edge) }
                    }.padding(8)
                }.disabled(!settings.sessionReady || settings.isWorking)
                GroupBox(L10n.text("아이콘 크기")) {
                    VStack(spacing: 16) {
                        sizeRow("기본 크기", value: Binding(get: { tileSize }, set: { value in
                            tileSize = value
                            if magnification, let value, let largeSize, largeSize < value { self.largeSize = value }
                        }), fallback: 64, minimum: 16)
                        SettingsToggleRow(title: "마우스를 올리면 확대", symbol: "plus.magnifyingglass", isOn: $magnification)
                            .onChange(of: magnification) { _, enabled in
                                if enabled, let tileSize, let largeSize, largeSize < tileSize { self.largeSize = tileSize }
                            }
                        if magnification {
                            sizeRow("최대 확대 크기", value: $largeSize, fallback: 128, minimum: tileSize ?? 16)
                        }
                    }.padding(8)
                }.disabled(!settings.sessionReady || settings.isWorking)
                if autoHide { GroupBox(L10n.text("표시 속도")) {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker(L10n.text("속도"), selection: $preset) {
                            ForEach(["즉시", "빠르게", "기본", "직접 설정"], id: \.self) { Text(L10n.text($0)).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                        .onChange(of: preset) { _, value in
                            if value == "즉시" { delay = 0; duration = 0 }
                            if value == "빠르게" { delay = 0.1; duration = 0.2 }
                        }
                        if preset != "기본" {
                            timingRow("표시 지연", value: $delay)
                            timingRow("펼침 시간", value: $duration)
                        }
                    }.padding(8)
                }.disabled(!settings.sessionReady || settings.isWorking) }
                if !configuration.isValid { Text(L10n.text("크기는 16–128, 시간은 0–5초로 지정하세요.")).font(.caption).foregroundStyle(.orange) }
                if let error = settings.historyError { SettingsNotice(title: "설정 확인 필요", detail: error) }
            }.frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { load() }
        .onChange(of: configuration) { _, value in
            guard lastSubmitted != nil, value != lastSubmitted, value.isValid,
                  settings.sessionReady, !settings.isWorking else { return }
            lastSubmitted = value
            settings.setDockConfiguration(value)
        }
        .onChange(of: settings.dockConfiguration) { _, value in
            if value != lastSubmitted { load() }
        }
    }
    private var configuration: DockConfiguration {
        DockConfiguration(autoHide: autoHide, delay: preset == "기본" ? nil : delay, duration: preset == "기본" ? nil : duration, tileSize: tileSize, magnification: magnification, largeSize: largeSize)
    }
    private func load() {
        let domain = "com.apple.dock" as CFString
        edge = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String ?? "bottom"
        let config = settings.dockConfiguration ?? DockConfiguration(
            autoHide: CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false,
            delay: (CFPreferencesCopyAppValue("autohide-delay" as CFString, domain) as? NSNumber)?.doubleValue,
            duration: (CFPreferencesCopyAppValue("autohide-time-modifier" as CFString, domain) as? NSNumber)?.doubleValue)
        tileSize = config.tileSize ?? (CFPreferencesCopyAppValue("tilesize" as CFString, domain) as? NSNumber)?.doubleValue
        largeSize = config.largeSize ?? (CFPreferencesCopyAppValue("largesize" as CFString, domain) as? NSNumber)?.doubleValue
        magnification = config.magnification ?? (CFPreferencesCopyAppValue("magnification" as CFString, domain) as? Bool ?? false)
        autoHide = config.autoHide
        delay = config.delay ?? 0.5
        duration = config.duration ?? 0.5
        preset = config.delay == nil && config.duration == nil ? "기본" : "직접 설정"
        lastSubmitted = configuration
    }
    private func sizeRow(_ title: String, value: Binding<Double?>, fallback: Double, minimum: Double) -> some View {
        HStack {
            Text(L10n.text(title)).font(.body).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { min(128, max(minimum, value.wrappedValue ?? fallback)) }, set: { value.wrappedValue = $0 }), in: min(128, max(16, minimum))...128, step: 1)
                .accessibilityLabel(L10n.text(title))
            Text(L10n.text(value.wrappedValue.map { String(format: "%.0f", $0) } ?? "기본값")).monospacedDigit().frame(width: 55, alignment: .trailing)
        }
    }
    private func timingRow(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(L10n.text(title)).font(.body)
            Spacer()
            TextField(L10n.text(title), value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; preset = "직접 설정" }), format: .number)
                .frame(width: 70).textFieldStyle(.roundedBorder)
            Text(L10n.text("초")).foregroundStyle(.secondary)
        }
    }
}


private struct DockEdgePreview: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    let edge: String
    private var vertical: Bool { edge == "left" || edge == "right" }
    private var alignment: Alignment { edge == "left" ? .leading : edge == "right" ? .trailing : .bottom }
    private var title: String { edge == "left" ? "왼쪽 가장자리" : edge == "right" ? "오른쪽 가장자리" : "하단 가장자리" }
    var body: some View {
        let _ = uiLanguage
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.35))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)) }
                .overlay(alignment: alignment) {
                    Capsule().fill(Color.accentColor)
                        .frame(width: vertical ? 4 : 144, height: vertical ? 76 : 4)
                        .padding(4)
                }
                .frame(width: 164, height: 96)
                .accessibilityHidden(true)
            Text(L10n.text(title)).font(.callout)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Dock 표시 위치: \(title)"))
    }
}
