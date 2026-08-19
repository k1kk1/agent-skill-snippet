import Foundation
import SwiftUI
import AppKit
import AgentRecipesCore
import HerdrKit

/// GUI 全体の状態。Prompt 生成・送信先解決・Herdr 呼び出しは
/// すべて Core / HerdrKit 側にあり、ここは「何を選んだか」だけを持つ。
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var recipes: [Recipe] = []
    @Published private(set) var recentIDs: [String] = []
    @Published var projects: [Project] = []
    @Published var settings: AppSettings
    @Published var searchText: String = ""

    /// 検出された Skill。Settings の Skills タブで一覧・表示する。
    @Published private(set) var skills: [DiscoveredSkill] = []

    /// Herdr 上の Agent 一覧と接続状態。
    @Published private(set) var agents: [HerdrAgent] = []
    /// Herdr 上の workspace 一覧。Recipe の再利用対象を絞るために使う。
    @Published private(set) var workspaces: [HerdrWorkspace] = []
    @Published private(set) var connection: HerdrConnectionStatus = .notInstalled

    /// LLM ごとの MCP 接続状況。Skill が MCP 待ちで止まるのを事前に気づけるようにする。
    @Published private(set) var mcp: [AgentKind: MCPInspection] = [:]
    @Published private(set) var mcpChecking: Set<AgentKind> = []

    /// 実行前プレビューの対象。
    @Published var previewRequest: RunPreview?
    /// Submit の応答結果。新しい順に持ち、Result ウィンドウで切り替えられる。
    /// 1 件しか持たないと、続けて実行したときに前の結果が消えてしまう。
    @Published private(set) var results: [RunResult] = []
    /// Result ウィンドウで表示している結果。
    @Published var selectedResultID: RunResult.ID?
    /// 確認への回答を送っている最中。
    @Published var isAnswering = false
    /// 実行中の Recipe。Result ウィンドウでローディングを出すために持つ。
    @Published var activeRun: ActiveRun?
    /// 応答待ちの実行。Recipe 名ではなく実行ごとの UUID で対応付ける。
    @Published private(set) var pendingResults: [PendingResult] = []

    private(set) var layout: StorageLayout
    private(set) var recipeRepository: RecipeRepository
    private(set) var projectRepository: ProjectRepository
    private let settingsRepository: SettingsRepository
    private(set) var historyRepository: HistoryRepository
    private var appliedSettings: AppSettings
    private var settingsSaveTask: Task<Void, Never>?
    private var clipboardSnapshot = ""
    private var hasClipboardSnapshot = false
    private var initialValuesCache: [Recipe.ID: [String: String]] = [:]
    /// 実行中の Task。中止ボタンから止める。
    private var runTask: Task<Void, Never>?
    /// 結果ウィンドウを開いているあいだ、pane を読み直し続ける Task。
    private var resultPollTask: Task<Void, Never>?
    /// 保留していた Prompt を送っている最中。二重送信を防ぐ。
    private var isSendingPendingPrompt = false

    /// 残しておく結果の数。
    static let resultLimit = 10

    /// 表示中の結果。
    var result: RunResult? {
        get { results.first { $0.id == selectedResultID } ?? results.first }
        set {
            guard let newValue else { return }
            if let index = results.firstIndex(where: { $0.id == newValue.id }) {
                results[index] = newValue
            } else {
                results.insert(newValue, at: 0)
                if results.count > Self.resultLimit { results.removeLast(results.count - Self.resultLimit) }
            }
            selectedResultID = newValue.id
        }
    }

    /// 利用者が答えないと先に進まない結果があるか。メニューバーのバッジに使う。
    var needsAttention: Bool {
        results.contains { $0.pendingPrompt != nil || $0.question != nil }
    }

    func clearResults() {
        results.removeAll()
        selectedResultID = nil
    }

    init() {
        let base = StorageLayout()
        let loaded = SettingsRepository(layout: base).load()
        let layout = StorageLayout(recipesDirectory: loaded.recipesDirectory)
        self.layout = layout
        self.settings = loaded
        self.settingsRepository = SettingsRepository(layout: layout)
        self.recipeRepository = RecipeRepository(layout: layout)
        self.projectRepository = ProjectRepository(layout: layout)
        self.historyRepository = HistoryRepository(layout: layout, limit: loaded.historyLimit)
        self.appliedSettings = loaded
        bootstrapIfNeeded()
        reload()
    }

    // MARK: - 読み込み

    func reload() {
        recipes = recipeRepository.loadAll()
        projects = projectRepository.load()
        recentIDs = historyRepository.recentRecipeIDs(limit: 5)
    }

    /// Herdr の状態を取り直す。メニューを開いたときと Settings から呼ぶ。
    func refreshHerdr() {
        let client = makeClient()
        Task {
            let state = await HerdrBackground.run {
                (
                    client.connectionStatus(),
                    (try? client.listAgents()) ?? [],
                    (try? client.listWorkspaces()) ?? []
                )
            }
            self.connection = state.0
            self.agents = state.1
            self.workspaces = state.2
        }
    }

    /// Skill Source を走査し直す。
    func reloadSkills() {
        let sources = settings.skillSources
        Task.detached(priority: .utility) {
            let found = SkillScanner().scan(sources: sources)
            await MainActor.run { self.skills = found }
        }
    }

    /// この時間を過ぎた結果は古いとみなして調べ直す。
    static let mcpFreshness: TimeInterval = 10 * 60

    /// MCP の接続状況を調べ直す。CLI の health check を待つので数秒かかる。
    /// - Parameters:
    ///   - agent: nil ならすべての LLM。
    ///   - force: 直近の結果があっても調べ直す (再チェックボタン用)。
    func refreshMCP(agent: AgentKind? = nil, force: Bool = false) {
        // 隠している LLM は CLI も叩かない (health check は数秒かかるため)。
        let targets = (agent.map { [$0] } ?? settings.mcpVisibleAgents).filter { kind in
            guard !force, let checkedAt = mcp[kind]?.checkedAt else { return true }
            return Date().timeIntervalSince(checkedAt) > Self.mcpFreshness
        }
        guard !targets.isEmpty else { return }
        // MCP 設定は cwd 依存なので、Agent を起動するのと同じディレクトリで調べる。
        let cwd = settings.ensureDefaultWorkingDirectory()
        for kind in targets where !mcpChecking.contains(kind) {
            mcpChecking.insert(kind)
            Task.detached(priority: .utility) {
                let inspection = MCPScanner().inspect(agent: kind, workingDirectory: cwd)
                await MainActor.run {
                    self.mcp[kind] = inspection
                    self.mcpChecking.remove(kind)
                }
            }
        }
    }

    /// 現在の LLM で接続に失敗している MCP サーバー。
    var currentMCPFailures: [MCPServer] { mcp[settings.agent]?.failures ?? [] }

    /// 表示対象の LLM だけをまとめた MCP 一覧。
    var mcpGroups: [MCPServerGroup] {
        MCPInspection.grouped(settings.mcpVisibleAgents.compactMap { mcp[$0] })
    }

    /// SKILL.md をエディタで開く。設定のコマンドで開けなければ OS の既定アプリに任せる。
    func openSkillFile(_ skill: DiscoveredSkill) {
        if SkillOpener(command: settings.editorCommand).open(path: skill.path) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: skill.path))
    }

    func revealSkillInFinder(_ skill: DiscoveredSkill) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.path)])
    }

    private func bootstrapIfNeeded() {
        try? layout.ensureDirectories()
        // 初回だけでなく、新しい組み込み Recipe も既存の利用者へ安全に追加する。
        // 同じ id の Recipe は上書きしないため、利用者の編集内容は保持される。
        let existingIDs = Set(recipeRepository.loadAll().map(\.id))
        for sample in SampleRecipes.all {
            if !existingIDs.contains(sample.id) {
                _ = try? recipeRepository.save(sample)
            }
        }
        try? settingsRepository.save(settings)
    }

    // MARK: - 一覧の切り口

    var filtered: [Recipe] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recipes }
        return recipes.filter { $0.matches(query) }
    }

    var favorites: [Recipe] { filtered.filter(\.favorite) }

    var recents: [Recipe] {
        recentIDs.compactMap { id in filtered.first { $0.id == id } }
    }

    var categories: [String] {
        Array(Set(filtered.compactMap { $0.category?.isEmpty == false ? $0.category : nil })).sorted()
    }

    func recipes(inCategory category: String) -> [Recipe] {
        filtered.filter { $0.category == category }
    }

    var uncategorized: [Recipe] {
        filtered.filter { ($0.category ?? "").isEmpty }
    }

    func recipes(forProject project: Project) -> [Recipe] {
        filtered.filter { $0.target.projectID == project.id }
    }

    func project(for recipe: Recipe) -> Project? {
        projectRepository.project(id: recipe.target.projectID)
    }

    // MARK: - 実行

    /// フォームを開くか。
    /// 通常は開かない。開くのは Recipe が明示的にそう設定されているときと ⌥ クリックだけ。
    func opensForm(_ recipe: Recipe) -> Bool {
        recipe.target.askProject
    }

    /// 引数の値が実行時に埋まらない Recipe か (Clipboard も既定値も無い)。
    /// 選択式の引数は画面で選べるので、ここでは「入力が要る」に数えない。
    func needsTyping(_ recipe: Recipe) -> Bool {
        let values = initialValues(for: recipe)
        return recipe.arguments.contains { argument in
            guard argument.required, (values[argument.name] ?? "").isEmpty else { return false }
            return !(argument.type == .choice && !argument.normalizedOptions.isEmpty)
        }
    }

    /// 実行前に選ばせたい引数があるか。
    func needsChoice(_ recipe: Recipe) -> Bool {
        let values = initialValues(for: recipe)
        return recipe.arguments.contains { argument in
            argument.type == .choice
                && !argument.normalizedOptions.isEmpty
                && (values[argument.name] ?? "").isEmpty
        }
    }

    /// ポップオーバー / 実行フォームを開いたタイミングで 1 回だけ読み、表示中は使い回す。
    func refreshClipboardSnapshot() {
        clipboardSnapshot = SystemClipboard().read()
        hasClipboardSnapshot = true
        initialValuesCache.removeAll()
    }

    /// クリックしたときに実際に行われるモード。引数が埋まらない Recipe は「チャットに入力」になる。
    func effectiveMode(_ recipe: Recipe) -> ExecutionMode {
        (recipe.mode == .submit && needsTyping(recipe)) ? .paste : recipe.mode
    }

    /// Recipe を選んだときの入口。
    ///
    /// - 実行 (submit): そのまま実行して結果を出す
    /// - チャットに入力 (paste): LLM のチャット欄に入れて前面に出す
    /// - 引数が埋まらないとき: フォームを出さず「チャットに入力」に切り替えて、編集は LLM 側でやってもらう
    /// - ⌥ クリック: 詳細フォーム (引数・送信先・Preview)
    func activate(_ recipe: Recipe, forceForm: Bool = false) {
        refreshClipboardSnapshot()
        let wantsDetails = forceForm || opensForm(recipe) || needsTyping(recipe)

        var mode = recipe.mode
        if needsTyping(recipe), mode == .submit, !wantsDetails {
            mode = .paste
        }

        // 実行前の確認がこの画面 1 つ。⌥ クリックや入力が要るときは詳細まで出す。
        let showsPreview = wantsDetails
            || (mode.requiresHerdr && (settings.previewBeforeRun || needsChoice(recipe)))
        if showsPreview {
            previewRequest = RunPreview(
                recipe: recipe,
                project: project(for: recipe),
                mode: mode,
                values: initialValues(for: recipe),
                showsDetails: wantsDetails
            )
            PanelPresenter.shared.showPreview(model: self)
            return
        }
        execute(recipe: recipe, values: [:], project: project(for: recipe), mode: mode, agent: nil)
    }

    /// プレビューから実行する。
    func runPreview(_ preview: RunPreview, mode: ExecutionMode? = nil) {
        previewRequest = nil
        PanelPresenter.shared.closePreview()
        execute(
            recipe: preview.recipe,
            values: preview.values.filter { !$0.value.isEmpty },
            project: preview.project,
            mode: mode ?? preview.mode,
            agent: agents.first { $0.id == preview.agentID },
            additionalPrompt: preview.additionalPrompt
        )
    }

    /// Recipe を編集しながら、実行前の確認画面の見え方を確かめる。
    func showFormPreview(_ recipe: Recipe) {
        refreshClipboardSnapshot()
        previewRequest = RunPreview(
            recipe: recipe,
            project: project(for: recipe),
            mode: recipe.mode.requiresHerdr ? recipe.mode : .submit,
            values: initialValues(for: recipe),
            isPreviewOnly: true
        )
        PanelPresenter.shared.showPreview(model: self)
    }

    func cancelPreview() {
        previewRequest = nil
        PanelPresenter.shared.closePreview()
    }

    /// 送信の実体。agent が指定されていればそこへ、無ければ Target Resolver に任せる。
    func execute(
        recipe: Recipe,
        values: [String: String],
        project: Project?,
        mode: ExecutionMode,
        agent: HerdrAgent?,
        additionalPrompt: String = ""
    ) {
        let runner = makeRunner()
        let notify = settings.notificationsEnabled
        // Submit のときだけ応答完了まで待てる (Paste / Copy は Agent を走らせない)。
        let waitMS: Int? = (mode == .submit && settings.waitForResult)
            ? settings.resultTimeoutSeconds * 1000
            : nil
        let pendingID = waitMS.map { _ in UUID() }
        if let pendingID { pendingResults.append(PendingResult(id: pendingID, recipeName: recipe.name)) }

        // 実行中であることを見せる。Submit は待ち時間が長いので特に必要。
        if mode.requiresHerdr {
            activeRun = ActiveRun(recipeName: recipe.name, mode: mode)
            PanelPresenter.shared.showResult(model: self)
        }
        let onStage: @Sendable (RunStage) -> Void = { stage in
            Task { @MainActor in self.activeRun?.stage = stage }
        }

        runTask?.cancel()
        runTask = Task {
            do {
                let outcome: RunOutcome = try await HerdrBackground.run {
                    if let agent {
                        let prompt = try runner.buildPrompt(
                            recipe: recipe,
                            values: values,
                            project: project,
                            additionalPrompt: additionalPrompt
                        )
                        return .completed(try runner.send(
                            prompt: prompt, recipe: recipe, mode: mode, agent: agent,
                            project: project, waitTimeoutMS: waitMS, progress: onStage
                        ))
                    }
                    return try runner.run(
                        recipe: recipe, values: values, project: project,
                        additionalPrompt: additionalPrompt,
                        modeOverride: mode, waitTimeoutMS: waitMS, progress: onStage
                    )
                }
                // 中止したあとに結果を出さない (Herdr の呼び出し自体は止められない)。
                guard !Task.isCancelled else { return }
                switch outcome {
                case .completed(let receipt):
                    self.finish(receipt, notify: notify, waited: waitMS != nil, pendingID: pendingID)
                }
            } catch {
                self.clearPending(pendingID)
                self.activeRun = nil
                guard !Task.isCancelled else { return }
                // 失敗の理由はトーストだと数秒で消えてしまうので、結果として残す。
                if mode.requiresHerdr {
                    self.result = RunResult(
                        recipeName: recipe.name,
                        agent: nil,
                        rawOutput: "",
                        failure: error.localizedDescription
                    )
                    PanelPresenter.shared.showResult(model: self)
                }
                ToastPresenter.shared.show(Toast(message: error.localizedDescription, isError: true))
            }
        }
    }

    /// 実行の待機をやめる。Herdr 側の Agent は動き続けるので、そのことも伝える。
    func cancelActiveRun() {
        guard activeRun != nil else { return }
        runTask?.cancel()
        runTask = nil
        activeRun = nil
        pendingResults.removeAll()
        ToastPresenter.shared.show(Toast(
            message: "待機をやめました。Agent は動き続けているので、Herdr で確認できます。",
            isError: false
        ))
    }

    /// 送信完了。待機していた場合は Agent の出力を読み取って結果ウィンドウに出す。
    private func finish(_ receipt: RunReceipt, notify: Bool, waited: Bool, pendingID: UUID?) {
        recentIDs = historyRepository.recentRecipeIDs(limit: 5)
        clearPending(pendingID)

        guard let agent = receipt.agent else {
            activeRun = nil
            if notify { ToastPresenter.shared.show(Toast(message: receipt.notificationText, isError: false)) }
            return
        }
        // 起動時の確認で止まっている場合は、待つ設定でなくても結果ウィンドウを出して答えてもらう。
        guard waited || !receipt.promptDelivered else {
            activeRun = nil
            if notify { ToastPresenter.shared.show(Toast(message: receipt.notificationText, isError: false)) }
            return
        }

        let client = makeClient()
        Task {
            let output = await HerdrBackground.run { (try? client.readPane(agent.paneID, lines: 200)) ?? "" }
            let result = RunResult(
                recipeName: receipt.recipeName,
                agent: agent,
                rawOutput: output,
                pendingPrompt: receipt.promptDelivered ? nil : receipt.prompt
            )
            self.activeRun = nil
            self.result = result
            PanelPresenter.shared.showResult(model: self)
            if notify {
                // 確認待ちで止まっている場合は、完了と伝えない。
                let message: String
                if !receipt.promptDelivered {
                    message = "\(receipt.recipeName) — 起動時の確認に答えると送信します"
                } else if result.question != nil {
                    message = "\(receipt.recipeName) — \(agent.displayName) が確認を求めています"
                } else {
                    message = "\(receipt.recipeName) — \(agent.displayName) の応答が完了しました"
                }
                ToastPresenter.shared.show(Toast(
                    message: message,
                    isError: !receipt.promptDelivered || result.question != nil
                ))
            }
        }
    }

    /// Agent の確認に答える。キーを送ってから、少し待って結果を読み直す。
    func answer(_ option: AgentQuestion.Option, for result: RunResult) {
        guard let pane = result.agent?.paneID else { return }
        sendToAgent(result: result) { client in
            try client.sendKeys(option.keys, toPane: pane)
        }
    }

    /// 確認に自由入力で答える。
    func answer(text: String, for result: RunResult) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pane = result.agent?.paneID else { return }
        sendToAgent(result: result) { client in
            try client.sendText(trimmed, toPane: pane)
            try client.sendKeys(["enter"], toPane: pane)
        }
    }

    /// 確認への回答を送り、画面が変わるのを少しだけ待って読み直す。
    ///
    /// ここで応答完了まで待たないのが重要。Agent が続けて確認してくると
    /// `agent wait --until idle` は帰ってこず、次の確認に気づけなくなる。
    /// 以降の変化はポーリングが拾う。
    private func sendToAgent(result: RunResult, _ action: @escaping @Sendable (HerdrClient) throws -> Void) {
        guard let agent = result.agent else { return }
        let client = makeClient()
        isAnswering = true
        Task {
            let output = await HerdrBackground.run { () -> String? in
                do {
                    try action(client)
                } catch {
                    return nil
                }
                // 画面が描き変わるまでの間だけ待つ。
                Thread.sleep(forTimeInterval: 1.5)
                return (try? client.readPane(agent.paneID, lines: 200)) ?? ""
            }
            self.isAnswering = false
            guard let output else {
                ToastPresenter.shared.show(Toast(message: "Agent へ送信できませんでした", isError: true))
                return
            }
            var updated = result
            updated.rawOutput = output
            updated.lastChangeAt = Date()
            self.result = updated
            // 送れていない Prompt があれば、確認が消えたことをポーリングが見て送る。
            self.startResultPolling()
        }
    }

    // MARK: - 結果の追従

    /// pane を読み直す間隔。
    static let resultPollInterval: Duration = .seconds(2)
    /// 結果ウィンドウを閉じているときの間隔。
    static let idlePollInterval: Duration = .seconds(5)

    /// 結果ウィンドウを開いているあいだ、表示中の結果を追いかける。
    ///
    /// 送信直後に 1 回読むだけでは、
    /// - Agent が続けて 2 つ目の確認を出した
    /// - 利用者が Herdr (tmux) 側で直接答えた
    /// といった変化にアプリが気づけない。
    func startResultPolling() {
        guard resultPollTask == nil else { return }
        resultPollTask = Task { @MainActor in
            while !Task.isCancelled {
                // 画面に出していないあいだは、間隔を空けて herdr の呼び出しを減らす。
                let visible = PanelPresenter.shared.isResultWindowOpen
                try? await Task.sleep(for: visible ? Self.resultPollInterval : Self.idlePollInterval)
                guard !Task.isCancelled else { break }
                let targets = pollTargets
                guard !targets.isEmpty else { break }
                for id in targets { await pollResult(id) }
            }
            resultPollTask = nil
        }
    }

    func stopResultPolling() {
        resultPollTask?.cancel()
        resultPollTask = nil
    }

    /// ウィンドウを閉じたあとも結果を追いかける時間 (最後に動きがあってから)。
    /// Agent は答えたあとに続けて確認してくることがある。
    static let backgroundWatchWindow: TimeInterval = 3 * 60

    /// 読み直す対象。
    /// - 表示中の結果 (ウィンドウを開いているとき)
    /// - まだ Prompt を送れていない結果 / 確認待ちの結果
    /// - 送信から間もない結果 (続けて確認してくることがあるため)
    private var pollTargets: [RunResult.ID] {
        var ids: [RunResult.ID] = []
        if PanelPresenter.shared.isResultWindowOpen, let current = result, current.agent != nil {
            ids.append(current.id)
        }
        for candidate in results where candidate.agent != nil && !ids.contains(candidate.id) {
            let watching = candidate.pendingPrompt != nil
                || candidate.question != nil
                || Date().timeIntervalSince(candidate.lastChangeAt) < Self.backgroundWatchWindow
            if watching { ids.append(candidate.id) }
        }
        return ids
    }

    /// 結果の pane を読み直し、変化があれば差し替える。
    private func pollResult(_ id: RunResult.ID) async {
        // 送信中・回答中は相手が読み書きしているので、次の周期に回す。
        guard !isAnswering, !isSendingPendingPrompt, activeRun == nil else { return }
        guard let current = results.first(where: { $0.id == id }), let agent = current.agent else { return }

        let client = makeClient()
        let output = await HerdrBackground.run {
            (try? client.readPane(agent.paneID, lines: 200)) ?? ""
        }
        guard !output.isEmpty else { return }
        // 読んでいるあいだに結果が消えていることがある。
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        guard results[index].rawOutput != output else { return }

        let previousQuestion = results[index].question
        results[index].rawOutput = output
        results[index].lastChangeAt = Date()
        let question = results[index].question

        // 質問文には経過秒数などが混ざるので、数字を落とした形で「別の確認か」を見る。
        // 文字列そのままで比べると、同じ確認に何度も反応してしまう。
        let signature = Self.questionSignature(question)
        if signature != nil, signature != Self.questionSignature(previousQuestion) {
            // 閉じているときだけ開き直す。開いていれば画面がそのまま確認カードに変わる。
            if !PanelPresenter.shared.isResultWindowOpen {
                selectedResultID = results[index].id
                PanelPresenter.shared.showResult(model: self)
            }
            if settings.notificationsEnabled {
                ToastPresenter.shared.show(Toast(
                    message: "\(results[index].recipeName) — \(agent.displayName) が確認を求めています",
                    isError: true
                ))
            }
        }
        // Herdr 側で起動時の確認に答えられた場合は、待っていた Prompt をここで送る。
        if question == nil, results[index].pendingPrompt != nil {
            sendPendingPrompt(for: results[index].id)
        }
    }

    /// 同じ確認かどうかを見るための指紋。経過時間などの数字は落とす。
    private static func questionSignature(_ question: AgentQuestion?) -> String? {
        guard let question else { return nil }
        let prompt = question.prompt.filter { !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        return prompt + "|" + question.options.map(\.id).joined(separator: ",")
    }

    /// 起動時の確認で送れなかった Prompt を、答えが済んだあとに送る。
    private func sendPendingPrompt(for id: RunResult.ID) {
        guard !isSendingPendingPrompt,
              let index = results.firstIndex(where: { $0.id == id }),
              let prompt = results[index].pendingPrompt,
              let agent = results[index].agent else { return }
        let recipeName = results[index].recipeName
        let client = makeClient()
        let notify = settings.notificationsEnabled
        isSendingPendingPrompt = true
        Task {
            let sent = await HerdrBackground.run { () -> Bool in
                let latest = client.waitUntilInteractive(target: agent.id)
                guard (latest?.status ?? "").lowercased() != "blocked" else { return false }
                do {
                    // 応答は待たない。待つとその間ポーリングが止まり、
                    // 次の確認に気づけなくなる (結果は読み直しで反映される)。
                    try client.promptAgent(prompt, target: agent.id)
                    return true
                } catch {
                    return false
                }
            }
            self.isSendingPendingPrompt = false
            guard sent, let index = self.results.firstIndex(where: { $0.id == id }) else { return }
            self.results[index].pendingPrompt = nil
            if notify {
                ToastPresenter.shared.show(Toast(
                    message: "\(recipeName) — 確認に答えられたので Prompt を送りました",
                    isError: false
                ))
            }
        }
    }

    /// 結果を読み直す。
    func refreshResult() {
        guard let result, let agent = result.agent else { return }
        let client = makeClient()
        isAnswering = true
        Task {
            let output = await HerdrBackground.run {
                (try? client.readPane(agent.paneID, lines: 200)) ?? ""
            }
            self.isAnswering = false
            var updated = result
            updated.rawOutput = output
            self.result = updated
        }
    }

    /// 履歴から結果を開き直す。閉じたら二度と見られない、という状態を避ける。
    func reopenResult(_ entry: HistoryEntry) {
        guard let paneID = entry.paneID else { return }
        guard let agent = agents.first(where: { $0.paneID == paneID }) else {
            ToastPresenter.shared.show(Toast(
                message: "この Agent はもう Herdr にありません",
                isError: true
            ))
            return
        }
        let client = makeClient()
        isAnswering = true
        Task {
            let output = await HerdrBackground.run { (try? client.readPane(paneID, lines: 200)) ?? "" }
            self.isAnswering = false
            self.result = RunResult(recipeName: entry.recipeName, agent: agent, rawOutput: output)
            PanelPresenter.shared.showResult(model: self)
        }
    }

    private func clearPending(_ id: UUID?) {
        guard let id, let index = pendingResults.firstIndex(where: { $0.id == id }) else { return }
        pendingResults.remove(at: index)
    }

    /// 結果ウィンドウから Herdr の該当 Agent を前面に出す。
    func focusInHerdr(_ agent: HerdrAgent) {
        let client = makeClient()
        Task { _ = await HerdrBackground.run { try? client.focusAgent(target: agent.id) } }
    }

    func preview(
        recipe: Recipe,
        values: [String: String],
        project: Project?,
        additionalPrompt: String = ""
    ) -> String {
        makeRunner(clipboard: SnapshotClipboard(value: clipboardValue())).preview(
            recipe: recipe,
            values: values,
            project: project,
            additionalPrompt: additionalPrompt
        )
    }

    func initialValues(for recipe: Recipe) -> [String: String] {
        if let cached = initialValuesCache[recipe.id] { return cached }
        let values = makeRunner(clipboard: SnapshotClipboard(value: clipboardValue())).initialValues(for: recipe)
        initialValuesCache[recipe.id] = values
        return values
    }

    /// フォームの送信先候補。Recipe の条件で絞ったものを優先して出す。
    func candidates(for recipe: Recipe, project: Project?) -> [HerdrAgent] {
        let filtered = TargetResolver().filter(
            agents: agents, target: recipe.target, project: project, agentKind: settings.agent
        )
        return filtered.isEmpty ? agents : filtered
    }

    // MARK: - 編集

    func save(_ recipe: Recipe, originalID: String?) {
        do {
            if let originalID, originalID != recipe.id {
                try recipeRepository.rename(id: originalID, to: recipe.id)
            }
            try recipeRepository.save(recipe)
            reload()
        } catch {
            ToastPresenter.shared.show(Toast(message: error.localizedDescription, isError: true))
        }
    }

    func delete(_ recipe: Recipe) {
        try? recipeRepository.delete(id: recipe.id)
        reload()
    }

    /// Finder で選んだローカルディレクトリを Project として追加する。
    @discardableResult
    func addWorkingDirectory() -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "追加"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let project = try projectRepository.add(name: url.lastPathComponent, path: url.path)
            projects = projectRepository.load()
            return project
        } catch {
            ToastPresenter.shared.show(Toast(message: error.localizedDescription, isError: true))
            return nil
        }
    }

    func saveProjects() {
        try? projectRepository.save(projects)
        reload()
    }

    func scheduleSettingsSave(rescanSkills: Bool = false) {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveSettings()
            if rescanSkills { self.reloadSkills() }
        }
    }

    func saveSettings() {
        let previous = appliedSettings
        try? settingsRepository.save(settings)
        if previous.recipesDirectory != settings.recipesDirectory {
            // Recipe ディレクトリの差し替えにだけ再読込が必要。
            layout = StorageLayout(recipesDirectory: settings.recipesDirectory)
            recipeRepository = RecipeRepository(layout: layout)
            projectRepository = ProjectRepository(layout: layout)
            historyRepository = HistoryRepository(layout: layout, limit: settings.historyLimit)
            reload()
        } else if previous.historyLimit != settings.historyLimit {
            historyRepository = HistoryRepository(layout: layout, limit: settings.historyLimit)
        }
        if previous.launchAtLogin != settings.launchAtLogin {
            LoginItem.setEnabled(settings.launchAtLogin)
        }
        if previous.herdrExecutablePath != settings.herdrExecutablePath {
            refreshHerdr()
        }
        if previous.showInDock != settings.showInDock {
            // Dock の表示は起動しなおさなくても切り替わる。
            (NSApp.delegate as? AppDelegate)?.applyActivationPolicy(showInDock: settings.showInDock)
        }
        appliedSettings = settings
    }

    // MARK: - 依存の組み立て

    private func makeClient() -> HerdrClient {
        HerdrClient(
            executablePath: settings.herdrExecutablePath,
            log: DebugLog(layout: layout, enabled: settings.debugLogging)
        )
    }

    private func makeRunner(clipboard: ClipboardAccess = SystemClipboard()) -> RecipeRunner {
        RecipeRunner(
            client: makeClient(),
            agentKind: settings.agent,
            defaultWorkingDirectory: settings.ensureDefaultWorkingDirectory(),
            clipboard: clipboard,
            history: historyRepository
        )
    }

    private func clipboardValue() -> String {
        if !hasClipboardSnapshot { refreshClipboardSnapshot() }
        return clipboardSnapshot
    }
}

struct PendingResult: Identifiable, Equatable {
    let id: UUID
    let recipeName: String
}

private struct SnapshotClipboard: ClipboardAccess {
    let value: String
    func read() -> String { value }
    func write(_: String) {}
}

/// Process.waitUntilExit などの同期 API を Swift Concurrency の協調プールから隔離する。
private enum HerdrBackground {
    private static let queue = DispatchQueue(label: "dev.agentrecipes.herdr", qos: .userInitiated, attributes: .concurrent)

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }
}

/// Submit の応答結果。
/// 実行中の Recipe。
struct ActiveRun: Identifiable {
    let id = UUID()
    var recipeName: String
    var mode: ExecutionMode
    var stage: RunStage = .buildingPrompt
    var startedAt = Date()
}

/// 実行前の確認。⌥ クリックの詳細指定もこの画面で行う。
struct RunPreview: Identifiable {
    let id = UUID()
    var recipe: Recipe
    var project: Project?
    var mode: ExecutionMode
    /// 解決済みの引数。この画面で編集できる。
    var values: [String: String] = [:]
    /// Skill が受け付ける場合の補足プロンプト。
    var additionalPrompt: String = ""
    /// 送信先を明示するときの pane id。空なら自動で決める。
    var agentID: String = ""
    /// すべての入力欄と送信先を出す (⌥ クリック / Project を選ぶ Recipe)。
    var showsDetails = false
    /// 編集中に見え方を確かめるだけのプレビュー。実行はしない。
    var isPreviewOnly = false

    /// 画面に出す引数。通常は選択式だけ、詳細表示ではすべて。
    var editableArguments: [ArgumentSpec] {
        showsDetails ? recipe.arguments : choices
    }

    /// 選択肢を持つ引数。
    var choices: [ArgumentSpec] {
        recipe.arguments.filter { $0.type == .choice && !$0.normalizedOptions.isEmpty }
    }
}

struct RunResult: Identifiable {
    let id = UUID()
    var recipeName: String
    /// 送信先。実行そのものに失敗した場合は決まっていない。
    var agent: HerdrAgent?
    /// pane から読んだ全文。リッチ結果の JSON はここから読む。
    var rawOutput: String
    /// まだ届いていない Prompt。起動時の確認に答えたあとで送る。
    var pendingPrompt: String?
    /// 実行に失敗した理由。トーストだけだと消えてしまうので結果として残す。
    var failure: String?
    var finishedAt = Date()
    /// 最後に画面が変わった時刻。しばらく動きがなければ読み直しをやめる。
    var lastChangeAt = Date()

    /// Agent が確認待ちで止まっている場合の質問。
    var question: AgentQuestion? {
        guard failure == nil, agent != nil else { return nil }
        return AgentQuestionParser.parse(rawOutput)
    }

    /// リッチ結果は切り詰めると JSON が壊れるので、全文から解析する。
    var presentation: ResultPresentation {
        if let failure { return .plain(failure) }
        return RichResultParser.parse(rawOutput)
    }

    var isRich: Bool {
        if case .rich = presentation { return true }
        return false
    }

    /// 表示・コピー用のテキスト。プレーン表示のときだけ末尾のやり取りに絞る。
    var output: String {
        if let failure { return failure }
        return isRich ? rawOutput : RunResult.trimToLastAnswer(rawOutput)
    }

    /// pane 全体ではなく、最後のやり取りだけを見せる。
    static func trimToLastAnswer(_ output: String) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // 末尾の入力欄とステータスバー (区切り線に挟まれた部分) は答えではないので落とす。
        let isSeparator: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).hasPrefix("────") }
        if let last = lines.lastIndex(where: isSeparator) {
            let head = lines[..<last]
            lines = Array(head.lastIndex(where: isSeparator).map { Array(lines[..<$0]) } ?? Array(head))
        }

        // 起動直後のセッションでは Welcome バナーが残るので、その枠の後ろだけを見る。
        if let banner = lines.lastIndex(where: { $0.contains("╰") || $0.contains("╯") }) {
            lines = Array(lines[lines.index(after: banner)...])
        }

        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.suffix(80).joined(separator: "\n")
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool
}
