import Foundation
import AgentRecipesCore

public enum RunOutcome: Sendable {
    /// 送信 (またはコピー) まで完了した。
    case completed(RunReceipt)
}

public struct RunReceipt: Hashable, Sendable {
    public var recipeName: String
    public var mode: ExecutionMode
    public var agent: HerdrAgent?
    public var project: Project?
    /// 送信のために Agent を新規起動したか。
    public var startedNewAgent: Bool = false

    /// 通知文。例: "Review Diff — Sent to ComposerSketch / Codex"
    public var notificationText: String {
        let suffix = startedNewAgent ? " (new)" : ""
        switch mode {
        case .copy:
            return "\(recipeName) — Copied to clipboard"
        case .paste:
            return "\(recipeName) — Pasted to \(agent?.displayName ?? "-")\(suffix)"
        case .submit:
            return "\(recipeName) — Sent to \(agent?.displayName ?? "-")\(suffix)"
        }
    }
}

/// Recipe を「Prompt 生成 → 送信先解決 → Herdr へ投入」まで通す。
/// GUI / CLI はこれだけを呼ぶ。
public struct RecipeRunner: Sendable {
    public static let defaultWorkspaceLabel = "AgentRecipes"

    private let client: HerdrClient
    private let builder: PromptBuilder
    private let targetResolver: TargetResolver
    private let clipboard: ClipboardAccess
    private let history: HistoryRepository?
    /// 送信先の LLM。アプリ設定から渡す。
    private let agentKind: AgentKind
    /// Recipe に作業フォルダが無いときの cwd。nil なら herdr の既定に任せる。
    private let defaultWorkingDirectory: String?

    public init(
        client: HerdrClient,
        agentKind: AgentKind = .claude,
        defaultWorkingDirectory: String? = nil,
        clipboard: ClipboardAccess = SystemClipboard(),
        history: HistoryRepository? = nil
    ) {
        self.agentKind = agentKind
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.client = client
        self.builder = PromptBuilder(clipboard: clipboard)
        self.targetResolver = TargetResolver()
        self.clipboard = clipboard
        self.history = history
    }

    /// Recipe を実行する。送信先が確定しない場合は `.needsTarget` を返す。
    public func run(
        recipe: Recipe,
        values: [String: String],
        project: Project?,
        additionalPrompt: String = "",
        modeOverride: ExecutionMode? = nil,
        waitTimeoutMS: Int? = nil
    ) throws -> RunOutcome {
        let mode = modeOverride ?? recipe.mode
        let prompt: String
        do {
            prompt = try builder.build(
                recipe: recipe,
                userValues: values,
                project: project,
                additionalPrompt: additionalPrompt
            )
        } catch {
            record(recipe: recipe, mode: mode, project: project, agent: nil, result: .failure, message: error.localizedDescription)
            throw error
        }

        // Copy は Herdr を必要としない。
        guard mode.requiresHerdr else {
            clipboard.write(prompt)
            let receipt = RunReceipt(recipeName: recipe.name, mode: .copy, agent: nil, project: project)
            record(recipe: recipe, mode: mode, project: project, agent: nil, result: .success, message: receipt.notificationText)
            return .completed(receipt)
        }

        do {
            let agents = try client.listAgents()
            switch try targetResolver.resolve(
                recipe: recipe, project: project, agents: agents, agentKind: agentKind
            ) {
            case .resolved(let agent):
                return .completed(try send(
                    prompt: prompt, recipe: recipe, mode: mode, agent: agent,
                    project: project, waitTimeoutMS: waitTimeoutMS
                ))

            case .startNew(let kind, let newAgentProject):
                let agent = try startAgent(
                    kind: kind,
                    project: newAgentProject,
                    workspaceID: recipe.target.workspaceID,
                    workspaceName: recipe.target.workspaceName
                )
                var receipt = try send(
                    prompt: prompt, recipe: recipe, mode: mode, agent: agent,
                    project: project, waitTimeoutMS: waitTimeoutMS
                )
                receipt.startedNewAgent = true
                return .completed(receipt)
            }
        } catch {
            record(recipe: recipe, mode: mode, project: project, agent: nil, result: .failure, message: error.localizedDescription)
            throw error
        }
    }

    /// 送信先をユーザーが選んだあとの投入。
    @discardableResult
    public func send(
        prompt: String,
        recipe: Recipe,
        mode: ExecutionMode,
        agent: HerdrAgent,
        project: Project?,
        waitTimeoutMS: Int? = nil
    ) throws -> RunReceipt {
        do {
            switch mode {
            case .copy:
                clipboard.write(prompt)
            case .paste:
                try client.sendText(prompt, toPane: agent.paneID)
                // 入力状態にして編集してもらうので、その pane を前面に出す。
                try? client.focusAgent(target: agent.id)
            case .submit:
                try client.promptAgent(prompt, target: agent.id, waitTimeoutMS: waitTimeoutMS)
            }
        } catch {
            record(recipe: recipe, mode: mode, project: project, agent: agent, result: .failure, message: error.localizedDescription)
            throw error
        }

        let receipt = RunReceipt(recipeName: recipe.name, mode: mode, agent: agent, project: project)
        record(recipe: recipe, mode: mode, project: project, agent: agent, result: .success, message: receipt.notificationText)
        return receipt
    }

    /// 新しい tab を作って Agent を起動し、受け付けられる状態まで待つ。
    private func startAgent(
        kind: String,
        project: Project?,
        workspaceID: String?,
        workspaceName: String?
    ) throws -> HerdrAgent {
        let cwd = project?.expandedPath ?? defaultWorkingDirectory
        let label = project?.name ?? kind
        let workspaces = try client.listWorkspaces()
        // 指定が無ければ AgentRecipes 用の workspace にまとめる。
        let wantedName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetName = (wantedName?.isEmpty == false) ? wantedName! : Self.defaultWorkspaceLabel
        let workspace = workspaces.first { $0.id == workspaceID }
            ?? workspaces.first { $0.label?.caseInsensitiveCompare(targetName) == .orderedSame }
        let pane: HerdrPane
        if let workspace {
            pane = try client.createTab(cwd: cwd, label: label, workspaceID: workspace.id)
        } else {
            // 指定された名前の workspace がまだ無いので作る。
            // workspace create は最初の tab / pane も同時に作るため、そのpaneを直接使う。
            pane = try client.createWorkspace(cwd: cwd, label: targetName)
        }
        // Herdr の Agent 名は workspace 全体で一意である必要がある。
        // 新規作成した pane id を含めれば、同じ Recipe の連続実行でも衝突しない。
        let uniqueName = Recipe.makeID(from: "\(kind)-\(pane.id)")
        let started = try startAgentWhenPaneIsReady(name: uniqueName, kind: kind, pane: pane.id)
        // 起動直後は信頼確認などで一時的に受け付けない状態になりうるので待つ。
        return client.waitForAgent(target: started.id) ?? started
    }

    /// tab 作成直後はシェルの初期化が終わるまで `agent_pane_busy` になることがある。
    /// その場合だけ短く待って再試行する。
    private func startAgentWhenPaneIsReady(name: String, kind: String, pane: String) throws -> HerdrAgent {
        let maxAttempts = 20
        for attempt in 1...maxAttempts {
            do {
                return try client.startAgent(name: name, kind: kind, pane: pane)
            } catch let error as HerdrError {
                guard case .commandFailed(_, let code, _) = error,
                      code == "agent_pane_busy",
                      attempt < maxAttempts else {
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        preconditionFailure("retry loop must return or throw")
    }

    /// 送信先を自分で選んでから送る場合に使う Prompt 生成。
    public func buildPrompt(
        recipe: Recipe,
        values: [String: String],
        project: Project?,
        additionalPrompt: String = ""
    ) throws -> String {
        try builder.build(recipe: recipe, userValues: values, project: project, additionalPrompt: additionalPrompt)
    }

    public func preview(
        recipe: Recipe,
        values: [String: String],
        project: Project?,
        additionalPrompt: String = ""
    ) -> String {
        builder.preview(recipe: recipe, userValues: values, project: project, additionalPrompt: additionalPrompt)
    }

    public func initialValues(for recipe: Recipe) -> [String: String] {
        builder.initialValues(for: recipe)
    }

    private func record(
        recipe: Recipe,
        mode: ExecutionMode,
        project: Project?,
        agent: HerdrAgent?,
        result: HistoryEntry.Result,
        message: String?
    ) {
        history?.append(HistoryEntry(
            recipeID: recipe.id,
            recipeName: recipe.name,
            project: project?.name,
            agent: agent?.agentName,
            mode: mode,
            result: result,
            message: message
        ))
    }
}
