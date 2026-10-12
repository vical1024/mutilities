import SwiftUI

/// Presentation groups share storage so existing profiles and conflict checks stay intact.
enum ShortcutLibrary {
    case shortcuts, macros

    func includes(_ rule: ShortcutRule) -> Bool {
        rule.templateID == nil && (rule.action == .macro) == (self == .macros)
    }
    var title: String { self == .macros ? "매크로" : "단축키" }
    var symbol: String { self == .macros ? "list.bullet.rectangle" : "command" }
}

private enum ShortcutFilter: String, CaseIterable, Identifiable {
    case all = "전체", applications = "앱 전환", shortcuts = "기타 동작"
    var id: String { rawValue }
    func includes(_ rule: ShortcutRule) -> Bool {
        switch self {
        case .all: true
        case .applications: rule.action == .toggleApplication
        case .shortcuts: rule.action != .toggleApplication
        }
    }
}

struct ShortcutSettingsView: View {
    var body: some View { ShortcutLibraryView(library: .shortcuts) }
}

struct MacroSettingsView: View {
    var body: some View { ShortcutLibraryView(library: .macros) }
}

private struct ShortcutLibraryView: View {
    let library: ShortcutLibrary
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: AppNavigation
    @ObservedObject private var macroRunner = MacroRunner.shared
    @State private var filter: ShortcutFilter = .all
    @State private var expandedID: UUID?
    @State private var deleteID: UUID?
    private var isMacro: Bool { library == .macros }
    private var visibleRules: [ShortcutRule] { settings.shortcuts.filter { library.includes($0) && (isMacro || filter.includes($0)) } }

    var body: some View {
        let _ = uiLanguage
        ScrollViewReader { scroll in
            SettingsPage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SettingsPageHeader(title: library.title, symbol: library.symbol)
                        Spacer()
                        if isMacro {
                            Button { add(.macro) } label: { Label(L10n.text("매크로 추가"), systemImage: "plus") }
                        } else {
                            Menu {
                                Button(L10n.text("앱 표시 / 숨기기 추가")) { add(.toggleApplication) }
                                Button(L10n.text("단축키 추가")) { add(.applications) }
                                Button(L10n.text("한/영 전환 추가")) { add(.toggleInputSource) }
                            } label: { Label(L10n.text("단축키 추가"), systemImage: "plus") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
                MappingReadinessNotice()
                if let error = settings.shortcutError {
                    SettingsNotice(title: "단축키 등록 확인 필요", detail: error, actionTitle: "충돌 검사", action: { navigation.openCheck(.conflicts) })
                }
                if !isMacro {
                    Picker(L10n.text("동작 종류"), selection: $filter) {
                        ForEach(ShortcutFilter.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if isMacro, let status = macroRunner.status {
                    HStack {
                        Text(L10n.text(status)).font(.callout)
                        Spacer()
                        if macroRunner.isRunning { Button(L10n.text("매크로 중지 · Esc")) { macroRunner.cancel() } }
                    }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                if visibleRules.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: library.symbol).font(.title2).foregroundStyle(.secondary)
                        Text(L10n.text(isMacro ? "등록된 매크로가 없습니다." : "표시할 단축키가 없습니다.")).font(.body)
                        if isMacro { Button(L10n.text("매크로 추가")) { add(.macro) } }
                    }.padding(24).frame(maxWidth: .infinity).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
                }
                ForEach($settings.shortcuts) { $rule in
                    if library.includes(rule) && (isMacro || filter.includes(rule)) {
                        ShortcutRuleRow(rule: $rule, expanded: Binding(
                            get: { expandedID == rule.id }, set: { expandedID = $0 ? rule.id : nil }
                        ), delete: { deleteID = rule.id })
                        .id(rule.id)
                    }
                }
            }
            .onChange(of: settings.shortcuts.map(\.id)) { _, ids in
                if let expandedID, ids.contains(expandedID) {
                    withAnimation { scroll.scrollTo(expandedID, anchor: .top) }
                }
            }
        }
        .onChange(of: settings.shortcuts) { _, rules in
            if let expandedID, let edited = rules.first(where: { $0.id == expandedID }), !filter.includes(edited) {
                filter = .all
            }
        }
        .confirmationDialog(L10n.text(isMacro ? "이 매크로를 삭제할까요?" : "이 단축키를 삭제할까요?"), isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }), titleVisibility: .visible) {
            Button(L10n.text(isMacro ? "매크로 삭제" : "단축키 삭제"), role: .destructive) {
                if let deleteID { settings.shortcuts.removeAll { $0.id == deleteID } }
                deleteID = nil
            }
        } message: {
            if let rule = settings.shortcuts.first(where: { $0.id == deleteID }) {
                Text("\(L10n.text(rule.actionTitle)) · \(rule.displayText)")
            }
            Text(L10n.text(isMacro ? "실행 키와 입력 순서가 함께 삭제됩니다." : "이 단축키에 지정한 동작이 삭제됩니다."))
        }
    }
    private func add(_ action: AppAction) {
        filter = action == .toggleApplication ? .applications : .shortcuts
        expandedID = settings.addShortcut(action: action)
    }
}

struct ShortcutRuleRow: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @Binding var rule: ShortcutRule
    @Binding var expanded: Bool
    let delete: () -> Void
    var body: some View {
        let _ = uiLanguage
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L10n.text(rule.actionTitle), systemImage: rule.action.symbol).font(.body)
                            if rule.action == .macro && !expanded && (rule.macro ?? KeyMacro()).validationError != nil {
                                Text(L10n.text("입력 순서 확인 필요")).font(.caption).foregroundStyle(.orange)
                            }
                            if rule.action == .toggleApplication {
                                Text(rule.targetApplication.isConfigured ? rule.targetApplication.displayName : L10n.text("앱을 선택하세요"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        ShortcutBadge(keys: rule.displayText)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.text(expanded ? "편집 접기" : "키 조합과 동작 편집"))
                Toggle(L10n.text("\(rule.actionTitle) 사용"), isOn: $rule.isEnabled).labelsHidden().toggleStyle(.switch)
                    .disabled(rule.action == .macro && !rule.isEnabled && (rule.macro ?? KeyMacro()).validationError != nil)
                if rule.templateID == nil { Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(L10n.text(rule.action == .macro ? "매크로 삭제" : "단축키 삭제")).accessibilityLabel("\(L10n.text(rule.actionTitle)) · \(L10n.text(rule.action == .macro ? "매크로 삭제" : "단축키 삭제"))") }
            }
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    if rule.templateID == nil && rule.action != .macro {
                        HStack {
                            Text(L10n.text("동작")).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                            Picker(L10n.text("동작"), selection: $rule.action) {
                                ForEach(AppAction.allCases.filter { $0 != .macro }) { Text(L10n.text($0.title)).tag($0) }
                            }.labelsHidden().frame(maxWidth: 360, alignment: .leading)
                            Spacer(minLength: 0)
                        }
                    }
                    if rule.action == .toggleApplication {
                        ApplicationTargetPicker(target: $rule.targetApplication)
                    }
                    HStack(spacing: 5) {
                        Text(L10n.text(rule.action == .macro ? "실행 키" : "키 조합")).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        ForEach(ShortcutModifier.allCases) { modifier in
                            ModifierButton(modifier: modifier, isSelected: rule.modifiers.contains(modifier)) {
                                if rule.modifiers.contains(modifier) {
                                    if rule.modifiers.count > 1 { rule.modifiers.remove(modifier) }
                                } else { rule.modifiers.insert(modifier) }
                            }
                        }
                        Picker(L10n.text("키"), selection: $rule.key) {
                            ForEach(ShortcutKey.allCases) { Text(L10n.text($0.title)).tag($0) }
                        }.labelsHidden().frame(width: 100)
                        Spacer(minLength: 0)
                    }
                }
                if rule.action == .windowCenterHeight {
                    HStack {
                        Text(L10n.text("화면 높이"))
                        Slider(value: Binding(get: { rule.windowHeightPercent ?? 95 }, set: { rule.windowHeightPercent = $0 }), in: 30...100, step: 1)
                        Text(L10n.text("\(Int(rule.windowHeightPercent ?? 95))%"))
                            .monospacedDigit().frame(width: 45, alignment: .trailing)
                    }
                    HStack {
                        Text(L10n.text("화면 너비"))
                        Toggle(L10n.text("기존 너비 유지"), isOn: Binding(get: { rule.windowWidthPercent == nil }, set: { rule.windowWidthPercent = $0 ? nil : 95 }))
                            .toggleStyle(.checkbox)
                        Slider(value: Binding(get: { rule.windowWidthPercent ?? 95 }, set: { rule.windowWidthPercent = $0 }), in: 30...100, step: 1)
                            .disabled(rule.windowWidthPercent == nil)
                        Text(L10n.text(rule.windowWidthPercent.map { "\(Int($0))%" } ?? "유지")).monospacedDigit().frame(width: 45, alignment: .trailing)
                        HelpButton(title: "창 크기", text: "비율은 메뉴 막대와 Dock을 제외한 영역을 기준으로 합니다. 앱의 최소 창 크기에 따라 지정한 비율보다 커질 수 있습니다.")
                    }
                }
                if rule.action == .macro {
                    MacroEditor(macro: Binding(get: { rule.macro ?? KeyMacro() }, set: { rule.macro = $0 }))
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
    }
}

struct ModifierButton: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    let modifier: ShortcutModifier
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        let _ = uiLanguage
        Button(action: action) {
            Text(L10n.text(modifier.title)).font(.system(size: 15, weight: .regular)).frame(width: 27, height: 24)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(isSelected ? .white : .primary).clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(L10n.text(modifier.rawValue)).accessibilityLabel(L10n.text(modifier.rawValue))
            .accessibilityValue(L10n.text(isSelected ? "선택됨" : "선택 안 됨"))
    }
}
