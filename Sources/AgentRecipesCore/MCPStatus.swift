import Foundation

/// MCP サーバー 1 件の状態。
public enum MCPServerState: String, Hashable, Sendable {
    /// 接続確認できた。
    case connected
    /// 接続に失敗した。Skill を起動しても途中で止まる可能性がある。
    case failed
    /// 承認待ち (Claude Code の `.mcp.json`)。
    case pending
    /// 設定はあるが無効。
    case disabled
    /// 設定されているが、この CLI では接続確認できない (Codex)。
    case configured
    case unknown

    public var displayName: String {
        switch self {
        case .connected: return "接続済み"
        case .failed: return "接続失敗"
        case .pending: return "承認待ち"
        case .disabled: return "無効"
        case .configured: return "設定あり"
        case .unknown: return "不明"
        }
    }

    public var symbolName: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .pending: return "pause.circle.fill"
        case .disabled: return "minus.circle"
        case .configured: return "circle.dashed"
        case .unknown: return "questionmark.circle"
        }
    }
}

public struct MCPServer: Hashable, Identifiable, Sendable {
    public var name: String
    /// コマンドや URL。一覧の補足に出す。
    public var detail: String?
    public var state: MCPServerState

    public var id: String { name }

    public init(name: String, detail: String? = nil, state: MCPServerState) {
        self.name = name
        self.detail = detail
        self.state = state
    }
}

/// ある LLM の MCP 接続状況。
public struct MCPInspection: Hashable, Sendable {
    public var agent: AgentKind
    /// CLI が見つからなかった場合は nil。
    public var executablePath: String?
    public var servers: [MCPServer]
    /// CLI が出した説明 / エラー。
    public var message: String?
    /// 実際に接続確認まで行ったか。Codex は設定一覧しか取れない。
    public var healthChecked: Bool
    /// どの作業ディレクトリで調べたか (MCP 設定は cwd に依存する)。
    public var workingDirectory: String
    public var checkedAt: Date

    public init(
        agent: AgentKind,
        executablePath: String? = nil,
        servers: [MCPServer] = [],
        message: String? = nil,
        healthChecked: Bool = false,
        workingDirectory: String = NSHomeDirectory(),
        checkedAt: Date = Date()
    ) {
        self.agent = agent
        self.executablePath = executablePath
        self.servers = servers
        self.message = message
        self.healthChecked = healthChecked
        self.workingDirectory = workingDirectory
        self.checkedAt = checkedAt
    }

    public var isInstalled: Bool { executablePath != nil }
    public var failures: [MCPServer] { servers.filter { $0.state == .failed } }
    public var hasFailure: Bool { !failures.isEmpty }

    /// 一行サマリー。メニューや設定の見出しに出す。
    public var summary: String {
        guard isInstalled else { return "\(agent.displayName) の CLI が見つかりません" }
        if servers.isEmpty { return "MCP サーバーなし" }
        if !healthChecked { return "\(servers.count) 件設定（接続確認は非対応）" }
        let connected = servers.filter { $0.state == .connected }.count
        if hasFailure { return "\(failures.count) 件が接続失敗（\(connected)/\(servers.count) 接続済み）" }
        return "\(connected)/\(servers.count) 接続済み"
    }
}

/// 同じ MCP サーバーを LLM 横断でまとめた行。
/// 例: `chrome-devtools` … Claude Code は接続済み / Codex は設定あり / Gemini は未設定。
public struct MCPServerGroup: Hashable, Identifiable, Sendable {
    public var name: String
    public var detail: String?
    /// LLM ごとの状態。設定されていない LLM は含まない。
    public var states: [AgentKind: MCPServerState]

    public var id: String { name }

    public init(name: String, detail: String? = nil, states: [AgentKind: MCPServerState]) {
        self.name = name
        self.detail = detail
        self.states = states
    }

    public func state(for agent: AgentKind) -> MCPServerState? { states[agent] }

    /// その LLM で実際に使える状態か。アイコンをカラーにする条件。
    public func isActive(for agent: AgentKind) -> Bool {
        switch states[agent] {
        case .connected, .configured: return true
        default: return false
        }
    }

    public var hasFailure: Bool { states.values.contains(.failed) }

    /// この MCP を使える LLM。
    public var activeAgents: [AgentKind] {
        AgentKind.allCases.filter { isActive(for: $0) }
    }
}

extension MCPInspection {
    /// 複数 LLM の結果を MCP 名でまとめる。並びは名前順。
    public static func grouped(_ inspections: [MCPInspection]) -> [MCPServerGroup] {
        var states: [String: [AgentKind: MCPServerState]] = [:]
        var details: [String: String] = [:]
        for inspection in inspections {
            for server in inspection.servers {
                states[server.name, default: [:]][inspection.agent] = server.state
                if details[server.name] == nil, let detail = server.detail {
                    details[server.name] = detail
                }
            }
        }
        return states.keys.sorted().map { name in
            MCPServerGroup(name: name, detail: details[name], states: states[name] ?? [:])
        }
    }
}

/// `<cli> mcp list` を実行して MCP の接続状況を読む。
///
/// MCP の設定は cwd（`.mcp.json` など）にも依存するため、
/// **Agent を起動するのと同じ作業ディレクトリ**で実行する。
public struct MCPScanner: Sendable {
    private let runner: @Sendable (_ executable: String, _ arguments: [String], _ cwd: String, _ timeout: TimeInterval) -> (output: String, error: String)?
    private let locator: @Sendable (String) -> String?

    public init() {
        self.runner = MCPScanner.runProcess
        self.locator = MCPScanner.locate
    }

    /// テスト用。CLI を実行せずに出力を差し替える。
    public init(
        locator: @escaping @Sendable (String) -> String?,
        runner: @escaping @Sendable (String, [String], String, TimeInterval) -> (output: String, error: String)?
    ) {
        self.locator = locator
        self.runner = runner
    }

    public func inspect(
        agent: AgentKind,
        workingDirectory: String = NSHomeDirectory(),
        timeout: TimeInterval = 30
    ) -> MCPInspection {
        guard let executable = locator(agent.rawValue) else {
            return MCPInspection(
                agent: agent,
                message: "`\(agent.rawValue)` が見つかりません。CLI をインストールすると MCP の状態を確認できます。",
                workingDirectory: workingDirectory
            )
        }
        let arguments = agent == .codex ? ["mcp", "list", "--json"] : ["mcp", "list"]
        guard let result = runner(executable, arguments, workingDirectory, timeout) else {
            return MCPInspection(
                agent: agent,
                executablePath: executable,
                message: "`\(agent.rawValue) \(arguments.joined(separator: " "))` が \(Int(timeout)) 秒以内に終わりませんでした。",
                workingDirectory: workingDirectory
            )
        }

        let text = result.output.isEmpty ? result.error : result.output
        if agent == .codex {
            let servers = Self.parseCodexJSON(result.output)
            return MCPInspection(
                agent: agent,
                executablePath: executable,
                servers: servers,
                message: servers.isEmpty ? Self.firstMeaningfulLine(text) : nil,
                healthChecked: false,
                workingDirectory: workingDirectory
            )
        }

        let servers = Self.parseListOutput(text)
        return MCPInspection(
            agent: agent,
            executablePath: executable,
            servers: servers,
            message: servers.isEmpty ? Self.firstMeaningfulLine(text) : nil,
            healthChecked: !servers.isEmpty,
            workingDirectory: workingDirectory
        )
    }

    // MARK: - パース

    /// Claude Code / Gemini の `mcp list` 出力。
    /// 例: `github: https://api.githubcopilot.com/mcp/ (HTTP) - ✓ Connected`
    static func parseListOutput(_ text: String) -> [MCPServer] {
        text.split(separator: "\n").compactMap { rawLine -> MCPServer? in
            let line = stripANSI(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            let state = self.state(of: rest)
            guard state != .unknown else { return nil }
            // " - ✓ Connected" などの状態部分を落として、コマンド / URL だけ残す。
            let detail = rest.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces)
            return MCPServer(name: name, detail: detail?.isEmpty == false ? detail : nil, state: state)
        }
    }

    private static func state(of text: String) -> MCPServerState {
        let lower = text.lowercased()
        // CLI により ✓ / ✔ / ✗ / ✘ が混在する。
        if text.contains("✗") || text.contains("✘") || lower.contains("failed") { return .failed }
        if text.contains("✓") || text.contains("✔") || lower.contains("connected") { return .connected }
        if text.contains("⏸") || lower.contains("pending") { return .pending }
        if lower.contains("disabled") { return .disabled }
        return .unknown
    }

    /// Codex の `mcp list --json`。接続確認はしないため、有効／無効だけを見る。
    static func parseCodexJSON(_ text: String) -> [MCPServer] {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let enabled = entry["enabled"] as? Bool ?? true
            let transport = entry["transport"] as? [String: Any]
            let detail = (transport?["command"] as? String) ?? (transport?["url"] as? String)
            return MCPServer(name: name, detail: detail, state: enabled ? .configured : .disabled)
        }
    }

    private static func firstMeaningfulLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { stripANSI(String($0)).trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )
    }

    // MARK: - 実行

    private static let runProcess: @Sendable (String, [String], String, TimeInterval) -> (output: String, error: String)? = { executable, arguments, cwd, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // 対話的な入力待ちで止まらないようにする。
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static let locate: @Sendable (String) -> String? = { command in
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        var candidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/\(command)"),
        ]
        // GUI から起動すると PATH が短いので、ログインシェルの PATH も一応見る。
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(command)" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
