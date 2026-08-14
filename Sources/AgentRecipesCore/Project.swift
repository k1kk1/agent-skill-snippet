import Foundation

/// Project は Recipe から独立したデータとして projects.json に保存する。
public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String

    public init(id: String = UUID().uuidString, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    public var expandedPath: String { (path as NSString).expandingTildeInPath }

    /// cwd 比較用に正規化したパス。
    public var normalizedPath: String {
        var path = (expandedPath as NSString).standardizingPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private enum CodingKeys: String, CodingKey { case id, name, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        // 旧形式 (path が id 代わり) からの読み込みも通す。
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? path
    }
}

public final class ProjectRepository: @unchecked Sendable {
    private let layout: StorageLayout

    public init(layout: StorageLayout = StorageLayout()) {
        self.layout = layout
    }

    public func load() -> [Project] {
        guard let data = try? Data(contentsOf: layout.projectsFile),
              let projects = try? JSONCoding.decoder.decode([Project].self, from: data) else {
            return []
        }
        return projects
    }

    public func save(_ projects: [Project]) throws {
        try layout.ensureDirectories()
        let data = try JSONCoding.encoder.encode(projects)
        try data.write(to: layout.projectsFile, options: .atomic)
    }

    public func project(id: String?) -> Project? {
        guard let id else { return nil }
        return load().first { $0.id == id }
    }

    /// 同じパスの Project があれば再利用し、無ければ追加する。
    @discardableResult
    public func add(name: String, path: String) throws -> Project {
        var projects = load()
        let candidate = Project(name: name, path: path)
        if let existing = projects.first(where: { $0.normalizedPath == candidate.normalizedPath }) {
            return existing
        }
        projects.append(candidate)
        try save(projects)
        return candidate
    }
}
