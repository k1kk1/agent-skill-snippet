import Foundation

/// 保存先は macOS ネイティブアプリ寄りに Application Support 配下。
///
/// ```
/// ~/Library/Application Support/AgentRecipes/
///   settings.json
///   projects.json
///   history.jsonl
///   recipes/<id>/recipe.json
///   recipes/<id>/prompt.md
/// ```
///
/// 任意ディレクトリ / Git 管理は将来対応だが、Recipe ディレクトリだけは
/// 設定で差し替えられるようにしてある (settings.recipesDirectory)。
public struct StorageLayout: Sendable {
    public let root: URL
    private let recipesOverride: URL?

    public init(root: URL? = nil, recipesDirectory: String? = nil) {
        if let root {
            self.root = root
        } else if let override = ProcessInfo.processInfo.environment["AGENTRECIPES_HOME"], !override.isEmpty {
            self.root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.root = base.appendingPathComponent("AgentRecipes", isDirectory: true)
        }

        if let recipesDirectory, !recipesDirectory.isEmpty {
            self.recipesOverride = URL(
                fileURLWithPath: (recipesDirectory as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            self.recipesOverride = nil
        }
    }

    public var recipesDirectory: URL {
        recipesOverride ?? root.appendingPathComponent("recipes", isDirectory: true)
    }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var projectsFile: URL { root.appendingPathComponent("projects.json") }
    public var historyFile: URL { root.appendingPathComponent("history.jsonl") }
    public var logFile: URL { root.appendingPathComponent("debug.log") }

    public func directory(for recipeID: String) -> URL {
        recipesDirectory.appendingPathComponent(recipeID, isDirectory: true)
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: recipesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

public enum StorageError: LocalizedError {
    case recipeNotFound(String)
    case duplicateRecipe(String)
    case invalidRecipeID(String)

    public var errorDescription: String? {
        switch self {
        case .recipeNotFound(let id): return "Recipe '\(id)' が見つかりません"
        case .duplicateRecipe(let id): return "Recipe '\(id)' は既に存在します"
        case .invalidRecipeID(let id): return "Recipe id '\(id)' は使用できません"
        }
    }
}

public final class RecipeRepository: @unchecked Sendable {
    public let layout: StorageLayout
    private let fm = FileManager.default

    public init(layout: StorageLayout = StorageLayout()) {
        self.layout = layout
    }

    public func loadAll() -> [Recipe] {
        guard let entries = try? fm.contentsOfDirectory(
            at: layout.recipesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .compactMap { url -> Recipe? in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return try? load(directory: url)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func load(id: String) throws -> Recipe {
        let dir = layout.directory(for: id)
        guard fm.fileExists(atPath: dir.appendingPathComponent("recipe.json").path) else {
            throw StorageError.recipeNotFound(id)
        }
        return try load(directory: dir)
    }

    public func load(directory: URL) throws -> Recipe {
        let data = try Data(contentsOf: directory.appendingPathComponent("recipe.json"))
        var recipe = try JSONCoding.decoder.decode(Recipe.self, from: data)
        // ディレクトリ名を正とする。手でコピーされた Recipe でも壊れないように。
        recipe.id = directory.lastPathComponent
        let file = recipe.prompt.file ?? "prompt.md"
        if let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) {
            recipe.body = text
        } else {
            recipe.body = recipe.prompt.text ?? ""
        }
        return recipe
    }

    @discardableResult
    public func save(_ recipe: Recipe) throws -> Recipe {
        var recipe = recipe
        guard isValidID(recipe.id) else { throw StorageError.invalidRecipeID(recipe.id) }
        recipe.schemaVersion = Recipe.currentSchemaVersion

        let dir = layout.directory(for: recipe.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = recipe.prompt.file ?? "prompt.md"
        recipe.prompt = PromptSpec(file: file, text: nil)
        try recipe.body.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)

        let data = try JSONCoding.encoder.encode(recipe)
        try data.write(to: dir.appendingPathComponent("recipe.json"), options: .atomic)
        return recipe
    }

    public func delete(id: String) throws {
        let dir = layout.directory(for: id)
        guard fm.fileExists(atPath: dir.path) else { throw StorageError.recipeNotFound(id) }
        try fm.removeItem(at: dir)
    }

    public func rename(id: String, to newID: String) throws {
        guard isValidID(newID) else { throw StorageError.invalidRecipeID(newID) }
        guard id != newID else { return }
        let src = layout.directory(for: id)
        let dst = layout.directory(for: newID)
        guard fm.fileExists(atPath: src.path) else { throw StorageError.recipeNotFound(id) }
        guard !fm.fileExists(atPath: dst.path) else { throw StorageError.duplicateRecipe(newID) }
        try fm.moveItem(at: src, to: dst)
        var recipe = try load(directory: dst)
        recipe.id = newID
        try save(recipe)
    }

    public func uniqueID(base: String) -> String {
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: layout.directory(for: candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    private func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        guard !id.contains("/"), !id.hasPrefix(".") else { return false }
        return true
    }
}

public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
