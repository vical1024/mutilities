import SwiftUI

struct ConflictCheckView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    private var report: ConflictReport? { settings.conflictReport }
    private var isScanning: Bool { settings.isScanning }

    var body: some View {
        let _ = uiLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("다른 앱과의 충돌"))
                            .font(.body)
                    }
                    Spacer()
                }

                if isScanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("단축키와 입력 엔진을 검사하는 중…"))
                    }
                } else if let report {
                    summary(report)
                    issues(report)
                    engineList(report)
                    if !report.issues.isEmpty { HStack {
                        HelpButton(title: "충돌 해결 방법", text: "앱 창을 닫아도 입력 엔진이 남을 수 있습니다. 해당 앱의 메뉴에서 종료하거나 설정에서 엔진을 중지하세요. 실행 중이라는 사실만으로 직접 충돌을 확정하지는 않습니다.")
                        Button(L10n.text("활동 모니터 열기")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                    } }
                }
            }
            .frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { refresh() }
        .onChange(of: settings.shortcuts) { _, _ in refresh() }
        .onChange(of: settings.shortcutError) { _, _ in refresh() }
    }

    @ViewBuilder
    private func summary(_ report: ConflictReport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: report.blockingCount > 0 ? "exclamationmark.octagon.fill" : "checkmark.shield.fill")
                .font(.title)
                .foregroundStyle(report.blockingCount > 0 ? .red : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(report.blockingCount > 0 ? "직접 충돌 \(report.blockingCount)개" : "확인된 직접 충돌 없음"))
                    .font(.body)
                Text(L10n.text("잠재적 충돌 \(report.warningCount)개 · \(report.checkedAt.formatted(date: .omitted, time: .standard)) 검사"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func issues(_ report: ConflictReport) -> some View {
        if report.issues.isEmpty {
            Label(L10n.text("현재 구성에서 충돌 징후를 찾지 못했습니다."), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            GroupBox(L10n.text("검사 결과")) {
                VStack(spacing: 0) {
                    ForEach(Array(report.issues.enumerated()), id: \.element.id) { index, issue in
                        if index > 0 { Divider().padding(.leading, 38) }
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbol(for: issue.severity))
                                .foregroundStyle(color(for: issue.severity))
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L10n.text(issue.title)).font(.body)
                                    Text(L10n.text(issue.engine))
                                        .font(.caption.weight(.regular))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Text(L10n.text(issue.detail)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 11)
                    }
                }
                .padding(4)
            }
        }
    }

    private func engineList(_ report: ConflictReport) -> some View {
        GroupBox(L10n.text("다른 입력 앱")) {
            VStack(spacing: 0) {
                ForEach(Array(report.engines.enumerated()), id: \.element.id) { index, engine in
                    if index > 0 { Divider().padding(.leading, 30) }
                    HStack {
                        Circle()
                            .fill(engine.isRunning ? Color.orange : Color.secondary.opacity(0.35))
                            .frame(width: 8, height: 8)
                        Text(L10n.text(engine.name))
                        Spacer()
                        Text(L10n.text(engine.isRunning ? "실행 중" : "감지 안 됨"))
                            .font(.caption)
                            .foregroundStyle(engine.isRunning ? .orange : .secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(4)
        }
    }

    private func refresh() {
        Task { await settings.scanConflicts() }
    }

    private func symbol(for severity: ConflictSeverity) -> String {
        switch severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocking: "xmark.octagon.fill"
        }
    }

    private func color(for severity: ConflictSeverity) -> Color {
        switch severity {
        case .info: .blue
        case .warning: .orange
        case .blocking: .red
        }
    }
}
