import Foundation

public enum ArgumentError: LocalizedError, Equatable {
    case missingRequired([String])
    case invalidValue(argument: String, reason: String)
    case unknown([String])

    public var errorDescription: String? {
        switch self {
        case .missingRequired(let names):
            return "必須の引数が未入力です: \(names.joined(separator: ", "))"
        case .invalidValue(let argument, let reason):
            return "引数 '\(argument)' が不正です: \(reason)"
        case .unknown(let names):
            return "未定義の引数です: \(names.joined(separator: ", "))"
        }
    }
}

/// ユーザー入力・既定値・Clipboard から引数の最終値を決め、型を検証する。
public struct ArgumentResolver: Sendable {
    private let clipboard: ClipboardAccess

    public init(clipboard: ClipboardAccess = SystemClipboard()) {
        self.clipboard = clipboard
    }

    /// 入力フォームの初期値。default → clipboard の順で埋める。
    public func initialValues(for recipe: Recipe) -> [String: String] {
        var values: [String: String] = [:]
        let needsClipboard = recipe.arguments.contains(where: \.useClipboardAsDefault)
        let clipboardValue = needsClipboard
            ? clipboard.read().trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        for argument in recipe.arguments {
            if let d = argument.defaultValue, !d.isEmpty {
                values[argument.name] = d
            }
            if argument.useClipboardAsDefault {
                if !clipboardValue.isEmpty { values[argument.name] = clipboardValue }
            }
        }
        return values
    }

    public func resolve(recipe: Recipe, userValues: [String: String]) throws -> [String: String] {
        let declared = Set(recipe.arguments.map(\.name))
        let unknown = userValues.keys.filter { !declared.contains($0) }
        if !unknown.isEmpty { throw ArgumentError.unknown(unknown.sorted()) }

        var values: [String: String] = [:]
        var missing: [String] = []
        let needsClipboard = recipe.arguments.contains { argument in
            argument.useClipboardAsDefault && (userValues[argument.name] ?? argument.defaultValue ?? "").isEmpty
        }
        let clipboardValue = needsClipboard
            ? clipboard.read().trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        for argument in recipe.arguments {
            var value = userValues[argument.name] ?? argument.defaultValue ?? ""
            if value.isEmpty, argument.useClipboardAsDefault {
                value = clipboardValue
            }
            if value.isEmpty {
                if argument.required { missing.append(argument.name) }
                values[argument.name] = ""
                continue
            }
            try validate(value: value, against: argument)
            values[argument.name] = value
        }

        if !missing.isEmpty { throw ArgumentError.missingRequired(missing) }
        return values
    }

    private func validate(value: String, against argument: ArgumentSpec) throws {
        switch argument.type {
        case .url:
            guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
                throw ArgumentError.invalidValue(argument: argument.name, reason: "URL として解釈できません")
            }
        case .choice:
            let options = argument.normalizedOptions
            // 選択肢を決めていない Recipe では、値をそのまま通す。
            guard !options.isEmpty else { break }
            guard options.contains(value) else {
                throw ArgumentError.invalidValue(
                    argument: argument.name,
                    reason: "選択肢にありません (\(options.joined(separator: " / ")))"
                )
            }
        case .string, .multiline:
            break
        }
    }
}
