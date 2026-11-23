import SwiftUI

/// Lists every managed macOS setting the app has changed since it started, so nothing happens silently.
struct ChangesView: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let _ = uiLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPageHeader(title: "변경 내역", symbol: "list.bullet.clipboard")
                GroupBox(L10n.text("동작 방식")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.text("시작할 때 현재 설정을 백업하고, 이 앱이 관리하는 macOS 설정을 기본값으로 초기화합니다."), systemImage: "1.circle")
                        Label(L10n.text("그 위에 앱에서 설정한 값만 적용합니다."), systemImage: "2.circle")
                        Label(L10n.text("종료하면 백업한 원래 값으로 복원합니다."), systemImage: "3.circle")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox(L10n.text("시작 전과 현재 값 비교")) {
                    if settings.managedChanges.isEmpty {
                        Text(L10n.text(settings.sessionReady ? "앱이 바꾼 macOS 설정이 없습니다." : "시작 백업이 끝나면 변경 내역이 표시됩니다."))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(settings.managedChanges) { change in
                                ChangeRow(change: change)
                                if change.id != settings.managedChanges.last?.id { Divider() }
                            }
                        }.padding(8)
                    }
                }
                Text(L10n.text("종료 시 복원할 값은 시작 전 백업 기준입니다. 앱 기능(키 교체, 창 전환 등)은 macOS 설정을 바꾸지 않고 실행 중에만 동작합니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 860, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            // Refresh while the page is visible; the task is cancelled when it disappears.
            while !Task.isCancelled {
                await settings.refreshChanges()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct ChangeRow: View {
    let change: ManagedChange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.text(change.title)).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text(change.before)).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(L10n.text(change.now)).fontWeight(.medium).lineLimit(1)
                .foregroundStyle(change.kind == .reset ? Color.orange : Color.accentColor)
        }.padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}
