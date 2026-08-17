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
        defaultWorkingDirectory: String? = nil,
        variables: VariableResolver? = nil
    ) {
        self.arguments = ArgumentResolver(clipboard: clipboard)
        self.variables = variables ?? VariableResolver(
            clipboard: clipboard,
            defaultWorkingDirectory: defaultWorkingDirectory
        )
    }

    public func initialValues(for recipe: Recipe) -> [String: String] {
        arguments.initialValues(for: recipe)
    }

    /// 実行用。引数が足りなければ throw する。
    public func build(
        recipe: Recipe,
        userValues: [String: String],
        project: Project?,
        additionalPrompt: String = ""
    ) throws -> String {
        let template = recipe.template
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptError.emptyTemplate
        }
        var values = try arguments.resolve(recipe: recipe, userValues: userValues)
        let needsClipboard = TemplateRenderer.placeholders(in: template).contains("clipboard")
        for (key, value) in variables.values(project: project, includeClipboard: needsClipboard) where values[key] == nil {
            values[key] = value
        }
        return decorate(
            TemplateRenderer.render(template, values: values),
            for: recipe,
            additionalPrompt: additionalPrompt
        )
    }

    /// Preview 用。未入力の引数は空のままレンダリングする。
    public func preview(
        recipe: Recipe,
        userValues: [String: String],
        project: Project?,
        additionalPrompt: String = ""
    ) -> String {
        var values = userValues
        let needsClipboard = TemplateRenderer.placeholders(in: recipe.template).contains("clipboard")
        for (key, value) in variables.values(project: project, includeClipboard: needsClipboard) where values[key] == nil {
            values[key] = value
        }
        return decorate(
            TemplateRenderer.render(recipe.template, values: values),
            for: recipe,
            additionalPrompt: additionalPrompt
        )
    }

    /// Recipe が使っているが、引数にも Built-in にも無い変数。Editor の警告用。
    public static func undeclaredVariables(in recipe: Recipe) -> [String] {
        TemplateRenderer.placeholders(in: recipe.template).filter { name in
            !VariableResolver.builtinNames.contains(name)
                && !recipe.arguments.contains { $0.name == name }
        }
    }

    private func decorate(_ rendered: String, for recipe: Recipe, additionalPrompt: String) -> String {
        var sections: [String] = []
        if let skill = recipe.skill {
            sections.append("この作業では `\(skill.name)` スキルを使用し、その SKILL.md の指示に従ってください。")
        }
        sections.append(rendered)
        let supplemental = additionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if recipe.acceptsAdditionalPrompt, !supplemental.isEmpty {
            sections.append("追加の指示:\n\(supplemental)")
        }
        if recipe.resultFormat == .rich {
            sections.append(RichResultDocument.promptInstruction)
        }
        return sections.joined(separator: "\n\n")
    }
}
