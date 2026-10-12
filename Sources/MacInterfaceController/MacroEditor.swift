import SwiftUI

struct MacroEditor: View {
    @AppStorage(AppLanguage.defaultsKey) private var uiLanguage = AppLanguage.korean.rawValue
    @Binding var macro: KeyMacro

    var body: some View {
        let _ = uiLanguage
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("이름")).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                TextField(L10n.text("매크로 이름"), text: Binding(get: { macro.name ?? "" }, set: { macro.name = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            Text(L10n.text("입력 순서")).font(.body)
            ForEach(Array(macro.steps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(L10n.text("\(index + 1)")).monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                        Picker(L10n.text("종류"), selection: $macro.steps[index].kind) {
                            Text(L10n.text("키 입력")).tag(MacroStep.Kind.key)
                            Text(L10n.text("대기")).tag(MacroStep.Kind.wait)
                        }.labelsHidden().frame(width: 112)
                        if step.kind == .key {
                            ForEach(ShortcutModifier.allCases) { modifier in
                                ModifierButton(modifier: modifier, isSelected: step.modifiers.contains(modifier)) {
                                    if macro.steps[index].modifiers.contains(modifier) { macro.steps[index].modifiers.remove(modifier) }
                                    else { macro.steps[index].modifiers.insert(modifier) }
                                }
                            }
                            Picker(L10n.text("입력할 키"), selection: $macro.steps[index].key) {
                                ForEach(ShortcutKey.allCases) { Text(L10n.text($0.title)).tag($0) }
                            }.labelsHidden().frame(width: 100)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        Text(L10n.text(step.kind == .key ? "입력 후 대기" : "대기 시간")).font(.caption).foregroundStyle(.secondary)
                        TextField(L10n.text("대기 시간"), value: $macro.steps[index].milliseconds, format: .number)
                            .frame(width: 65).textFieldStyle(.roundedBorder)
                        Text(L10n.text("ms")).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { macro.steps.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help(L10n.text("위로 이동")).accessibilityLabel(L10n.text("위로 이동"))
                        Button { macro.steps.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == macro.steps.count - 1).help(L10n.text("아래로 이동")).accessibilityLabel(L10n.text("아래로 이동"))
                        Button { macro.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "trash") }
                            .help(L10n.text("단계 삭제")).accessibilityLabel(L10n.text("단계 삭제"))
                    }
                }
                .padding(10)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button(L10n.text("키 입력 추가")) { macro.steps.append(MacroStep()) }.disabled(macro.steps.count >= 100)
                Button(L10n.text("대기 추가")) { macro.steps.append(MacroStep(kind: .wait, milliseconds: 300)) }.disabled(macro.steps.count >= 100)
                Spacer()
            }
            HelpButton(title: "매크로 실행", text: "복사·붙여넣기는 Control·Command 교환 여부와 관계없이 ⌘C·⌘V로 지정하세요. 실행 중 Esc를 누르거나 다른 앱으로 이동하면 중지합니다.")
            if let error = macro.validationError {
                Text(L10n.text(error)).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

}
