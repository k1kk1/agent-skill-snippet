import Foundation
import AgentRecipesCore
import HerdrKit

// GUI と同じ Recipe Engine (Core + HerdrKit) を呼ぶだけの CLI。
// 実行ロジックはここには持たせない。

let cli = CLI(arguments: Array(CommandLine.arguments.dropFirst()))
exit(cli.run())

struct CLI {
    let arguments: [String]

    private let settingsRepo: SettingsRepository
    private let layout: StorageLayout
    private let recipes: RecipeRepository
    private let projects: ProjectRepository
    private let settings: AppSettings

    init(arguments: [String]) {
        self.arguments = arguments
        let base = StorageLayout()
        let settings = SettingsRepository(layout: base).load()
        self.settings = settings
        self.layout = StorageLayout(recipesDirectory: settings.recipesDirectory)
        self.settingsRepo = SettingsRepository(layout: layout)
        self.recipes = RecipeRepository(layout: layout)
        self.projects = ProjectRepository(layout: layout)
    }

    func run() -> Int32 {
        guard let command = arguments.first else {
            printUsage()
            return 1
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "list", "ls": return try list(rest)
            case "show": return try show(rest)
            case "preview": return try preview(rest)
            case "run": return try execute(rest, forcedMode: nil)
            case "copy": return try execute(rest, forcedMode: .copy)
            case "paste": return try execute(rest, forcedMode: .paste)
            case "submit": return try execute(rest, forcedMode: .submit)
            case "skills": return skills(rest)
            case "agents": return agents()
            case "panes": return panes()
            case "workspaces": return workspaces()
            case "projects": return try projectsCommand(rest)
            case "status": return status()
            case "history": return history(rest)
            case "init": return try initialize(rest)
            case "path": print(layout.root.path); return 0
            case "help", "--help", "-h": printUsage(); return 0
            case "version", "--version": print("agentrecipes 0.2.0 (schema \(Recipe.currentSchemaVersion))"); return 0
            default:
                fail("不明なコマンド: \(command)")
                printUsage()
                return 1
            }
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    // MARK: - Recipe

    private func list(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        var all = recipes.loadAll()
        if let query = opts.positional.first { all = all.filter { $0.matches(query) } }
        if opts.flag("favorites") { all = all.filter(\.favorite) }
        if let category = opts.value("category") { all = all.filter { $0.category == category } }

        if opts.flag("json") {
            let data = try JSONCoding.encoder.encode(all)
            FileHandle.standardOutput.write(data)
            print("")
            return 0
        }
        guard !all.isEmpty else {
            print("Recipe がありません。`agentrecipes init` でサンプルを作成できます。")
            return 0
        }
        let width = all.map(\.id.count).max() ?? 10
        for recipe in all {
            let star = recipe.favorite ? "★" : " "
            let id = recipe.id.padding(toLength: max(width, recipe.id.count), withPad: " ", startingAt: 0)
            let args = recipe.arguments.isEmpty ? "" : "  <\(recipe.arguments.map(\.name).joined(separator: ", "))>"
            print("\(star) \(id)  \(recipe.mode.displayName.padding(toLength: 6, withPad: " ", startingAt: 0))  \(recipe.name)\(args)")
        }
        return 0
    }

    private func show(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        guard let id = opts.positional.first else { throw CLIError.missingRecipeID }
        let recipe = try resolveRecipe(id)
        print("id:          \(recipe.id)")
        print("name:        \(recipe.name)")
        if let d = recipe.description { print("description: \(d)") }
        print("mode:        \(recipe.mode.rawValue)")
        print("session:     \(recipe.target.session.displayName)")
        print("agent:       \(settings.agent.displayName)  (設定で切り替え)")
        print("project:     \(projects.project(id: recipe.target.projectID)?.name ?? "(none)")")
        print("skill:       \(recipe.skill?.displayName ?? "(none)")")
        print("result:      \(recipe.resultFormat.displayName)")
        if !recipe.arguments.isEmpty {
            print("arguments:")
            for argument in recipe.arguments {
                print("  --\(argument.name)  (\(argument.type.rawValue), \(argument.required ? "required" : "optional"))")
            }
        }
        print("---")
        print(recipe.template)
        return 0
    }

    private func preview(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        guard let id = opts.positional.first else { throw CLIError.missingRecipeID }
        let recipe = try resolveRecipe(id)
        let builder = PromptBuilder()
        var values = builder.initialValues(for: recipe)
        for (key, value) in opts.namedValues(excluding: Options.reservedKeys) { values[key] = value }
        print(builder.preview(recipe: recipe, userValues: values, project: project(for: recipe, opts: opts)))
        return 0
    }

    private func execute(_ args: [String], forcedMode: ExecutionMode?) throws -> Int32 {
        let opts = Options(args)
        guard let id = opts.positional.first else { throw CLIError.missingRecipeID }
        let recipe = try resolveRecipe(id)

        let runner = makeRunner()
        var values = runner.initialValues(for: recipe)
        for (key, value) in opts.namedValues(excluding: Options.reservedKeys) { values[key] = value }
        values = values.filter { key, _ in recipe.arguments.contains { $0.name == key } }

        let mode = forcedMode ?? opts.value("mode").flatMap(ExecutionMode.init(rawValue:)) ?? recipe.mode
        // --wait は Submit のときだけ意味がある (Paste/Copy は Agent を走らせない)。
        let waitTimeout: Int? = (opts.flag("wait") && mode == .submit)
            ? (opts.value("timeout").flatMap(Int.init) ?? 300_000)
            : nil
        let selectedProject = project(for: recipe, opts: opts)

        // --agent が指定されていれば自動解決より優先する。
        if let wanted = opts.value("agent") {
            let agents = try makeClient().listAgents()
            guard let agent = agents.first(where: { $0.id == wanted })
                ?? agents.first(where: { $0.agentName == wanted }) else {
                fail("Agent '\(wanted)' が見つかりません")
                return 1
            }
            let prompt = try runner.buildPrompt(recipe: recipe, values: values, project: selectedProject)
            if waitTimeout != nil {
                FileHandle.standardError.write(Data("… \(agent.displayName) の応答を待っています\n".utf8))
            }
            let receipt = try runner.send(
                prompt: prompt, recipe: recipe, mode: mode, agent: agent,
                project: selectedProject, waitTimeoutMS: waitTimeout
            )
            print(receipt.notificationText)
            if waitTimeout != nil { return printPaneOutput(agent: agent) }
            return 0
        }

        let outcome = try runner.run(
            recipe: recipe, values: values, project: selectedProject,
            modeOverride: mode, waitTimeoutMS: waitTimeout
        )
        switch outcome {
        case .completed(let receipt):
            print(receipt.notificationText)
            if waitTimeout != nil, let agent = receipt.agent {
                return printPaneOutput(agent: agent)
            }
            return 0

        case .needsTarget(let prompt, let candidates, let reason):
            // CLI では対話的に選ばせず、--agent で 1 件に決まる場合だけ送る。
            if let wanted = opts.value("agent"),
               let agent = candidates.first(where: { $0.id == wanted || $0.agentName == wanted }) {
                let receipt = try runner.send(
                    prompt: prompt, recipe: recipe, mode: mode, agent: agent,
                    project: selectedProject, waitTimeoutMS: waitTimeout
                )
                print(receipt.notificationText)
                if waitTimeout != nil { return printPaneOutput(agent: agent) }
                return 0
            }
            fail(describe(reason))
            guard !candidates.isEmpty else { return 1 }
            print("候補:")
            for agent in candidates {
                print("  \(agent.id)  \(agent.displayName)  \(agent.status ?? "-")")
            }
            print("--agent <id> で送信先を指定してください。")
            return 1
        }
    }

    /// 応答が落ち着いたあとの pane 出力を表示する。
    private func printPaneOutput(agent: HerdrAgent) -> Int32 {
        let client = makeClient()
        do {
            print("")
            print(try client.readPane(agent.paneID, lines: 200))
            if let status = (try? client.agent(target: agent.id))?.status {
                FileHandle.standardError.write(Data("status: \(status)\n".utf8))
            }
            return 0
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    private func describe(_ reason: TargetResolution.AskReason) -> String {
        switch reason {
        case .strategyIsAsk: return "この Recipe は送信先を毎回選ぶ設定です"
        case .notFound: return "条件に合う Agent が見つかりません"
        }
    }

    // MARK: - Skills

    private func skills(_ args: [String]) -> Int32 {
        let opts = Options(args)
        var found = SkillScanner().scan(sources: settings.skillSources)
        if let query = opts.positional.first { found = found.filter { $0.matches(query) } }

        if let target = opts.value("open") ?? (opts.flag("open") ? opts.positional.first : nil) {
            guard let skill = found.first(where: { $0.name == target })
                ?? found.first(where: { $0.matches(target) }) else {
                fail("Skill '\(target)' が見つかりません")
                return 1
            }
            if SkillOpener(command: settings.editorCommand).open(path: skill.path) {
                print("開きました: \(skill.path)")
            } else {
                // エディタが見つからないときはパスだけ返す。
                print(skill.path)
            }
            return 0
        }

        if opts.flag("json") {
            struct Row: Encodable { let name: String; let description: String?; let source: String; let path: String }
            let rows = found.map { Row(name: $0.name, description: $0.description, source: $0.source, path: $0.path) }
            if let data = try? JSONCoding.encoder.encode(rows) {
                FileHandle.standardOutput.write(data)
                print("")
            }
            return 0
        }

        guard !found.isEmpty else {
            print("Skill が見つかりません。Settings の Skill Sources を確認してください。")
            for source in settings.skillSources { print("  \(source.name): \(source.path)") }
            return 0
        }
        let width = found.map(\.name.count).max() ?? 10
        for skill in found {
            let name = skill.name.padding(toLength: max(width, skill.name.count), withPad: " ", startingAt: 0)
            let description = skill.description.map { " — " + $0.prefix(70) } ?? ""
            print("[\(skill.source)] \(name)\(description)")
        }
        print("")
        print("`agentrecipes skills --open <name>` で SKILL.md をエディタで開きます。")
        return 0
    }

    // MARK: - Herdr

    private func agents() -> Int32 {
        do {
            let agents = try makeClient().listAgents()
            guard !agents.isEmpty else { print("Agent がいません"); return 0 }
            for agent in agents {
                print("\(agent.id)  \(agent.displayName)  \(agent.status ?? "-")")
            }
            return 0
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    private func panes() -> Int32 {
        do {
            for pane in try makeClient().listPanes() {
                print("\(pane.id)  \(pane.displayName)  \(pane.cwd ?? "-")")
            }
            return 0
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    private func workspaces() -> Int32 {
        do {
            for workspace in try makeClient().listWorkspaces() {
                print("\(workspace.id)  \(workspace.displayName)  panes=\(workspace.paneCount ?? 0)")
            }
            return 0
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    private func status() -> Int32 {
        let client = makeClient()
        print("herdr:  \(client.executablePath ?? "(not found)")")
        let status = client.connectionStatus()
        print("status: \(status.displayText)")
        print("agent:  \(settings.agent.displayName)")
        print("store:  \(layout.root.path)")
        return status.isHealthy ? 0 : 1
    }

    // MARK: - Project / History / init

    private func projectsCommand(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        if let path = opts.value("add") {
            let expanded = (path as NSString).expandingTildeInPath
            let name = opts.value("name") ?? (expanded as NSString).lastPathComponent
            let project = try projects.add(name: name, path: path)
            print("追加しました: \(project.name)  \(project.path)")
            return 0
        }
        let all = projects.load()
        guard !all.isEmpty else {
            print("Project がありません。`agentrecipes projects --add ~/src/foo` で追加できます。")
            return 0
        }
        for project in all {
            print("\(project.id)  \(project.name)  \(project.path)")
        }
        return 0
    }

    private func history(_ args: [String]) -> Int32 {
        let opts = Options(args)
        let limit = opts.value("limit").flatMap(Int.init) ?? 20
        let entries = HistoryRepository(layout: layout, limit: settings.historyLimit).recent(limit: limit)
        guard !entries.isEmpty else {
            print("履歴がありません")
            return 0
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        for entry in entries {
            let mark = entry.result == .success ? " " : "!"
            print("\(mark) \(formatter.string(from: entry.timestamp))  \(entry.recipeName)  \(entry.project ?? "-")  \(entry.agent ?? "-")  \(entry.mode.rawValue)")
        }
        return 0
    }

    private func initialize(_ args: [String]) throws -> Int32 {
        let opts = Options(args)
        try layout.ensureDirectories()
        try settingsRepo.save(settingsRepo.load())

        var created = 0
        for sample in SampleRecipes.all {
            let exists = FileManager.default.fileExists(atPath: layout.directory(for: sample.id).path)
            if exists, !opts.flag("force") { continue }
            try recipes.save(sample)
            created += 1
        }
        print("\(layout.root.path) を初期化しました (Recipe \(created) 件)")
        return 0
    }

    // MARK: - ヘルパ

    private func makeClient() -> HerdrClient {
        HerdrClient(
            executablePath: settings.herdrExecutablePath,
            log: DebugLog(layout: layout, enabled: settings.debugLogging)
        )
    }

    private func makeRunner() -> RecipeRunner {
        RecipeRunner(
            client: makeClient(),
            agentKind: settings.agent,
            history: HistoryRepository(layout: layout, limit: settings.historyLimit)
        )
    }

    private func project(for recipe: Recipe, opts: Options) -> Project? {
        if let name = opts.value("project") {
            let all = projects.load()
            if let match = all.first(where: { $0.id == name || $0.name == name }) { return match }
            // 未登録のパスを直接指定された場合も受け付ける。
            return Project(name: (name as NSString).lastPathComponent, path: name)
        }
        return projects.project(id: recipe.target.projectID)
    }

    private func resolveRecipe(_ query: String) throws -> Recipe {
        if let exact = try? recipes.load(id: query) { return exact }
        let all = recipes.loadAll()
        let prefixed = all.filter { $0.id.hasPrefix(query) }
        let matches = prefixed.isEmpty ? all.filter { $0.matches(query) } : prefixed
        switch matches.count {
        case 0: throw StorageError.recipeNotFound(query)
        case 1: return matches[0]
        default: throw CLIError.ambiguous(query, matches.map(\.id))
        }
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    }

    private func printUsage() {
        print("""
        agentrecipes — Herdr 上の Agent へ Recipe を投げる CLI

        USAGE
          agentrecipes list [query] [--favorites] [--category <name>] [--json]
          agentrecipes show <recipe>
          agentrecipes preview <recipe> [--<arg> <value> ...] [--project <name|path>]
          agentrecipes run <recipe> [--<arg> <value> ...] [--mode copy|paste|submit]
                                    [--project <name|path>] [--agent <id|kind>]
                                    [--wait] [--timeout <ms>]
          agentrecipes copy|paste|submit <recipe> [--<arg> <value> ...]
          agentrecipes skills [query] [--open <name>] [--json]
          agentrecipes agents | panes | workspaces | status
          agentrecipes projects [--add <path> [--name <name>]]
          agentrecipes history [--limit <n>]
          agentrecipes init [--force]
          agentrecipes path

        EXAMPLES
          agentrecipes run review-diff --project ComposerSketch
          agentrecipes run web-research --url https://example.com --focus "API仕様"
          agentrecipes copy review-clipboard
          agentrecipes submit web-research --wait        # 応答が終わるまで待って結果を表示
        """)
    }
}

enum CLIError: LocalizedError {
    case missingRecipeID
    case ambiguous(String, [String])

    var errorDescription: String? {
        switch self {
        case .missingRecipeID: return "Recipe を指定してください"
        case .ambiguous(let query, let ids):
            return "'\(query)' は複数の Recipe に一致します: \(ids.joined(separator: ", "))"
        }
    }
}

/// `--key value` / `--flag` / 位置引数 を扱う最小限のパーサ。
struct Options {
    private(set) var positional: [String] = []
    private var named: [String: String] = [:]
    private var flags: Set<String> = []

    static let reservedKeys: Set<String> = [
        "mode", "project", "agent", "json", "favorites", "category", "limit", "force", "add", "name",
        "wait", "timeout", "open",
    ]

    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            let token = args[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                let next = index + 1 < args.count ? args[index + 1] : nil
                if let next, !next.hasPrefix("--") {
                    named[key] = next
                    index += 2
                    continue
                }
                flags.insert(key)
            } else {
                positional.append(token)
            }
            index += 1
        }
    }

    func value(_ key: String) -> String? { named[key] }

    func flag(_ key: String) -> Bool {
        if flags.contains(key) { return true }
        guard let raw = named[key] else { return false }
        return ["true", "yes", "1"].contains(raw.lowercased())
    }

    func namedValues(excluding excluded: Set<String>) -> [String: String] {
        named.filter { !excluded.contains($0.key) }
    }
}
