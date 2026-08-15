import Foundation

/// 初回起動 / `agentrecipes init` で入れる Recipe。
/// 引数なし / 引数あり / Clipboard 利用 / リッチ結果 のパターン。
public enum SampleRecipes {
    public static var all: [Recipe] {
        [reviewDiff, webResearch, clipboardReview, richResultTest, skillCreator]
    }

    /// 引数なし。選ぶと即送信される。
    public static var reviewDiff: Recipe {
        Recipe(
            id: "review-diff",
            name: "差分をレビュー",
            description: "現在の変更内容をレビューする",
            category: "Development",
            tags: ["review", "git"],
            favorite: true,
            mode: .submit,
            target: TargetSpec(session: .newSession),
            body: """
            現在の変更内容をレビューしてください。
            問題点、改善案、テスト不足を確認してください。
            """
        )
    }

    /// 実行時に値を入力する。URL は Clipboard から拾う。
    public static var webResearch: Recipe {
        Recipe(
            id: "web-research",
            name: "Webページ調査",
            description: "URL を調査してポイントをまとめる",
            category: "Research",
            tags: ["web", "research"],
            favorite: true,
            arguments: [
                ArgumentSpec(name: "url", label: "URL", type: .url, required: true, useClipboardAsDefault: true),
                ArgumentSpec(name: "focus", label: "確認項目", type: .string, required: false, defaultValue: "全体像"),
            ],
            mode: .submit,
            target: TargetSpec(session: .newSession),
            body: """
            web-page-research スキルを使って {{url}} を調査してください。

            特に以下を確認してください。

            {{focus}}
            """
        )
    }

    /// ユーザー入力なしで Clipboard の内容を使う。
    public static var clipboardReview: Recipe {
        Recipe(
            id: "review-clipboard",
            name: "Clipboardをレビュー",
            description: "クリップボードの内容をそのままレビューさせる",
            category: "Utilities",
            tags: ["clipboard"],
            mode: .submit,
            target: TargetSpec(session: .newSession),
            body: """
            以下の内容をレビューしてください。

            {{clipboard}}
            """
        )
    }

    /// 構造化された Markdown / Table / List / JSON を Result ウィンドウで確認する。
    public static var richResultTest: Recipe {
        Recipe(
            id: "rich-result-test",
            name: "リッチ表示テスト",
            description: "Skill の構造化結果を Result ウィンドウで確認する",
            category: "Utilities",
            tags: ["test", "rich-result"],
            skill: SkillReference(name: "agent-recipes-rich-result-test", source: "codex"),
            resultFormat: .rich,
            mode: .submit,
            target: TargetSpec(session: .newSession),
            body: """
            リッチ表示用のテスト結果を返してください。
            """
        )
    }

    /// Agent Recipes の入出力契約に沿った Codex Skill を作成・更新する。
    public static var skillCreator: Recipe {
        Recipe(
            id: "create-agent-recipes-skill",
            name: "Agent Recipes 用 Skill を作成",
            description: "Recipe の入力・出力契約に沿った Codex Skill を作成または更新する",
            category: "Development",
            tags: ["skill", "agent-recipes", "codex"],
            skill: SkillReference(name: "agent-recipes-skill-creator", source: "codex"),
            arguments: [
                ArgumentSpec(
                    name: "requirement",
                    label: "作りたい Skill の要件",
                    type: .multiline,
                    required: true
                ),
            ],
            mode: .submit,
            target: TargetSpec(session: .newSession),
            body: """
            以下の要件に沿って、Agent Recipes から呼び出す Codex Skill を作成または更新してください。

            {{requirement}}
            """
        )
    }
}
