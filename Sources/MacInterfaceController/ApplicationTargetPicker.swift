import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationTargetPicker: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @Binding var target: ApplicationTarget
    @State private var selectionError: String?

    var body: some View {
        let _ = uiLanguage
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("대상 앱")).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Menu {
                    Section(L10n.text("실행 중인 앱")) {
                        ForEach(runningApplications, id: \.bundleIdentifier) { application in
                            Button(application.localizedName ?? application.bundleIdentifier ?? "앱") {
                                guard let identifier = application.bundleIdentifier else { return }
                                target = ApplicationTarget(bundleIdentifier: identifier, name: application.localizedName ?? identifier)
                                selectionError = nil
                            }
                        }
                    }
                    Divider()
                    Button(L10n.text("다른 앱 선택…"), action: chooseApplication)
                } label: {
                    Text(target.isConfigured ? target.displayName : L10n.text("앱을 선택하세요"))
                }.frame(maxWidth: 360, alignment: .leading)
                HelpButton(title: "앱 표시 / 숨기기", text: "앱의 모든 창을 함께 표시하거나 숨깁니다. 숨기면 이전 앱으로 돌아갑니다.")
                Spacer(minLength: 0)
            }
            if let selectionError {
                Text(L10n.text(selectionError)).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("표시 / 숨기기에 사용할 앱 선택")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else {
            selectionError = "이 앱의 식별자를 읽을 수 없습니다. 다른 앱을 선택해 주세요."
            return
        }
        target = ApplicationTarget(bundleIdentifier: identifier,
                                   name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        selectionError = nil
    }
}
