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

    @Published var runRequest: RunRequest?
    /// Submit の応答結果。Result ウィンドウが参照する。
    @Published var result: RunResult?
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

    /// MCP の接続状況を調べ直す。CLI の health check を待つので数秒かかる。
    /// - Parameter agent: nil ならすべての LLM。
    func refreshMCP(agent: AgentKind? = nil) {
        let targets = agent.map { [$0] } ?? AgentKind.allCases
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
    func needsTyping(_ recipe: Recipe) -> Bool {
        let values = initialValues(for: recipe)
        return recipe.arguments.contains { argument in
            argument.required && (values[argument.name] ?? "").isEmpty
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
        if forceForm || opensForm(recipe) {
            runRequest = RunRequest(recipe: recipe, project: project(for: recipe))
            PanelPresenter.shared.showRunForm(model: self)
            return
        }

        var mode = recipe.mode
        if needsTyping(recipe), mode == .submit {
            mode = .paste
            ToastPresenter.shared.show(Toast(
                message: "\(recipe.name): 入力が必要なのでチャットに入れました。続きは LLM 側で編集してください",
                isError: false
            ))
        }
        execute(recipe: recipe, values: [:], project: project(for: recipe), mode: mode, agent: nil)
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

        Task {
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
                            project: project, waitTimeoutMS: waitMS
                        ))
                    }
                    return try runner.run(
                        recipe: recipe, values: values, project: project,
                        additionalPrompt: additionalPrompt,
                        modeOverride: mode, waitTimeoutMS: waitMS
                    )
                }
                switch outcome {
                case .completed(let receipt):
                    self.finish(receipt, notify: notify, waited: waitMS != nil, pendingID: pendingID)
                }
            } catch {
                self.clearPending(pendingID)
                ToastPresenter.shared.show(Toast(message: error.localizedDescription, isError: true))
            }
        }
    }

    /// 送信完了。待機していた場合は Agent の出力を読み取って結果ウィンドウに出す。
    private func finish(_ receipt: RunReceipt, notify: Bool, waited: Bool, pendingID: UUID?) {
        recentIDs = historyRepository.recentRecipeIDs(limit: 5)
        PanelPresenter.shared.closeRunForm()
        clearPending(pendingID)

        guard waited, let agent = receipt.agent else {
            if notify { ToastPresenter.shared.show(Toast(message: receipt.notificationText, isError: false)) }
            return
        }

        let client = makeClient()
        Task {
            let output = await HerdrBackground.run { (try? client.readPane(agent.paneID, lines: 200)) ?? "" }
            self.result = RunResult(
                recipeName: receipt.recipeName,
                agent: agent,
                output: RunResult.trimToLastAnswer(output)
            )
            PanelPresenter.shared.showResult(model: self)
            if notify {
                ToastPresenter.shared.show(Toast(
                    message: "\(receipt.recipeName) — \(agent.displayName) の応答が完了しました",
                    isError: false
                ))
            }
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
struct RunResult: Identifiable {
    let id = UUID()
    var recipeName: String
    var agent: HerdrAgent
    var output: String

    var isRich: Bool {
        if case .rich = RichResultParser.parse(output) { return true }
        return false
    }

    /// pane 全体ではなく、最後のやり取りだけを見せる。
    static func trimToLastAnswer(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 区切り線 (─────) の最後の塊以降を答えとみなす。
        if let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("────") }),
           index > 0 {
            let head = lines[..<index].suffix(60)
            return (head + lines[index...]).joined(separator: "\n")
        }
        return lines.suffix(60).joined(separator: "\n")
    }
}

struct RunRequest: Identifiable {
    let id = UUID()
    var recipe: Recipe
    var project: Project?
    var values: [String: String] = [:]
    var additionalPrompt: String = ""
    var modeOverride: ExecutionMode?
    /// フォームで送信先を選ぶときの候補。
    var candidates: [HerdrAgent] = []
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool
}
