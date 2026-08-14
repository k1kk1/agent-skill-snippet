import Foundation

/// `{{name}}` だけの単純なテンプレート。if / loop / function は入れない。
/// Shell へ渡す経路が無くなったため、レンダリングは Prompt 用の 1 系統のみ。
public enum TemplateRenderer {

    /// テンプレート中に現れる変数名を出現順に返す (重複除去)。
    public static func placeholders(in template: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for name in scan(template).compactMap({ $0.variable }) {
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// 値が無い変数は空文字になる。
    public static func render(_ template: String, values: [String: String]) -> String {
        scan(template).map { token in
            switch token {
            case .text(let t): return t
            case .variable(let v): return values[v] ?? ""
            }
        }.joined()
    }

    public static func missingVariables(in template: String, values: [String: String]) -> [String] {
        placeholders(in: template).filter { values[$0] == nil }
    }

    // MARK: - 内部

    private enum Token {
        case text(String)
        case variable(String)

        var variable: String? {
            if case .variable(let v) = self { return v }
            return nil
        }
    }

    private static func scan(_ template: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        var index = template.startIndex

        while index < template.endIndex {
            if template[index] == "{",
               let open = template.index(index, offsetBy: 1, limitedBy: template.endIndex),
               open < template.endIndex, template[open] == "{",
               let contentStart = template.index(open, offsetBy: 1, limitedBy: template.endIndex),
               let closeRange = template.range(of: "}}", range: contentStart..<template.endIndex) {

                let raw = String(template[contentStart..<closeRange.lowerBound])
                let name = raw.trimmingCharacters(in: .whitespaces)
                if isValidVariableName(name) {
                    if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" }
                    tokens.append(.variable(name))
                    index = closeRange.upperBound
                    continue
                }
            }
            buffer.append(template[index])
            index = template.index(after: index)
        }
        if !buffer.isEmpty { tokens.append(.text(buffer)) }
        return tokens
    }

    /// 英数・アンダースコア・ドットのみを変数とみなす。
    /// Prompt 内の JSON やコード片の `{{ ... }}` を誤って変数扱いしないためのガード。
    private static func isValidVariableName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return false }
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return true
    }
}
