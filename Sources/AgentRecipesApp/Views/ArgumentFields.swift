import SwiftUI
import AgentRecipesCore

struct ArgumentField: View {
    let argument: ArgumentSpec
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(argument.displayLabel).font(.caption).bold()
                if argument.required {
                    Text("*").font(.caption).foregroundStyle(.red)
                }
                Label(argument.type.displayName, systemImage: argument.type.symbolName)
                    .font(.caption2).foregroundStyle(.tertiary)
                if argument.useClipboardAsDefault {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                        .font(.caption2).foregroundStyle(.purple)
                }
            }

            switch argument.type {
            case .multiline:
                TextEditor(text: $value)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            case .choice:
                ChoiceField(argument: argument, value: $value)
            case .string, .url:
                TextField(argument.displayLabel, text: $value)
            }
        }
    }
}

/// 選択式の入力。プルダウンか、並べたボタンで値を選ぶ。
/// 複数選択のときは、選んだ順ではなく選択肢の並び順で連結する。
struct ChoiceField: View {
    let argument: ArgumentSpec
    @Binding var value: String

    private var options: [String] { argument.normalizedOptions }

    private var selected: Set<String> {
        Set(argument.allowsMultiple ? ArgumentSpec.selectedValues(value) : (value.isEmpty ? [] : [value]))
    }

    var body: some View {
        if options.isEmpty {
            Text("選択肢が設定されていません")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if argument.choiceStyle == .buttons {
            buttons
        } else if argument.allowsMultiple {
            multiMenu
        } else {
            singleMenu
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    toggle(option)
                } label: {
                    HStack(spacing: 4) {
                        if argument.allowsMultiple {
                            Image(systemName: selected.contains(option) ? "checkmark.square.fill" : "square")
                                .font(.caption2)
                        }
                        Text(option).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(selected.contains(option) ? .accentColor : .secondary)
            }
        }
    }

    /// 複数選択のプルダウン。開いたまま複数チェックできる。
    private var multiMenu: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { selected.contains(option) },
                    set: { _ in toggle(option) }
                ))
            }
        } label: {
            Text(value.isEmpty ? "未選択" : value)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }

    private var singleMenu: some View {
        Picker("", selection: $value) {
            if !options.contains(value) {
                Text(value.isEmpty ? "未選択" : value).tag(value)
            }
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .labelsHidden()
    }

    private func toggle(_ option: String) {
        guard argument.allowsMultiple else {
            value = option
            return
        }
        var next = selected
        if next.contains(option) { next.remove(option) } else { next.insert(option) }
        value = argument.joined(Array(next))
    }
}
