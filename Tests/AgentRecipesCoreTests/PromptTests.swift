import XCTest
@testable import AgentRecipesCore

final class FakeClipboard: ClipboardAccess, @unchecked Sendable {
    var contents: String
    private(set) var readCount = 0
    init(_ contents: String = "") { self.contents = contents }
    func read() -> String {
        readCount += 1
        return contents
    }
    func write(_ string: String) { contents = string }
}

final class TemplateRendererTests: XCTestCase {
    func testPlaceholdersAreExtractedInOrderWithoutDuplicates() {
        let template = "{{url}} を調べて {{focus}} と {{url}} をまとめる"
        XCTAssertEqual(TemplateRenderer.placeholders(in: template), ["url", "focus"])
    }

    func testNonVariableBracesAreLeftAlone() {
        let template = "{{ 1 + 2 }} と {{}} と {{a b}} はそのまま"
        XCTAssertTrue(TemplateRenderer.placeholders(in: template).isEmpty)
        XCTAssertEqual(TemplateRenderer.render(template, values: [:]), template)
    }

    func testRenderingInsertsValuesAndBlanksMissingOnes() {
        XCTAssertEqual(
            TemplateRenderer.render("{{a}}/{{b}}", values: ["a": "1"]),
            "1/"
        )
        XCTAssertEqual(TemplateRenderer.missingVariables(in: "{{a}}/{{b}}", values: ["a": "1"]), ["b"])
    }

    func testWhitespaceInsidePlaceholderIsTrimmed() {
        XCTAssertEqual(TemplateRenderer.render("{{ url }}", values: ["url": "x"]), "x")
    }
}

final class PromptBuilderTests: XCTestCase {
    private func webResearch() -> Recipe {
        Recipe(
            id: "web-research",
            name: "Webページ調査",
            arguments: [
                ArgumentSpec(name: "url", type: .url, required: true),
                ArgumentSpec(name: "focus", type: .string, required: false, defaultValue: "全体像"),
            ],
            body: "{{url}} を調査してください。\n{{focus}}"
        )
    }

    func testBuildsPromptFromArgumentsAndDefaults() throws {
        let prompt = try PromptBuilder(clipboard: FakeClipboard())
            .build(recipe: webResearch(), userValues: ["url": "https://example.com"], project: nil)
        XCTAssertEqual(prompt, "https://example.com を調査してください。\n全体像")
    }

    func testMissingRequiredArgumentThrows() {
        XCTAssertThrowsError(
            try PromptBuilder(clipboard: FakeClipboard()).build(recipe: webResearch(), userValues: [:], project: nil)
        ) { error in
            XCTAssertEqual(error as? ArgumentError, .missingRequired(["url"]))
        }
    }

    func testInvalidURLIsRejected() {
        XCTAssertThrowsError(
            try PromptBuilder(clipboard: FakeClipboard())
                .build(recipe: webResearch(), userValues: ["url": "not a url"], project: nil)
        ) { error in
            guard case .invalidValue(let name, _)? = error as? ArgumentError else {
                return XCTFail("想定外のエラー: \(error)")
            }
            XCTAssertEqual(name, "url")
        }
    }

    func testUnknownArgumentIsRejected() {
        XCTAssertThrowsError(
            try PromptBuilder(clipboard: FakeClipboard())
                .build(recipe: webResearch(), userValues: ["url": "https://a.example", "nope": "x"], project: nil)
        ) { error in
            XCTAssertEqual(error as? ArgumentError, .unknown(["nope"]))
        }
    }

    func testClipboardFillsArgumentDefault() throws {
        var recipe = webResearch()
        recipe.arguments[0].useClipboardAsDefault = true
        let prompt = try PromptBuilder(clipboard: FakeClipboard("https://clip.example"))
            .build(recipe: recipe, userValues: [:], project: nil)
        XCTAssertTrue(prompt.hasPrefix("https://clip.example"))
    }

    func testClipboardVariableNeedsNoUserInput() throws {
        let recipe = Recipe(id: "review-clipboard", name: "Clipboardをレビュー", body: "以下:\n{{clipboard}}")
        XCTAssertFalse(recipe.needsUserInput)
        let prompt = try PromptBuilder(clipboard: FakeClipboard("let x = 1"))
            .build(recipe: recipe, userValues: [:], project: nil)
        XCTAssertEqual(prompt, "以下:\nlet x = 1")
    }

    func testClipboardIsNotReadWhenRecipeDoesNotUseIt() throws {
        let clipboard = FakeClipboard("private clipboard")
        let recipe = Recipe(id: "plain", name: "Plain", body: "{{date}} only")
        _ = try PromptBuilder(clipboard: clipboard).build(recipe: recipe, userValues: [:], project: nil)
        XCTAssertEqual(clipboard.readCount, 0)
    }

    func testClipboardIsReadOnceForMultipleClipboardDefaults() {
        let clipboard = FakeClipboard("shared")
        let recipe = Recipe(
            id: "clip", name: "Clipboard",
            arguments: [
                ArgumentSpec(name: "first", useClipboardAsDefault: true),
                ArgumentSpec(name: "second", useClipboardAsDefault: true),
            ],
            body: "{{first}} {{second}}"
        )
        XCTAssertEqual(PromptBuilder(clipboard: clipboard).initialValues(for: recipe), ["first": "shared", "second": "shared"])
        XCTAssertEqual(clipboard.readCount, 1)
    }

    func testProjectVariables() throws {
        let project = Project(name: "music-db", path: "~/src/music-db")
        let recipe = Recipe(id: "p", name: "P", body: "{{project}} @ {{cwd}}")
        let prompt = try PromptBuilder(clipboard: FakeClipboard())
            .build(recipe: recipe, userValues: [:], project: project)
        XCTAssertEqual(prompt, "music-db @ \(("~/src/music-db" as NSString).expandingTildeInPath)")
    }

    func testSkillAndRichResultFormatAreAddedToPrompt() throws {
        let recipe = Recipe(
            id: "rich", name: "Rich",
            skill: SkillReference(name: "structured-output", source: "codex"),
            resultFormat: .rich,
            body: "調査してください"
        )
        let prompt = try PromptBuilder(clipboard: FakeClipboard())
            .build(recipe: recipe, userValues: [:], project: nil)

        XCTAssertTrue(prompt.hasPrefix("この作業では `structured-output` スキルを使用"))
        XCTAssertTrue(prompt.contains("調査してください"))
        XCTAssertTrue(prompt.hasSuffix(RichResultDocument.promptInstruction))
    }

    func testPlainResultFormatDoesNotAddOutputContract() throws {
        let recipe = Recipe(id: "plain", name: "Plain", body: "hello")
        let prompt = try PromptBuilder(clipboard: FakeClipboard())
            .build(recipe: recipe, userValues: [:], project: nil)
        XCTAssertEqual(prompt, "hello")
    }

    func testAdditionalPromptIsIncludedOnlyWhenRecipeAcceptsIt() throws {
        let enabled = Recipe(
            id: "enabled", name: "Enabled", acceptsAdditionalPrompt: true, body: "基本の指示"
        )
        let disabled = Recipe(id: "disabled", name: "Disabled", body: "基本の指示")
        let builder = PromptBuilder(clipboard: FakeClipboard())

        XCTAssertEqual(
            try builder.build(recipe: enabled, userValues: [:], project: nil, additionalPrompt: "優先度を高く"),
            "基本の指示\n\n追加の指示:\n優先度を高く"
        )
        XCTAssertEqual(
            try builder.build(recipe: disabled, userValues: [:], project: nil, additionalPrompt: "混入してはいけない"),
            "基本の指示"
        )
    }

    func testBuiltinVariableSetIsTheMVPFive() {
        XCTAssertEqual(Set(VariableResolver.builtinNames), ["clipboard", "date", "time", "project", "cwd"])
    }

    func testPreviewToleratesMissingValues() {
        let preview = PromptBuilder(clipboard: FakeClipboard())
            .preview(recipe: webResearch(), userValues: [:], project: nil)
        XCTAssertEqual(preview, " を調査してください。\n")
    }

    func testEmptyTemplateThrows() {
        XCTAssertThrowsError(
            try PromptBuilder(clipboard: FakeClipboard())
                .build(recipe: Recipe(id: "empty", name: "Empty"), userValues: [:], project: nil)
        ) { error in
            XCTAssertEqual(error as? PromptError, .emptyTemplate)
        }
    }

    func testUndeclaredVariablesAreReported() {
        let recipe = Recipe(id: "x", name: "X", body: "{{url}} {{clipboard}} {{nope}}")
        XCTAssertEqual(PromptBuilder.undeclaredVariables(in: recipe), ["url", "nope"])
    }

    func testNeedsUserInputReflectsRuntimeChoices() {
        var recipe = Recipe(id: "x", name: "X", body: "hello")
        XCTAssertFalse(recipe.needsUserInput)
        recipe.target.askProject = true
        XCTAssertTrue(recipe.needsUserInput)

        // 送信先は実行時に聞かない。workspace 指定だけではフォームを開かない。
        recipe.target.askProject = false
        recipe.target.workspaceName = "AgentRecipes"
        XCTAssertFalse(recipe.needsUserInput)
    }

    /// 選択式の引数は、選択肢にある値だけを通す。
    func testChoiceArgumentAcceptsOnlyItsOptions() throws {
        let recipe = Recipe(
            id: "c", name: "C",
            arguments: [ArgumentSpec(
                name: "focus", type: .choice, required: true,
                options: ["全体像", "API", "セキュリティ"], choiceStyle: .buttons
            )],
            body: "{{focus}} を見てください"
        )
        let builder = PromptBuilder(clipboard: FakeClipboard())
        XCTAssertEqual(
            try builder.build(recipe: recipe, userValues: ["focus": "API"], project: nil),
            "API を見てください"
        )
        XCTAssertThrowsError(
            try builder.build(recipe: recipe, userValues: ["focus": "その他"], project: Project?.none)
        ) { error in
            guard case .invalidValue(let name, _)? = error as? ArgumentError else {
                return XCTFail("invalidValue のはず: \(error)")
            }
            XCTAssertEqual(name, "focus")
        }
    }

    /// 既定値があれば選ばずに実行できる。
    func testChoiceArgumentUsesDefaultValue() throws {
        let recipe = Recipe(
            id: "c", name: "C",
            arguments: [ArgumentSpec(
                name: "focus", type: .choice, required: true,
                defaultValue: "全体像", options: ["全体像", "API"]
            )],
            body: "{{focus}}"
        )
        let builder = PromptBuilder(clipboard: FakeClipboard())
        XCTAssertEqual(try builder.build(recipe: recipe, userValues: [:], project: nil), "全体像")
    }

    /// 空白や重複を除いた選択肢を使う。
    func testNormalizedOptionsDropsBlanksAndDuplicates() {
        let argument = ArgumentSpec(
            name: "x", type: .choice, options: [" A ", "A", "", "B"]
        )
        XCTAssertEqual(argument.normalizedOptions, ["A", "B"])
    }

    func testSearchMatchesNameTagsAndAgent() {
        var recipe = webResearch()
        recipe.tags = ["research", "json"]
        recipe.category = "Research"
        XCTAssertTrue(recipe.matches("web"))
        XCTAssertTrue(recipe.matches("research json"))
        XCTAssertFalse(recipe.matches("music"))
    }

    func testArgumentTypesAreTextAndChoice() {
        XCTAssertEqual(ArgumentType.allCases.map(\.rawValue), ["string", "multiline", "url", "choice"])
    }

    func testModesAreCopyPasteSubmit() {
        XCTAssertEqual(ExecutionMode.allCases.map(\.rawValue), ["copy", "paste", "submit"])
        XCTAssertFalse(ExecutionMode.copy.requiresHerdr)
        XCTAssertTrue(ExecutionMode.paste.requiresHerdr)
        XCTAssertTrue(ExecutionMode.submit.requiresHerdr)
    }

    func testResultFormatsArePlainAndRich() {
        XCTAssertEqual(ResultFormat.allCases, [.plain, .rich])
    }
}
