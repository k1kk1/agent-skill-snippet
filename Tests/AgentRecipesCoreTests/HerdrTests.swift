import XCTest
@testable import AgentRecipesCore
@testable import HerdrKit

/// herdr を実際には起動せず、コマンドと入力を記録するだけの Runner。
final class FakeHerdrRunner: HerdrCommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        var arguments: [String]
        var input: String?
    }

    private(set) var invocations: [Invocation] = []
    var responses: [String: HerdrCommandResult] = [:]
    var responseSequences: [String: [HerdrCommandResult]] = [:]
    var defaultResult = HerdrCommandResult(
        exitCode: 0,
        standardOutput: #"{"id":"cli","result":{"agents":[],"panes":[],"workspaces":[],"tabs":[]}}"#,
        standardError: ""
    )

    func run(executable: String, arguments: [String], input: String?) throws -> HerdrCommandResult {
        invocations.append(Invocation(arguments: arguments, input: input))
        // 完全一致 → サブコマンド ("tab create" など) の順に探す。
        for key in [arguments.joined(separator: " "), arguments.prefix(2).joined(separator: " ")] {
            if var sequence = responseSequences[key], !sequence.isEmpty {
                let next = sequence.removeFirst()
                responseSequences[key] = sequence
                return next
            }
        }
        if let exact = responses[arguments.joined(separator: " ")] { return exact }
        if let sub = responses[arguments.prefix(2).joined(separator: " ")] { return sub }
        return defaultResult
    }

    var lastArguments: [String] { invocations.last?.arguments ?? [] }
}

private func makeClient(_ runner: FakeHerdrRunner) -> HerdrClient {
    // executablePath を明示すると locate() を通らない。
    HerdrClient(executablePath: "/bin/echo", runner: runner)
}

final class HerdrClientTests: XCTestCase {
    /// 実際の herdr 0.8 が返すエンベロープ。
    private let agentsJSON = """
    {"id":"cli:agent:list","result":{"type":"agent_list","agents":[
      {"agent":"codex","agent_status":"idle","cwd":"/Users/x/src/ComposerSketch","pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_title_stripped":"ComposerSketch","focused":false},
      {"agent":"claude","agent_status":"working","cwd":"/Users/x/src/music-db","pane_id":"w1:p2","tab_id":"w1:t1","workspace_id":"w1","terminal_title_stripped":"music-db","focused":true}
    ]}}
    """

    func testListAgentsDecodesJSON() throws {
        let runner = FakeHerdrRunner()
        runner.responses["agent list"] = HerdrCommandResult(
            exitCode: 0, standardOutput: agentsJSON, standardError: ""
        )
        let agents = try makeClient(runner).listAgents()
        XCTAssertEqual(agents.map(\.id), ["w1:p1", "w1:p2"])
        XCTAssertEqual(agents[0].displayName, "ComposerSketch / Codex")
        XCTAssertEqual(agents[0].paneID, "w1:p1")
        XCTAssertTrue(agents[0].isIdle)
        XCTAssertFalse(agents[1].isIdle)
        XCTAssertEqual(runner.lastArguments, ["agent", "list"])
    }

    func testListCommandsUseExpectedSubcommands() throws {
        let runner = FakeHerdrRunner()
        let client = makeClient(runner)
        _ = try client.listWorkspaces()
        XCTAssertEqual(runner.lastArguments, ["workspace", "list"])
        _ = try client.listTabs()
        XCTAssertEqual(runner.lastArguments, ["tab", "list"])
        _ = try client.listPanes()
        XCTAssertEqual(runner.lastArguments, ["pane", "list"])
    }

    func testCreateWorkspaceReturnsItsRootPane() throws {
        let runner = FakeHerdrRunner()
        runner.responses["workspace create"] = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"result":{"root_pane":{"pane_id":"w2:p1","workspace_id":"w2"},"workspace":{"workspace_id":"w2","label":"AgentRecipes"}}}"#,
            standardError: ""
        )
        let pane = try makeClient(runner).createWorkspace(cwd: "/Users/x/src/app", label: "AgentRecipes")
        XCTAssertEqual(pane.id, "w2:p1")
        XCTAssertEqual(
            runner.lastArguments,
            ["workspace", "create", "--no-focus", "--cwd", "/Users/x/src/app", "--label", "AgentRecipes"]
        )
    }

    func testCreateTabCanTargetWorkspace() throws {
        let runner = FakeHerdrRunner()
        runner.responses["tab create"] = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"result":{"root_pane":{"pane_id":"w2:p2","workspace_id":"w2"}}}"#,
            standardError: ""
        )
        let pane = try makeClient(runner).createTab(cwd: nil, label: "codex", workspaceID: "w2")
        XCTAssertEqual(pane.id, "w2:p2")
        XCTAssertEqual(
            runner.lastArguments,
            ["tab", "create", "--no-focus", "--workspace", "w2", "--label", "codex"]
        )
    }

    /// Paste は pane send-text、Submit は agent prompt。
    func testSendTextUsesPaneSendText() throws {
        let runner = FakeHerdrRunner()
        try makeClient(runner).sendText("hello", toPane: "w1:p1")
        XCTAssertEqual(runner.lastArguments, ["pane", "send-text", "w1:p1", "hello"])
    }

    func testPromptAgentUsesAgentPrompt() throws {
        let runner = FakeHerdrRunner()
        try makeClient(runner).promptAgent("hello", target: "w1:p2")
        XCTAssertEqual(runner.lastArguments, ["agent", "prompt", "w1:p2", "hello"])
    }

    func testNotRunningIsClassifiedFromStderr() {
        let runner = FakeHerdrRunner()
        runner.defaultResult = HerdrCommandResult(
            exitCode: 1, standardOutput: "", standardError: "could not connect to herdr server"
        )
        XCTAssertThrowsError(try makeClient(runner).listAgents()) { error in
            guard case .notRunning = error as? HerdrError else {
                return XCTFail("notRunning に分類されるべき: \(error)")
            }
        }
    }

    /// herdr はエラーでも終了コード 0 を返し、JSON の error に理由を入れる。
    func testErrorEnvelopeWithZeroExitIsDetected() {
        let runner = FakeHerdrRunner()
        runner.defaultResult = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"error":{"code":"agent_not_found","message":"agent target w9:p9 not found"},"id":"cli:agent:get"}"#,
            standardError: ""
        )
        XCTAssertThrowsError(try makeClient(runner).agent(target: "w9:p9")) { error in
            guard case .commandFailed(_, let code, _) = error as? HerdrError else {
                return XCTFail("commandFailed に分類されるべき: \(error)")
            }
            XCTAssertEqual(code, "agent_not_found")
        }
    }

    func testErrorEnvelopeOnSendIsDetected() {
        let runner = FakeHerdrRunner()
        runner.defaultResult = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"error":{"code":"pane_not_found","message":"pane w9:p9 not found"},"id":"cli:pane:send-text"}"#,
            standardError: ""
        )
        XCTAssertThrowsError(try makeClient(runner).sendText("hi", toPane: "w9:p9"))
    }

    func testNonZeroExitBecomesCommandFailed() {
        let runner = FakeHerdrRunner()
        runner.defaultResult = HerdrCommandResult(exitCode: 2, standardOutput: "", standardError: "boom")
        XCTAssertThrowsError(try makeClient(runner).listAgents()) { error in
            guard case .commandFailed = error as? HerdrError else {
                return XCTFail("commandFailed に分類されるべき: \(error)")
            }
        }
    }

    func testNonZeroJSONErrorPreservesRemoteCode() {
        let runner = FakeHerdrRunner()
        runner.defaultResult = HerdrCommandResult(
            exitCode: 1,
            standardOutput: "",
            standardError: #"{"error":{"code":"agent_pane_busy","message":"not an available shell"}}"#
        )
        XCTAssertThrowsError(try makeClient(runner).startAgent(name: "x", kind: "codex", pane: "w1:p9")) { error in
            guard case .commandFailed(_, let code, _) = error as? HerdrError else {
                return XCTFail("commandFailed のはず: \(error)")
            }
            XCTAssertEqual(code, "agent_pane_busy")
        }
    }

    func testBrokenJSONBecomesDecodingFailed() {
        let runner = FakeHerdrRunner()
        runner.defaultResult = HerdrCommandResult(exitCode: 0, standardOutput: "{not json", standardError: "")
        XCTAssertThrowsError(try makeClient(runner).listAgents()) { error in
            guard case .decodingFailed = error as? HerdrError else {
                return XCTFail("decodingFailed に分類されるべき: \(error)")
            }
        }
    }

    func testMissingExecutableIsNotInstalled() throws {
        let client = HerdrClient(executablePath: "/nonexistent/herdr", runner: FakeHerdrRunner())
        // 実在しないパスは無視され、locate() も失敗すれば notInstalled になる。
        if client.isInstalled { throw XCTSkip("この環境には herdr が実在するためスキップ") }
        XCTAssertThrowsError(try client.listAgents()) { error in
            XCTAssertEqual(error as? HerdrError, .notInstalled)
        }
    }

    func testConnectionStatusReportsAgentCount() {
        let runner = FakeHerdrRunner()
        runner.responses["agent list"] = HerdrCommandResult(
            exitCode: 0, standardOutput: agentsJSON, standardError: ""
        )
        XCTAssertEqual(makeClient(runner).connectionStatus(), .connected(agentCount: 2))
    }

    func testConnectionStatusReportsNotRunning() {
        let runner = FakeHerdrRunner()
        runner.defaultResult = HerdrCommandResult(exitCode: 1, standardOutput: "", standardError: "not running")
        XCTAssertEqual(makeClient(runner).connectionStatus(), .notRunning)
    }
}

final class TargetResolverTests: XCTestCase {
    private let agents = [
        HerdrAgent(id: "w1:p1", agent: "codex", status: "working", cwd: "/Users/x/src/ComposerSketch"),
        HerdrAgent(id: "w1:p2", agent: "claude", status: "idle", cwd: "/Users/x/src/music-db"),
        HerdrAgent(id: "w1:p3", agent: "claude", status: "idle", cwd: "/Users/x/src/other"),
    ]
    private let musicDB = Project(id: "proj-music", name: "music-db", path: "/Users/x/src/music-db")

    private func recipe(_ session: SessionPolicy, projectID: String? = nil) -> Recipe {
        Recipe(id: "r", name: "R", target: TargetSpec(session: session, projectID: projectID), body: "hello")
    }

    private func resolve(
        _ recipe: Recipe,
        project: Project?,
        agents: [HerdrAgent],
        agentKind: AgentKind = .claude
    ) throws -> TargetResolution {
        try TargetResolver().resolve(recipe: recipe, project: project, agents: agents, agentKind: agentKind)
    }

    /// 既定は毎回新しいセッション。空いている既存 Agent がいても使わない。
    func testNewSessionIsUsedEvenWhenIdleAgentsExist() throws {
        let resolution = try resolve(recipe(.newSession), project: musicDB, agents: agents)
        XCTAssertEqual(resolution, .startNew(agent: "claude", project: musicDB))
    }

    func testNewSessionUsesConfiguredAgentKind() throws {
        let resolution = try resolve(recipe(.newSession), project: nil, agents: agents, agentKind: .codex)
        XCTAssertEqual(resolution, .startNew(agent: "codex", project: nil))
    }

    func testReuseUsesIdleAgentOfTheSameKind() throws {
        let resolution = try resolve(recipe(.reuseIfAvailable), project: nil, agents: agents)
        XCTAssertEqual(resolution, .resolved(agents[1]))
    }

    func testReuseSkipsWorkingAgentAndStartsNew() throws {
        let busy = HerdrAgent(id: "w1:p9", agent: "claude", status: "working", cwd: "/Users/x/src/app")
        let resolution = try resolve(recipe(.reuseIfAvailable), project: nil, agents: [busy])
        XCTAssertEqual(resolution, .startNew(agent: "claude", project: nil))
    }

    func testReuseMatchesProjectWhenRecipeHasOne() throws {
        // projectID があるときは cwd も一致させる。
        let resolution = try resolve(
            recipe(.reuseIfAvailable, projectID: "proj-music"), project: musicDB, agents: agents
        )
        XCTAssertEqual(resolution, .resolved(agents[1]))

        let other = Project(id: "proj-x", name: "x", path: "/Users/x/src/nope")
        let miss = try resolve(
            recipe(.reuseIfAvailable, projectID: "proj-x"), project: other, agents: agents
        )
        XCTAssertEqual(miss, .startNew(agent: "claude", project: other))
    }

    func testAskAlwaysAsks() throws {
        let resolution = try resolve(recipe(.ask), project: musicDB, agents: agents)
        XCTAssertEqual(resolution, .ask(candidates: agents, reason: .strategyIsAsk))
    }

    func testRankingPrefersIdleThenDoneAndAvoidsWorking() {
        let working = HerdrAgent(id: "p1", agent: "codex", status: "working")
        let done = HerdrAgent(id: "p2", agent: "codex", status: "done")
        let idle = HerdrAgent(id: "p3", agent: "codex", status: "idle")
        let blocked = HerdrAgent(id: "p4", agent: "codex", status: "blocked")
        let ranked = TargetResolver().rank([working, blocked, done, idle])
        XCTAssertEqual(ranked.map(\.id), ["p3", "p2", "p4", "p1"])
    }

    func testPaneDisplayName() {
        XCTAssertEqual(agents[1].displayName, "music-db / Claude")
        XCTAssertTrue(agents[1].isIdle)
        XCTAssertFalse(agents[1].isWorking)
    }
}

final class RecipeRunnerTests: XCTestCase {
    private var root: URL!
    private var layout: StorageLayout!
    private let agents = [
        HerdrAgent(id: "w1:p1", agent: "codex", status: "idle", cwd: "/Users/x/src/ComposerSketch"),
    ]

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentrecipes-runner-\(UUID().uuidString)")
        layout = StorageLayout(root: root)
        try layout.ensureDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func runner(
        _ runner: FakeHerdrRunner,
        clipboard: ClipboardAccess,
        agentKind: AgentKind = .codex
    ) -> (RecipeRunner, HistoryRepository) {
        let history = HistoryRepository(layout: layout, limit: 20)
        return (
            RecipeRunner(client: makeClient(runner), agentKind: agentKind, clipboard: clipboard, history: history),
            history
        )
    }

    private func agentListResult() -> HerdrCommandResult {
        HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"id":"cli:agent:list","result":{"agents":[{"agent":"codex","agent_status":"idle","cwd":"/Users/x/src/ComposerSketch","pane_id":"w1:p1","workspace_id":"w1"}]}}"#,
            standardError: ""
        )
    }

    func testCopyModeUsesClipboardAndNeverCallsHerdr() throws {
        let fake = FakeHerdrRunner()
        let clipboard = FakeClipboard("元の内容")
        let (runner, history) = runner(fake, clipboard: clipboard)

        let recipe = Recipe(id: "c", name: "Copy Me", mode: .copy, body: "hello")
        let outcome = try runner.run(recipe: recipe, values: [:], project: nil)

        guard case .completed(let receipt) = outcome else { return XCTFail("completed のはず") }
        XCTAssertEqual(clipboard.read(), "hello")
        XCTAssertTrue(fake.invocations.isEmpty)
        XCTAssertEqual(receipt.notificationText, "Copy Me — Copied to clipboard")
        XCTAssertEqual(history.recent().first?.result, .success)
    }

    func testSubmitSendsPromptToResolvedAgent() throws {
        let fake = FakeHerdrRunner()
        fake.responses["agent list"] = agentListResult()
        let (runner, history) = runner(fake, clipboard: FakeClipboard())

        let recipe = Recipe(
            id: "review", name: "Review Diff",
            mode: .submit,
            target: TargetSpec(session: .reuseIfAvailable),
            body: "レビューしてください"
        )
        let outcome = try runner.run(recipe: recipe, values: [:], project: nil)

        guard case .completed(let receipt) = outcome else { return XCTFail("completed のはず") }
        XCTAssertEqual(fake.lastArguments, ["agent", "prompt", "w1:p1", "レビューしてください"])
        XCTAssertEqual(receipt.notificationText, "Review Diff — Sent to ComposerSketch / Codex")
        XCTAssertEqual(history.recent().first?.agent, "codex")
    }

    func testPasteSendsTextToThePaneOfTheAgent() throws {
        let fake = FakeHerdrRunner()
        fake.responses["agent list"] = agentListResult()
        let (runner, _) = runner(fake, clipboard: FakeClipboard())

        let recipe = Recipe(
            id: "p", name: "Paste Me", mode: .paste,
            target: TargetSpec(session: .reuseIfAvailable),
            body: "text"
        )
        let outcome = try runner.run(recipe: recipe, values: [:], project: nil)

        guard case .completed(let receipt) = outcome else { return XCTFail("completed のはず") }
        // 入力したあとチャットを前面に出す。
        let commands = fake.invocations.map { $0.arguments.prefix(2).joined(separator: " ") }
        XCTAssertEqual(commands, ["agent list", "pane send-text", "agent focus"])
        XCTAssertEqual(fake.invocations[1].arguments, ["pane", "send-text", "w1:p1", "text"])
        XCTAssertEqual(receipt.notificationText, "Paste Me — Pasted to ComposerSketch / Codex")
    }

    func testUnresolvedTargetReturnsNeedsTargetWithPrompt() throws {
        let fake = FakeHerdrRunner()
        fake.responses["agent list"] = agentListResult()
        let (runner, _) = runner(fake, clipboard: FakeClipboard())

        let recipe = Recipe(
            id: "ask", name: "Ask", mode: .submit,
            target: TargetSpec(session: .ask),
            body: "本文"
        )
        let outcome = try runner.run(recipe: recipe, values: [:], project: nil)

        guard case .needsTarget(let prompt, let candidates, let reason) = outcome else {
            return XCTFail("needsTarget のはず")
        }
        XCTAssertEqual(prompt, "本文")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(reason, .strategyIsAsk)
        // 選ばせる段階では送信していない。
        XCTAssertFalse(fake.invocations.contains { $0.arguments.contains("prompt") })
    }

    /// AgentRecipes space が無いときは作成時のroot paneでAgentを起動する。
    func testStartNewCreatesDefaultWorkspaceStartsAgentAndSends() throws {
        let fake = FakeHerdrRunner()
        fake.responses["agent list"] = HerdrCommandResult(
            exitCode: 0, standardOutput: #"{"result":{"agents":[]}}"#, standardError: ""
        )
        fake.responses["workspace list"] = HerdrCommandResult(
            exitCode: 0, standardOutput: #"{"result":{"workspaces":[]}}"#, standardError: ""
        )
        fake.responses["workspace create"] = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"result":{"root_pane":{"pane_id":"w2:p1","cwd":"/Users/x/src/music-db","workspace_id":"w2"},"workspace":{"workspace_id":"w2","label":"AgentRecipes"}}}"#,
            standardError: ""
        )
        fake.responses["agent start"] = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"result":{"agent":{"pane_id":"w2:p1","agent":"codex","agent_status":"idle","cwd":"/Users/x/src/music-db"}}}"#,
            standardError: ""
        )
        fake.responses["agent wait"] = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"result":{"agent":{"pane_id":"w2:p1","agent":"codex","agent_status":"idle","cwd":"/Users/x/src/music-db"}}}"#,
            standardError: ""
        )
        let (runner, history) = runner(fake, clipboard: FakeClipboard())
        let project = Project(id: "p", name: "music-db", path: "/Users/x/src/music-db")
        let recipe = Recipe(
            id: "new", name: "New Agent Run", mode: .submit,
            target: TargetSpec(session: .newSession, projectID: "p"),
            body: "はじめまして"
        )

        let outcome = try runner.run(recipe: recipe, values: [:], project: project)
        guard case .completed(let receipt) = outcome else { return XCTFail("completed のはず") }

        let commands = fake.invocations.map { $0.arguments.prefix(2).joined(separator: " ") }
        XCTAssertEqual(commands, ["agent list", "workspace list", "workspace create", "agent start", "agent wait", "agent prompt"])
        XCTAssertEqual(
            fake.invocations[2].arguments,
            ["workspace", "create", "--no-focus", "--cwd", "/Users/x/src/music-db", "--label", "AgentRecipes"]
        )
        XCTAssertEqual(
            fake.invocations[3].arguments,
            ["agent", "start", "codex-w2-p1", "--kind", "codex", "--pane", "w2:p1"]
        )
        XCTAssertEqual(fake.lastArguments, ["agent", "prompt", "w2:p1", "はじめまして"])
        XCTAssertTrue(receipt.startedNewAgent)
        XCTAssertEqual(receipt.notificationText, "New Agent Run — Sent to music-db / Codex (new)")
        XCTAssertEqual(history.recent().first?.result, .success)
    }

    func testStartNewRetriesWhileCreatedPaneIsBusy() throws {
        let fake = FakeHerdrRunner()
        fake.responses["agent list"] = HerdrCommandResult(
            exitCode: 0, standardOutput: #"{"result":{"agents":[]}}"#, standardError: ""
        )
        fake.responses["workspace list"] = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"result":{"workspaces":[{"workspace_id":"w2","label":"AgentRecipes"}]}}"#,
            standardError: ""
        )
        fake.responses["tab create"] = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"result":{"root_pane":{"pane_id":"w1:pA"}}}"#,
            standardError: ""
        )
        let busy = HerdrCommandResult(
            exitCode: 1, standardOutput: "",
            standardError: #"{"error":{"code":"agent_pane_busy","message":"not an available shell"}}"#
        )
        let started = HerdrCommandResult(
            exitCode: 0,
            standardOutput: #"{"result":{"agent":{"pane_id":"w1:pA","agent":"codex","agent_status":"idle"}}}"#,
            standardError: ""
        )
        fake.responseSequences["agent start"] = [busy, started]
        fake.responses["agent wait"] = started

        let (runner, _) = runner(fake, clipboard: FakeClipboard())
        let recipe = Recipe(id: "retry", name: "Retry", mode: .submit, body: "hello")
        _ = try runner.run(recipe: recipe, values: [:], project: nil)

        XCTAssertEqual(
            fake.invocations.first { $0.arguments.prefix(2) == ["tab", "create"] }?.arguments,
            ["tab", "create", "--no-focus", "--workspace", "w2", "--label", "codex"]
        )
        XCTAssertEqual(fake.invocations.filter { $0.arguments.prefix(2) == ["agent", "start"] }.count, 2)
        XCTAssertEqual(fake.lastArguments, ["agent", "prompt", "w1:pA", "hello"])
    }

    func testMissingArgumentIsRecordedAsFailure() throws {
        let fake = FakeHerdrRunner()
        let (runner, history) = runner(fake, clipboard: FakeClipboard())
        let recipe = Recipe(
            id: "x", name: "X",
            arguments: [ArgumentSpec(name: "url", type: .url)],
            mode: .submit, body: "{{url}}"
        )
        XCTAssertThrowsError(try runner.run(recipe: recipe, values: [:], project: nil))
        XCTAssertEqual(history.recent().first?.result, .failure)
    }

    func testHerdrFailureIsRecordedAndRethrown() throws {
        let fake = FakeHerdrRunner()
        fake.defaultResult = HerdrCommandResult(exitCode: 1, standardOutput: "", standardError: "not running")
        let (runner, history) = runner(fake, clipboard: FakeClipboard())
        let recipe = Recipe(id: "s", name: "S", mode: .submit, body: "hi")

        XCTAssertThrowsError(try runner.run(recipe: recipe, values: [:], project: nil)) { error in
            guard case .notRunning = error as? HerdrError else {
                return XCTFail("notRunning のはず: \(error)")
            }
        }
        XCTAssertEqual(history.recent().first?.result, .failure)
    }
}
