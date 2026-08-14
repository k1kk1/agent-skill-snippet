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
    @Published private(set) var connection: HerdrConnectionStatus = .notInstalled

    @Published var runRequest: RunRequest?
    /// Submit の応答結果。Result ウィンドウが参照する。
    @Published var result: RunResult?
    /// 応答待ちの Recipe 名 (メニューに出す)。
    @Published private(set) var pendingResults: [String] = []

    private(set) var layout: StorageLayout
    private(set) var recipeRepository: RecipeRepository
    private(set) var projectRepository: ProjectRepository
    private let settingsRepository: SettingsRepository
    private(set) var historyRepository: HistoryRepository

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
        Task.detached(priority: .utility) {
            let status = client.connectionStatus()
            let agents = (try? client.listAgents()) ?? []
            await MainActor.run {
                self.connection = status
                self.agents = agents
            }
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
        guard RecipeRepository(layout: layout).loadAll().isEmpty else { return }
        for sample in SampleRecipes.all {
            _ = try? recipeRepository.save(sample)
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
        recipe.target.askProject || recipe.target.session == .ask
    }

    /// 引数の値が実行時に埋まらない Recipe か (Clipboard も既定値も無い)。
    func needsTyping(_ recipe: Recipe) -> Bool {
        let values = initialValues(for: recipe)
        return recipe.arguments.contains { argument in
            argument.required && (values[argument.name] ?? "").isEmpty
        }
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
        agent: HerdrAgent?
    ) {
        let runner = makeRunner()
        let notify = settings.notificationsEnabled
        // Submit のときだけ応答完了まで待てる (Paste / Copy は Agent を走らせない)。
        let waitMS: Int? = (mode == .submit && settings.waitForResult)
            ? settings.resultTimeoutSeconds * 1000
            : nil
        if waitMS != nil { pendingResults.append(recipe.name) }

        Task.detached(priority: .userInitiated) {
            do {
                if let agent {
                    let prompt = try runner.buildPrompt(recipe: recipe, values: values, project: project)
                    let receipt = try runner.send(
                        prompt: prompt, recipe: recipe, mode: mode, agent: agent,
                        project: project, waitTimeoutMS: waitMS
                    )
                    await MainActor.run { self.finish(receipt, notify: notify, waited: waitMS != nil) }
                    return
                }

                let outcome = try runner.run(
                    recipe: recipe, values: values, project: project,
                    modeOverride: mode, waitTimeoutMS: waitMS
                )
                switch outcome {
                case .completed(let receipt):
                    await MainActor.run { self.finish(receipt, notify: notify, waited: waitMS != nil) }

                case .needsTarget(_, let candidates, let reason):
                    // 送信先が決まらなかったので、フォームで選ばせる。
                    await MainActor.run {
                        self.agents = candidates.isEmpty ? self.agents : candidates
                        self.runRequest = RunRequest(
                            recipe: recipe,
                            project: project,
                            values: values,
                            modeOverride: mode,
                            candidates: candidates,
                            reason: reason
                        )
                        PanelPresenter.shared.showRunForm(model: self)
                        if candidates.isEmpty {
                            ToastPresenter.shared.show(Toast(
                                message: TargetPrompt.describe(reason), isError: true
                            ))
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.clearPending(recipe.name)
                    ToastPresenter.shared.show(Toast(message: error.localizedDescription, isError: true))
                }
            }
        }
    }

    /// 送信完了。待機していた場合は Agent の出力を読み取って結果ウィンドウに出す。
    private func finish(_ receipt: RunReceipt, notify: Bool, waited: Bool) {
        recentIDs = historyRepository.recentRecipeIDs(limit: 5)
        PanelPresenter.shared.closeRunForm()
        clearPending(receipt.recipeName)

        guard waited, let agent = receipt.agent else {
            if notify { ToastPresenter.shared.show(Toast(message: receipt.notificationText, isError: false)) }
            return
        }

        let client = makeClient()
        Task.detached(priority: .utility) {
            let output = (try? client.readPane(agent.paneID, lines: 200)) ?? ""
            await MainActor.run {
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
    }

    private func clearPending(_ name: String) {
        if let index = pendingResults.firstIndex(of: name) { pendingResults.remove(at: index) }
    }

    /// 結果ウィンドウから Herdr の該当 Agent を前面に出す。
    func focusInHerdr(_ agent: HerdrAgent) {
        let client = makeClient()
        Task.detached(priority: .utility) { try? client.focusAgent(target: agent.id) }
    }

    func preview(recipe: Recipe, values: [String: String], project: Project?) -> String {
        makeRunner().preview(recipe: recipe, values: values, project: project)
    }

    func initialValues(for recipe: Recipe) -> [String: String] {
        makeRunner().initialValues(for: recipe)
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

    func saveProjects() {
        try? projectRepository.save(projects)
        reload()
    }

    func saveSettings() {
        try? settingsRepository.save(settings)
        // Recipe ディレクトリの差し替えに追随する。
        layout = StorageLayout(recipesDirectory: settings.recipesDirectory)
        recipeRepository = RecipeRepository(layout: layout)
        projectRepository = ProjectRepository(layout: layout)
        historyRepository = HistoryRepository(layout: layout, limit: settings.historyLimit)
        LoginItem.setEnabled(settings.launchAtLogin)
        reload()
        refreshHerdr()
    }

    // MARK: - 依存の組み立て

    private func makeClient() -> HerdrClient {
        HerdrClient(
            executablePath: settings.herdrExecutablePath,
            log: DebugLog(layout: layout, enabled: settings.debugLogging)
        )
    }

    private func makeRunner() -> RecipeRunner {
        RecipeRunner(client: makeClient(), agentKind: settings.agent, history: historyRepository)
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
    var modeOverride: ExecutionMode?
    /// 送信先を選ばせる必要がある場合の候補。
    var candidates: [HerdrAgent] = []
    var reason: TargetResolution.AskReason?
}

enum TargetPrompt {
    static func describe(_ reason: TargetResolution.AskReason) -> String {
        switch reason {
        case .strategyIsAsk: return "送信先を選んでください"
        case .notFound: return "条件に合う Agent が見つかりません"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool
}
