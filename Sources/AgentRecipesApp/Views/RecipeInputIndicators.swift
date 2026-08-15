import SwiftUI
import AgentRecipesCore

/// Recipe が必要とする入力と、その取得元をコンパクトに示す共通表示。
struct RecipeInputBadges: View {
    let recipe: Recipe
    var compact: Bool = false

    private var argumentTypes: [ArgumentType] {
        Array(Set(recipe.arguments.map(\.type))).sorted { $0.rawValue < $1.rawValue }
    }

    private var usesClipboard: Bool {
        recipe.arguments.contains(where: \.useClipboardAsDefault)
            || TemplateRenderer.placeholders(in: recipe.template).contains("clipboard")
    }

    /// ⌥クリックでフォームを開き、既定値や Clipboard の値を上書きできるか。
    private var canOpenForm: Bool {
        !recipe.arguments.isEmpty
            || recipe.acceptsAdditionalPrompt
            || recipe.target.askProject
    }

    private enum CompactState: Equatable {
        case active
        case inactive
        case hidden
    }

    var body: some View {
        Group {
            if compact {
                compactBadges
            } else {
                HStack(spacing: 4) {
                    if recipe.arguments.isEmpty {
                        badge("入力なし", symbol: "checkmark.circle", tint: .secondary)
                    } else {
                        ForEach(argumentTypes, id: \.self) { type in
                            badge(type.displayName, symbol: type.symbolName, tint: .blue)
                        }
                        badge("引数 \(recipe.arguments.count)", symbol: "slider.horizontal.3", tint: .secondary)
                    }
                    if usesClipboard {
                        badge("Clipboard", symbol: "doc.on.clipboard", tint: .purple)
                    }
                    if recipe.needsUserInput {
                        badge("フォーム", symbol: "rectangle.and.pencil.and.ellipsis", tint: .orange)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// メニューバーでは種類ごとに常に同じ位置を使う。
    /// 空のスロットも確保することで、Recipe ごとに後続の記号が横に動かない。
    private var compactBadges: some View {
        HStack(spacing: 6) {
            compactSlot(
                ArgumentType.string.symbolName,
                label: ArgumentType.string.displayName,
                tint: .blue,
                state: argumentTypes.contains(.string)
                    ? .active
                    : (recipe.acceptsAdditionalPrompt ? .inactive : .hidden)
            )
            compactSlot(
                ArgumentType.multiline.symbolName,
                label: ArgumentType.multiline.displayName,
                tint: .blue,
                state: argumentTypes.contains(.multiline) ? .active : .hidden
            )
            compactSlot(
                ArgumentType.url.symbolName,
                label: ArgumentType.url.displayName,
                tint: .blue,
                state: argumentTypes.contains(.url) ? .active : .hidden
            )
            compactSlot(
                "doc.on.clipboard",
                label: "Clipboard",
                tint: .purple,
                state: usesClipboard ? .active : .hidden
            )
            compactSlot(
                "rectangle.and.pencil.and.ellipsis",
                label: recipe.needsUserInput
                    ? "フォーム入力が必要"
                    : (canOpenForm ? "フォームで上書き可能（⌥クリック）" : "フォーム入力なし"),
                tint: .orange,
                state: recipe.needsUserInput ? .active : (canOpenForm ? .inactive : .hidden)
            )
        }
    }

    private func compactSlot(_ symbol: String, label: String, tint: Color, state: CompactState) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foregroundColor(for: state, activeTint: tint))
            .frame(width: 11, height: 14)
            .opacity(state == .active ? 1 : (state == .inactive ? 0.85 : 0.35))
            .help(label)
            .accessibilityHidden(true)
    }

    private func foregroundColor(for state: CompactState, activeTint: Color) -> Color {
        switch state {
        case .active: return activeTint
        case .inactive: return .primary
        case .hidden: return .secondary
        }
    }

    @ViewBuilder
    private func badge(_ text: String, symbol: String, tint: Color) -> some View {
        Group {
            if compact {
                Label(text, systemImage: symbol).labelStyle(.iconOnly)
            } else {
                Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
            }
        }
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 1 : 5)
            .padding(.vertical, compact ? 1 : 3)
            .background(tint.opacity(compact ? 0 : 0.12), in: Capsule())
            .help(text)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        parts.append(recipe.arguments.isEmpty ? "入力なし" : "引数 \(recipe.arguments.count) 件")
        if !argumentTypes.isEmpty { parts.append("形式: " + argumentTypes.map(\.displayName).joined(separator: "、")) }
        if usesClipboard { parts.append("Clipboard を使用") }
        if recipe.needsUserInput { parts.append("フォーム入力あり") }
        if recipe.acceptsAdditionalPrompt { parts.append("補足プロンプトを受け付ける") }
        return parts.joined(separator: "。")
    }
}
