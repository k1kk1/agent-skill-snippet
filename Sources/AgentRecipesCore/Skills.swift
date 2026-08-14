import Foundation

/// 検出された Agent Skill。
/// Recipe とは別概念で、Prompt 本文から「どの Skill を使わせるか」を書くときの参照に使う。
public struct DiscoveredSkill: Hashable, Identifiable, Sendable {
    public var name: String
    public var description: String?
    /// どの Source（Agent 種別）で見つかったか。"claude" / "codex" など。
    public var source: String
    /// SKILL.md の絶対パス。
    public var path: String

    public var id: String { path }

    public var directory: String { (path as NSString).deletingLastPathComponent }

    public init(name: String, description: String? = nil, source: String, path: String) {
        self.name = name
        self.description = description
        self.source = source
        self.path = path
    }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let joined = [name, description ?? "", source, path].joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { joined.contains($0) }
    }
}

/// Skill を探すディレクトリ。
public struct SkillSource: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var path: String

    public var id: String { path }
    public var expandedPath: String { (path as NSString).expandingTildeInPath }

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    public static let defaults: [SkillSource] = [
        SkillSource(name: "claude", path: "~/.claude/skills"),
        SkillSource(name: "codex", path: "~/.codex/skills"),
    ]
}

/// `<dir>/<skill-name>/SKILL.md` を走査する。
/// Agent ごとに形式が変わってもここだけ直せば済むようにしてある。
public struct SkillScanner: Sendable {
    private let fileNames: [String]

    public init(fileNames: [String] = ["SKILL.md", "skill.md"]) {
        self.fileNames = fileNames
    }

    public func scan(sources: [SkillSource]) -> [DiscoveredSkill] {
        var seen = Set<String>()
        var out: [DiscoveredSkill] = []
        for source in sources {
            for skill in scan(source: source) where seen.insert(skill.path).inserted {
                out.append(skill)
            }
        }
        return out.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func scan(source: SkillSource) -> [DiscoveredSkill] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: source.expandedPath, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { entry -> DiscoveredSkill? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            guard let file = fileNames
                .map({ entry.appendingPathComponent($0) })
                .first(where: { fm.fileExists(atPath: $0.path) }) else { return nil }

            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return DiscoveredSkill(
                name: frontMatterValue("name", in: text) ?? entry.lastPathComponent,
                description: frontMatterValue("description", in: text),
                source: source.name,
                path: file.path
            )
        }
    }

    /// SKILL.md 先頭の YAML front matter から素朴に 1 行値を取り出す。
    /// (YAML パーサを持ち込むほどの用途ではない)
    private func frontMatterValue(_ key: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard trimmed.hasPrefix("\(key):") else { continue }
            var value = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// SKILL.md をエディタで開く。
public struct SkillOpener: Sendable {
    /// 設定された起動コマンド (既定 "code")。空なら OS の既定アプリで開く。
    private let command: String

    public init(command: String = "code") {
        self.command = command.trimmingCharacters(in: .whitespaces)
    }

    /// 指定エディタで開く。成功したら true。
    /// 見つからない場合は false を返し、呼び出し側が OS 既定にフォールバックする。
    @discardableResult
    public func open(path: String) -> Bool {
        guard !command.isEmpty, let executable = locate(command) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }

    private func locate(_ command: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        let candidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/\(command)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
