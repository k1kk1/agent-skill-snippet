import SwiftUI
import AgentRecipesCore

/// 一覧の行に出す記号のもと。
///
/// 記号とその状態は、この 1 か所だけで決める。
/// メニューのバッジと、Recipe 編集画面の凡例が同じ計算を使うことで、
/// 「この記号はどの設定のことか」がずれないようにする。
struct RecipeBadges {
    enum State: Equatable {
        /// 今回使う。
        case active
        /// 使えるが、今回は使わない。
        case inactive
        /// この Recipe には関係がない。
        case hidden
    }

    /// 記号のまとまり。
    enum Group: Int, CaseIterable {
        /// 何を渡すか (引数の形式)。
        case format
        /// どう入れるか (入力方法)。
        case input

        var title: String {
            switch self {
            case .format: return "何を渡すか"
            case .input: return "どう入れるか"
            }
        }
    }

    struct Item: Identifiable {
        var id: String
        var symbol: String
        /// 記号が示すもの。
        var title: String
        var state: State
        /// どの設定でそうなっているか。凡例に出す。
        var detail: String
        var group: Group
    }

    let recipe: Recipe

    private var argumentTypes: [ArgumentType] {
        Array(Set(recipe.arguments.map(\.type)))
    }

    private func arguments(ofType type: ArgumentType) -> [ArgumentSpec] {
        recipe.arguments.filter { $0.type == type }
    }

    /// 引数の既定値に Clipboard を使うか、Prompt に {clipboard} があるか。
    private var clipboardArguments: [ArgumentSpec] {
        recipe.arguments.filter(\.useClipboardAsDefault)
    }

    private var templateUsesClipboard: Bool {
        TemplateRenderer.placeholders(in: recipe.template).contains("clipboard")
    }

    var usesClipboard: Bool { !clipboardArguments.isEmpty || templateUsesClipboard }

    var items: [Item] {
        [
            formatItem(.string),
            formatItem(.multiline),
            formatItem(.url),
            formatItem(.choice),
            clipboardItem,
        ]
    }

    func items(in group: Group) -> [Item] {
        items.filter { $0.group == group }
    }

    /// 記号 1 つ分の状態。編集画面の設定の隣に、同じ状態で出すために使う。
    func state(of id: String) -> State {
        items.first { $0.id == id }?.state ?? .hidden
    }

    private func formatItem(_ type: ArgumentType) -> Item {
        // Clipboard から入る引数は Clipboard の記号だけを点ける。
        // 「打ち込む形式」と「Clipboard から入れる」は排他にしないと、
        // どちらの話なのか読み取れない。
        let matching = arguments(ofType: type).filter { !$0.useClipboardAsDefault }
        let fromClipboard = arguments(ofType: type).filter(\.useClipboardAsDefault)
        return Item(
            id: type.rawValue,
            symbol: type.symbolName,
            title: title(for: type),
            state: matching.isEmpty ? .hidden : .active,
            detail: matching.isEmpty
                ? (fromClipboard.isEmpty
                    ? "この形式の引数はない"
                    : "この形式の引数は Clipboard から入れる")
                : "「引数」の " + matching.map(\.name).joined(separator: ", "),
            group: .format
        )
    }

    private func title(for type: ArgumentType) -> String {
        switch type {
        case .string: return "文字列の引数"
        case .multiline: return "複数行の引数"
        case .url: return "URL の引数"
        case .choice: return "選択式の引数"
        }
    }

    private var clipboardItem: Item {
        let detail: String
        if !clipboardArguments.isEmpty {
            detail = "「引数」の " + clipboardArguments.map(\.name).joined(separator: ", ")
                + " が Clipboard を既定値にしている"
        } else if templateUsesClipboard {
            detail = "「Prompt」に {clipboard} がある"
        } else {
            detail = "Clipboard は使わない"
        }
        return Item(
            id: "clipboard",
            symbol: "doc.on.clipboard",
            title: "Clipboard から入れる",
            state: usesClipboard ? .active : .hidden,
            detail: detail,
            group: .input
        )
    }

}

/// Recipe が必要とする入力と、その取得元をコンパクトに示す共通表示。
///
/// メニューバーでは種類ごとに常に同じ位置を使う。空のスロットも確保することで、
/// Recipe ごとに後続の記号が横に動かない。
/// 等間隔に並べるとどれが何の話か読み取れないので、まとまりの間を空ける。
struct RecipeInputBadges: View {
    let recipe: Recipe

    private var badges: RecipeBadges { RecipeBadges(recipe: recipe) }

    /// 同じまとまりの記号どうしの間隔。
    static let slotSpacing: CGFloat = 5
    /// 別のまとまりに移るときの間隔。
    static let groupSpacing: CGFloat = 12

    var body: some View {
        HStack(spacing: Self.groupSpacing) {
            ForEach(RecipeBadges.Group.allCases, id: \.self) { group in
                HStack(spacing: Self.slotSpacing) {
                    ForEach(badges.items(in: group)) { item in
                        RecipeBadgeIcon(item: item, size: 13)
                            .frame(width: 15, height: 17)
                            // 何の話か・なぜそうなっているかは、説明を並べずに
                            // ツールチップで読めるようにする。
                            .help("\(item.title)\n\(item.detail)")
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        parts.append(recipe.arguments.isEmpty ? "入力なし" : "引数 \(recipe.arguments.count) 件")
        let active = badges.items(in: .format).filter { $0.state == .active }
        if !active.isEmpty { parts.append("形式: " + active.map(\.title).joined(separator: "、")) }
        if badges.usesClipboard { parts.append("Clipboard を使用") }
        return parts.joined(separator: "。")
    }
}

/// 記号 1 つ。色は 3 段階だけにして、行が騒がしくならないようにする。
/// 使う = オレンジ / 使えるが今回は使わない = 白 / 対象外 = グレー。
struct RecipeBadgeIcon: View {
    let item: RecipeBadges.Item
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: item.symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Self.color(for: item.state))
    }

    static func color(for state: RecipeBadges.State) -> Color {
        switch state {
        case .active: return .orange
        case .inactive: return .primary
        case .hidden: return Color.secondary.opacity(0.35)
        }
    }
}

/// 設定と一覧の記号を結びつけるための印。
/// 編集画面の各設定の隣に、同じ記号・同じ 3 色で出す。
struct BadgeStateIcon: View {
    let symbol: String
    let state: RecipeBadges.State
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(RecipeBadgeIcon.color(for: state))
            .frame(width: 15)
    }
}
