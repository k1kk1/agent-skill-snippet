import Foundation
import AgentRecipesCore

public enum RunOutcome: Sendable {
    /// 送信 (またはコピー) まで完了した。
    case completed(RunReceipt)
}

/// 実行中の進み具合。UI のローディング表示に使う。
public enum RunStage: Hashable, Sendable {
    case buildingPrompt
    case resolvingTarget
    case startingAgent
    case sending
    case waitingForResponse

    public var displayName: String {
        switch self {
        case .buildingPrompt: return "Prompt を組み立てています"
        case .resolvingTarget: return "送信先を確認しています"
        case .startingAgent: return "新しいセッションを起動しています"
        case .sending: return "Prompt を送信しています"
        case .waitingForResponse: return "応答を待っています"
        }
    }
}

public struct RunReceipt: Hashable, Sendable {
    public var recipeName: String
    public var mode: ExecutionMode
    public var agent: HerdrAgent?
    public var project: Project?
    /// 送信のために Agent を新規起動したか。
    public var startedNewAgent: Bool = false
    /// 送った Prompt。届かなかった場合に送り直せるよう持っておく。
    public var prompt: String = ""
    /// Prompt が Agent の画面に入ったことを確認できたか。
    /// 起動時の確認 (フォルダの信頼、モデル選択など) で止まっていると false になる。
    public var promptDelivered: Bool = true

    /// 通知文。例: "Review Diff — Sent to ComposerSketch / Codex"
    public var notificationText: String {
        let suffix = startedNewAgent ? " (new)" : ""
        switch mode {
        case .copy:
            return "\(recipeName) — Copied to clipboard"
        case .paste:
            return "\(recipeName) — Pasted to \(agent?.displayName ?? "-")\(suffix)"
        case .submit:
            guard promptDelivered else {
                return "\(recipeName) — \(agent?.displayName ?? "-") が起動時の確認で止まっています"
            }
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
        self.builder = PromptBuilder(clipboard: clipboard, defaultWorkingDirectory: defaultWorkingDirectory)
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
        waitTimeoutMS: Int? = nil,
        progress: (@Sendable (RunStage) -> Void)? = nil
    ) throws -> RunOutcome {
        let mode = modeOverride ?? recipe.mode
        progress?(.buildingPrompt)
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
            progress?(.resolvingTarget)
            let agents = try client.listAgents()
            switch try targetResolver.resolve(
                recipe: recipe, project: project, agents: agents, agentKind: agentKind
            ) {
            case .resolved(let agent):
                return .completed(try send(
                    prompt: prompt, recipe: recipe, mode: mode, agent: agent,
                    project: project, waitTimeoutMS: waitTimeoutMS, progress: progress
                ))

            case .startNew(let kind, let newAgentProject):
                progress?(.startingAgent)
                let agent = try startAgent(
                    kind: kind,
                    project: newAgentProject,
                    workspaceID: recipe.target.workspaceID,
                    workspaceName: recipe.target.workspaceName
                )
                var receipt = try send(
                    prompt: prompt, recipe: recipe, mode: mode, agent: agent,
                    project: project, waitTimeoutMS: waitTimeoutMS, progress: progress
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
        waitTimeoutMS: Int? = nil,
        progress: (@Sendable (RunStage) -> Void)? = nil
    ) throws -> RunReceipt {
        progress?(.sending)
        var delivered = true
        do {
            switch mode {
            case .copy:
                clipboard.write(prompt)
            case .paste:
                try client.sendText(prompt, toPane: agent.paneID)
                // 入力状態にして編集してもらうので、その pane を前面に出す。
                try? client.focusAgent(target: agent.id)
            case .submit:
                delivered = try submit(
                    prompt, to: agent, waitTimeoutMS: waitTimeoutMS, progress: progress
                )
            }
        } catch {
            record(recipe: recipe, mode: mode, project: project, agent: agent, result: .failure, message: error.localizedDescription)
            throw error
        }

        let receipt = RunReceipt(
            recipeName: recipe.name, mode: mode, agent: agent, project: project,
            prompt: prompt, promptDelivered: delivered
        )
        record(
            recipe: recipe, mode: mode, project: project, agent: agent,
            // 送れていない場合は失敗ではなく「確認待ち」。答えれば続行できる。
            result: delivered ? .success : .pending,
            message: receipt.notificationText
        )
        return receipt
    }

    /// Prompt を送り、Agent の画面に入ったことを確認する。
    ///
    /// 起動直後の Agent は、フォルダの信頼確認・モデル選択・MCP のロードなどで
    /// 入力を受け付けないことがある。受理されたように見えて入力だけ落ちるため、
    /// 送ったあとに画面を読んで確かめ、必要なら 1 度だけ送り直す。
    private func submit(
        _ prompt: String,
        to agent: HerdrAgent,
        waitTimeoutMS: Int?,
        progress: (@Sendable (RunStage) -> Void)? = nil
    ) throws -> Bool {
        // 確認ダイアログが出ている間に送ると、その選択肢に文字を打ち込むことになる。
        // 起動直後は一瞬だけ blocked になることがあるので、少しだけ様子を見る。
        if isBlocked(agent), isBlocked(waitWhileBlocked(agent)) { return false }

        if waitTimeoutMS != nil { progress?(.waitingForResponse) }
        try client.promptAgent(prompt, target: agent.id, waitTimeoutMS: waitTimeoutMS)
        if promptLanded(prompt, pane: agent.paneID) { return true }

        // MCP のロードなどで取りこぼした場合はもう一度だけ試す。
        guard let retryTarget = client.waitUntilInteractive(target: agent.id), !isBlocked(retryTarget) else {
            return false
        }
        try client.promptAgent(prompt, target: agent.id, waitTimeoutMS: waitTimeoutMS)
        return promptLanded(prompt, pane: agent.paneID)
    }

    private func isBlocked(_ agent: HerdrAgent) -> Bool {
        (agent.status ?? "").lowercased() == "blocked"
    }

    /// 起動直後の一時的な blocked (バナー表示や起動処理の途中) が解けるか短く待つ。
    /// 本物の確認ダイアログはユーザーが答えるまで解けないので、待ちは短くする。
    private func waitWhileBlocked(_ agent: HerdrAgent, timeoutMS: Int = 8_000) -> HerdrAgent {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        var latest = agent
        while Date() < deadline, isBlocked(latest) {
            Thread.sleep(forTimeInterval: 0.5)
            guard let next = try? client.agent(target: latest.id) else { return latest }
            latest = next
        }
        return latest
    }

    /// 画面に Prompt の一部が出ているか。
    /// TUI は折り返すので、空白を落としてから探す。
    private func promptLanded(_ prompt: String, pane: String) -> Bool {
        guard let needle = Self.deliveryMarker(for: prompt) else { return true }
        // 画面を読めないときは「届いた」とみなす。
        // 判定を誤って送り直すと、同じ Prompt が二重に実行されてしまう。
        guard let output = try? client.readPane(pane, lines: 200),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return Self.squeezed(output).contains(needle)
    }

    /// 届いたかを確かめるための短い目印。長すぎると折り返しや装飾で一致しなくなる。
    static func deliveryMarker(for prompt: String) -> String? {
        let firstLine = prompt
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine, !firstLine.isEmpty else { return nil }
        let marker = squeezed(String(firstLine.prefix(40)))
        return marker.count >= 4 ? marker : nil
    }

    static func squeezed(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
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
        let settled = client.waitForAgent(target: started.id) ?? started
        // status が idle でも TUI が描き終わっていないことがあり、
        // その間に送った Prompt は握りつぶされる。入力可能になるまで待つ。
        let interactive = client.waitUntilInteractive(target: settled.id) ?? settled
        // MCP のロードなどで起動処理が続いていると、まだ Prompt を取りこぼす。
        // 落ち着く (idle / done) か、確認待ち (blocked) になるまで待つ。
        return waitUntilSettled(interactive)
    }

    /// 起動処理 (MCP のロードなど) が終わるのを待つ。
    /// blocked は待っても解けない (ユーザーが答えるまで進まない) のでそこで止める。
    private func waitUntilSettled(_ agent: HerdrAgent, timeoutMS: Int = 60_000) -> HerdrAgent {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        var latest = agent
        while Date() < deadline {
            switch (latest.status ?? "").lowercased() {
            case "idle", "done", "blocked": return latest
            default: break
            }
            Thread.sleep(forTimeInterval: 0.5)
            guard let next = try? client.agent(target: latest.id) else { return latest }
            latest = next
        }
        return latest
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
            paneID: agent?.paneID,
            mode: mode,
            result: result,
            message: message
        ))
    }
}
