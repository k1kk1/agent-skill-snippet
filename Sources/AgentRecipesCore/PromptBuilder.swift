import Foundation

public enum PromptError: LocalizedError, Equatable {
    case emptyTemplate

    public var errorDescription: String? {
        switch self {
        case .emptyTemplate: return "Prompt が空です"
        }
    }
}

/// Argument Resolver → Variable Resolver → Template Renderer をつなぐ薄い層。
/// GUI / CLI はこれ 1 つで Prompt を作る。
public struct PromptBuilder: Sendable {
    private let arguments: ArgumentResolver
    private let variables: VariableResolver

    public init(
        clipboard: ClipboardAccess = SystemClipboard(),
        variables: VariableResolver? = nil
    ) {
        self.arguments = ArgumentResolver(clipboard: clipboard)
        self.variables = variables ?? VariableResolver(clipboard: clipboard)
    }

    public func initialValues(for recipe: Recipe) -> [String: String] {
        arguments.initialValues(for: recipe)
    }

    /// 実行用。引数が足りなければ throw する。
    public func build(recipe: Recipe, userValues: [String: String], project: Project?) throws -> String {
        let template = recipe.template
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptError.emptyTemplate
        }
        var values = try arguments.resolve(recipe: recipe, userValues: userValues)
        for (key, value) in variables.values(project: project) where values[key] == nil {
            values[key] = value
        }
        return decorate(TemplateRenderer.render(template, values: values), for: recipe)
    }

    /// Preview 用。未入力の引数は空のままレンダリングする。
    public func preview(recipe: Recipe, userValues: [String: String], project: Project?) -> String {
        var values = userValues
        for (key, value) in variables.values(project: project) where values[key] == nil {
            values[key] = value
        }
        return decorate(TemplateRenderer.render(recipe.template, values: values), for: recipe)
    }

    /// Recipe が使っているが、引数にも Built-in にも無い変数。Editor の警告用。
    public static func undeclaredVariables(in recipe: Recipe) -> [String] {
        TemplateRenderer.placeholders(in: recipe.template).filter { name in
            !VariableResolver.builtinNames.contains(name)
                && !recipe.arguments.contains { $0.name == name }
        }
    }

    private func decorate(_ rendered: String, for recipe: Recipe) -> String {
        var sections: [String] = []
        if let skill = recipe.skill {
            sections.append("この作業では `\(skill.name)` スキルを使用し、その SKILL.md の指示に従ってください。")
        }
        sections.append(rendered)
        if recipe.resultFormat == .rich {
            sections.append(RichResultDocument.promptInstruction)
        }
        return sections.joined(separator: "\n\n")
    }
}
