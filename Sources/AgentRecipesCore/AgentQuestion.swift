import Foundation

/// Agent が実行を止めて聞いてきている確認 (許可プロンプトや y/n)。
/// Result ウィンドウからそのまま答えられるように、選択肢と送るキーを持つ。
public struct AgentQuestion: Hashable, Sendable {
    public struct Option: Hashable, Identifiable, Sendable {
        /// ボタンに出す文言。
        public var label: String
        /// `herdr pane send-keys` に渡すキー列。
        public var keys: [String]
        /// 肯定的な選択肢か (ボタンを強調するため)。
        public var isAffirmative: Bool

        public var id: String { label + "|" + keys.joined(separator: " ") }

        public init(label: String, keys: [String], isAffirmative: Bool) {
            self.label = label
            self.keys = keys
            self.isAffirmative = isAffirmative
        }
    }

    /// 質問文。
    public var prompt: String
    public var options: [Option]

    public init(prompt: String, options: [Option]) {
        self.prompt = prompt
        self.options = options
    }
}

/// pane の出力末尾から「Agent が待っている確認」を読み取る。
///
/// 対応する形:
/// - 番号付きの選択 UI (Claude Code の許可プロンプトなど)
///   ```
///   Do you want to allow this?
///   ❯ 1. Yes
///     2. Yes, and don't ask again
///     3. No, and tell Claude what to do differently
///   ```
/// - `(y/n)` / `[Y/n]` のような一行の確認
public enum AgentQuestionParser {
    /// 末尾から見て、この行数までを確認の候補として扱う。
    private static let tailLineLimit = 40

    public static func parse(_ output: String) -> AgentQuestion? {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { sanitize(String($0)) }
        let tail = Array(lines.suffix(tailLineLimit))
        return numberedQuestion(in: tail) ?? yesNoQuestion(in: tail)
    }

    // MARK: - 番号付きの選択 UI

    private static func numberedQuestion(in lines: [String]) -> AgentQuestion? {
        var options: [(index: Int, option: AgentQuestion.Option)] = []
        for (index, line) in lines.enumerated() {
            guard let option = numberedOption(line) else { continue }
            options.append((index, option))
        }
        // 1 件だけだと本文中の箇条書きを拾いやすいので、2 件以上を条件にする。
        guard options.count >= 2 else { return nil }
        // 連続した塊のうち、いちばん最後のものを使う。
        var group: [(index: Int, option: AgentQuestion.Option)] = [options[options.count - 1]]
        for candidate in options.dropLast().reversed() {
            guard let first = group.first, first.index - candidate.index <= 2 else { break }
            group.insert(candidate, at: 0)
        }
        guard group.count >= 2, let firstIndex = group.first?.index else { return nil }

        let prompt = questionText(above: firstIndex, in: lines)
            ?? "Agent が確認を求めています"
        return AgentQuestion(prompt: prompt, options: group.map(\.option))
    }

    /// `❯ 1. Yes` / `  2. No, and tell Claude ...` の 1 行を選択肢にする。
    private static func numberedOption(_ line: String) -> AgentQuestion.Option? {
        var text = line.trimmingCharacters(in: .whitespaces)
        // 選択中を示す記号を落とす。
        for marker in ["❯", ">", "▶", "•"] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let separator = text.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let number = String(text[text.startIndex..<separator])
        guard number.count == 1, let digit = Int(number), (1...9).contains(digit) else { return nil }
        let label = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 120 else { return nil }
        return AgentQuestion.Option(
            label: label,
            keys: [number],
            isAffirmative: isAffirmative(label)
        )
    }

    /// 選択肢の直前にある、質問らしい行を探す。
    private static func questionText(above index: Int, in lines: [String]) -> String? {
        for line in lines[..<index].reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isDecoration(text) else { continue }
            return text
        }
        return nil
    }

    // MARK: - y/n

    private static let yesNoPatterns = ["(y/n)", "[y/n]", "(yes/no)", "[yes/no]", "(y/N)", "[y/N]", "(Y/n)", "[Y/n]"]

    private static func yesNoQuestion(in lines: [String]) -> AgentQuestion? {
        for line in lines.reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()
            guard yesNoPatterns.contains(where: { lower.contains($0.lowercased()) }) else { continue }
            return AgentQuestion(
                prompt: text,
                options: [
                    AgentQuestion.Option(label: "はい (y)", keys: ["y", "enter"], isAffirmative: true),
                    AgentQuestion.Option(label: "いいえ (n)", keys: ["n", "enter"], isAffirmative: false),
                ]
            )
        }
        return nil
    }

    // MARK: - 共通

    private static func isAffirmative(_ label: String) -> Bool {
        let lower = label.lowercased()
        if lower.hasPrefix("no") || lower.hasPrefix("don't") || lower.hasPrefix("cancel") { return false }
        return lower.hasPrefix("yes") || lower.hasPrefix("allow") || lower.hasPrefix("proceed")
            || lower.hasPrefix("continue") || lower.hasPrefix("ok")
    }

    /// 罫線やプロンプト記号だけの行。
    private static func isDecoration(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: "─━-=_│|╭╮╰╯┌┐└┘ >❯"))
        return stripped.isEmpty
    }

    /// ANSI エスケープと制御文字を落とす。
    static func sanitize(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }
}
