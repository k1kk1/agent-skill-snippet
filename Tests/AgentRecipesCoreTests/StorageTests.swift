import XCTest
@testable import AgentRecipesCore

final class StorageTests: XCTestCase {
    private var root: URL!
    private var layout: StorageLayout!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentrecipes-tests-\(UUID().uuidString)")
        layout = StorageLayout(root: root)
        try layout.ensureDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDefaultStoreLivesInApplicationSupport() throws {
        // 環境変数が無い前提の既定値を確認する。
        guard ProcessInfo.processInfo.environment["AGENTRECIPES_HOME"] == nil else {
            throw XCTSkip("AGENTRECIPES_HOME が設定されているためスキップ")
        }
        let layout = StorageLayout()
        XCTAssertTrue(layout.root.path.hasSuffix("Application Support/AgentRecipes"), layout.root.path)
        XCTAssertEqual(layout.settingsFile.lastPathComponent, "settings.json")
        XCTAssertEqual(layout.projectsFile.lastPathComponent, "projects.json")
    }

    func testRecipesDirectoryCanBeOverridden() {
        let custom = StorageLayout(root: root, recipesDirectory: root.appendingPathComponent("elsewhere").path)
        XCTAssertEqual(custom.recipesDirectory.lastPathComponent, "elsewhere")
        XCTAssertEqual(custom.settingsFile, root.appendingPathComponent("settings.json"))
    }

    func testPromptIsStoredAsSeparateMarkdownFile() throws {
        let repo = RecipeRepository(layout: layout)
        try repo.save(SampleRecipes.webResearch)

        let dir = layout.directory(for: "web-research")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("prompt.md").path))

        let json = try String(contentsOf: dir.appendingPathComponent("recipe.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"schemaVersion\" : 3"))
        XCTAssertFalse(json.contains("調査してください"))

        let loaded = try repo.load(id: "web-research")
        XCTAssertEqual(loaded.body, SampleRecipes.webResearch.body)
        XCTAssertEqual(loaded.arguments.map(\.name), ["url", "focus"])
        XCTAssertEqual(loaded.mode, .submit)
        XCTAssertEqual(loaded.target.session, .newSession)
    }

    func testSkillAndResultFormatRoundTrip() throws {
        let recipe = SampleRecipes.richResultTest
        let repo = RecipeRepository(layout: layout)
        try repo.save(recipe)

        let loaded = try repo.load(id: recipe.id)
        XCTAssertEqual(loaded.skill, SkillReference(name: "agent-recipes-rich-result-test", source: "codex"))
        XCTAssertEqual(loaded.resultFormat, .rich)
    }

    /// 旧スキーマ (projectAndAgent / agentOnly + target.agent) も読める。
    func testLegacyTargetSchemaIsMigrated() throws {
        let dir = layout.directory(for: "legacy")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"""
        { "schemaVersion": 2, "id": "legacy", "name": "Legacy",
          "target": { "strategy": "projectAndAgent", "agent": "codex", "onNotFound": "ask" } }
        """#.write(to: dir.appendingPathComponent("recipe.json"), atomically: true, encoding: .utf8)
        try "本文".write(to: dir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)

        let loaded = try RecipeRepository(layout: layout).load(id: "legacy")
        // 旧 strategy は「新しいセッション」に寄せる (既存セッションには入れない)。
        XCTAssertEqual(loaded.target.session, .newSession)
        XCTAssertNil(loaded.skill)
        XCTAssertEqual(loaded.resultFormat, .plain)
    }

    func testRenameMovesDirectory() throws {
        let repo = RecipeRepository(layout: layout)
        try repo.save(SampleRecipes.reviewDiff)
        try repo.rename(id: "review-diff", to: "review-changes")

        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.directory(for: "review-diff").path))
        XCTAssertEqual(try repo.load(id: "review-changes").id, "review-changes")
    }

    func testUniqueIDAvoidsCollision() throws {
        let repo = RecipeRepository(layout: layout)
        try repo.save(SampleRecipes.reviewDiff)
        XCTAssertEqual(repo.uniqueID(base: "review-diff"), "review-diff-2")
    }

    func testInvalidIDIsRejected() {
        let repo = RecipeRepository(layout: layout)
        XCTAssertThrowsError(try repo.save(Recipe(id: "../escape", name: "bad", body: "x")))
    }

    func testLoadAllSkipsUnrelatedFiles() throws {
        let repo = RecipeRepository(layout: layout)
        try repo.save(SampleRecipes.reviewDiff)
        try "noise".write(
            to: layout.recipesDirectory.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(repo.loadAll().map(\.id), ["review-diff"])
    }

    func testProjectsAreStoredIndependently() throws {
        let repo = ProjectRepository(layout: layout)
        let project = try repo.add(name: "music-db", path: "~/src/music-db")
        XCTAssertEqual(repo.load().count, 1)

        // 同じパスの再追加は増えない。
        _ = try repo.add(name: "music-db (dup)", path: "~/src/music-db/")
        XCTAssertEqual(repo.load().count, 1)
        XCTAssertEqual(repo.project(id: project.id)?.name, "music-db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.projectsFile.path))
    }

    func testProjectNormalizedPath() {
        let project = Project(name: "x", path: "~/src/foo/")
        XCTAssertEqual(project.normalizedPath, (("~/src/foo") as NSString).expandingTildeInPath)
    }

    func testSettingsRoundTripAndDefaults() throws {
        let repo = SettingsRepository(layout: layout)
        XCTAssertEqual(repo.load().defaultMode, .submit)
        XCTAssertTrue(repo.load().notificationsEnabled)

        var settings = repo.load()
        settings.herdrExecutablePath = "/opt/homebrew/bin/herdr"
        settings.debugLogging = true
        try repo.save(settings)

        XCTAssertEqual(repo.load().herdrExecutablePath, "/opt/homebrew/bin/herdr")
        XCTAssertTrue(repo.load().debugLogging)
    }

    func testPartialSettingsJSONFallsBackToDefaults() throws {
        try #"{ "debugLogging": true }"#.write(to: layout.settingsFile, atomically: true, encoding: .utf8)
        let settings = SettingsRepository(layout: layout).load()
        XCTAssertTrue(settings.debugLogging)
        XCTAssertEqual(settings.historyLimit, 200)
        XCTAssertEqual(settings.defaultMode, .submit)
    }

    func testHistoryKeepsMinimumFieldsAndOrder() {
        let history = HistoryRepository(layout: layout, limit: 5)
        for i in 0..<3 {
            history.append(HistoryEntry(
                recipeID: "r\(i)", recipeName: "Recipe \(i)",
                timestamp: Date().addingTimeInterval(Double(i)),
                project: "proj", agent: "codex", mode: .submit, result: .success
            ))
        }
        XCTAssertEqual(history.recent().map(\.recipeID), ["r2", "r1", "r0"])
    }

    func testHistoryIsTrimmedToLimit() {
        let history = HistoryRepository(layout: layout, limit: 3)
        for i in 0..<6 {
            history.append(HistoryEntry(
                recipeID: "r\(i)", recipeName: "R\(i)", agent: "claude", mode: .paste, result: .success
            ))
        }
        XCTAssertEqual(history.recent().count, 3)
        XCTAssertEqual(history.recent().first?.recipeID, "r5")
    }

    func testRecentRecipeIDsAreUniqueAndSkipFailures() {
        let history = HistoryRepository(layout: layout, limit: 50)
        func add(_ id: String, _ result: HistoryEntry.Result) {
            history.append(HistoryEntry(recipeID: id, recipeName: id, mode: .submit, result: result))
        }
        add("a", .success); add("b", .success); add("a", .success); add("c", .failure)
        XCTAssertEqual(history.recentRecipeIDs(limit: 5), ["a", "b"])
    }

    func testDebugLogWritesOnlyWhenEnabled() {
        DebugLog(layout: layout, enabled: false).write("hidden")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.logFile.path))

        DebugLog(layout: layout, enabled: true).write("herdr agent list --json")
        let text = try? String(contentsOf: layout.logFile, encoding: .utf8)
        XCTAssertEqual(text?.contains("herdr agent list --json"), true)
    }

    func testSkillScannerReadsFrontMatter() throws {
        let dir = root.appendingPathComponent("skills/web-page-research")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: web-page-research
        description: URL を読んで要点をまとめる
        ---

        # 本文
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        // SKILL.md を持たないディレクトリは無視する。
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("skills/not-a-skill"), withIntermediateDirectories: true
        )

        let found = SkillScanner().scan(sources: [
            SkillSource(name: "claude", path: root.appendingPathComponent("skills").path)
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.name, "web-page-research")
        XCTAssertEqual(found.first?.description, "URL を読んで要点をまとめる")
        XCTAssertEqual(found.first?.source, "claude")
        XCTAssertTrue(found.first?.path.hasSuffix("SKILL.md") == true)
        XCTAssertTrue(found.first?.matches("research") == true)
        XCTAssertFalse(found.first?.matches("音楽") == true)
    }

    func testSkillScannerFallsBackToDirectoryName() throws {
        let dir = root.appendingPathComponent("skills/no-front-matter")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# ただの Markdown".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let found = SkillScanner().scan(sources: [
            SkillSource(name: "codex", path: root.appendingPathComponent("skills").path)
        ])
        XCTAssertEqual(found.first?.name, "no-front-matter")
        XCTAssertNil(found.first?.description)
    }

    func testMissingSkillSourceIsIgnored() {
        let found = SkillScanner().scan(sources: [SkillSource(name: "x", path: "/nonexistent/skills")])
        XCTAssertTrue(found.isEmpty)
    }

    func testRecipeIDGeneration() {
        XCTAssertEqual(Recipe.makeID(from: "Discography Import"), "discography-import")
        XCTAssertEqual(Recipe.makeID(from: "PR レビュー!!"), "pr")
    }
}
