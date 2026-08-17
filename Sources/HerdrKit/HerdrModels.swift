import Foundation

/// Herdr CLI (0.8) が返す JSON エンベロープ。
/// 成功: `{"id":"cli:agent:list","result":{...}}`
/// 失敗: `{"id":"...","error":{"code":"agent_not_found","message":"..."}}`
/// 失敗時も終了コードは 0 なので、エラー判定は必ずこの `error` を見る。
struct HerdrEnvelope<Result: Decodable>: Decodable {
    var id: String?
    var result: Result?
    var error: HerdrRemoteError?
}

struct HerdrRemoteError: Decodable, Hashable, Sendable {
    var code: String
    var message: String
}

struct AgentListResult: Decodable {
    var agents: [HerdrAgent]
}

struct PaneListResult: Decodable {
    var panes: [HerdrPane]
}

struct WorkspaceListResult: Decodable {
    var workspaces: [HerdrWorkspace]
}

struct TabListResult: Decodable {
    var tabs: [HerdrTab]
}

struct AgentInfoResult: Decodable {
    var agent: HerdrAgent
}

struct AgentStartedResult: Decodable {
    var agent: HerdrAgent
}

struct TabCreatedResult: Decodable {
    var rootPane: HerdrPane
    var tab: HerdrTab?

    private enum CodingKeys: String, CodingKey {
        case rootPane = "root_pane"
        case tab
    }
}

struct WorkspaceCreatedResult: Decodable {
    var rootPane: HerdrPane
    var workspace: HerdrWorkspace

    private enum CodingKeys: String, CodingKey {
        case rootPane = "root_pane"
        case workspace
    }
}

public struct HerdrWorkspace: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String?
    public var number: Int?
    public var paneCount: Int?
    public var agentStatus: String?

    public var displayName: String { label ?? id }

    public init(id: String, label: String? = nil, number: Int? = nil, paneCount: Int? = nil, agentStatus: String? = nil) {
        self.id = id
        self.label = label
        self.number = number
        self.paneCount = paneCount
        self.agentStatus = agentStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id = "workspace_id"
        case label, number
        case paneCount = "pane_count"
        case agentStatus = "agent_status"
    }
}

public struct HerdrTab: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String?
    public var workspaceID: String?

    public var displayName: String { label ?? id }

    public init(id: String, label: String? = nil, workspaceID: String? = nil) {
        self.id = id
        self.label = label
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case id = "tab_id"
        case label
        case workspaceID = "workspace_id"
    }
}

public struct HerdrPane: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String?
    public var title: String?
    public var cwd: String?
    public var agent: String?
    public var agentStatus: String?
    public var workspaceID: String?
    public var tabID: String?

    public init(
        id: String, label: String? = nil, title: String? = nil, cwd: String? = nil,
        agent: String? = nil, agentStatus: String? = nil,
        workspaceID: String? = nil, tabID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.title = title
        self.cwd = cwd
        self.agent = agent
        self.agentStatus = agentStatus
        self.workspaceID = workspaceID
        self.tabID = tabID
    }

    public var displayName: String {
        label ?? title ?? cwd.map { ($0 as NSString).lastPathComponent } ?? id
    }

    private enum CodingKeys: String, CodingKey {
        case id = "pane_id"
        case label
        case title = "terminal_title_stripped"
        case cwd
        case agent
        case agentStatus = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
    }
}

/// Herdr 上で動いている Agent。送信先はこれ。
/// `herdr agent prompt` / `herdr pane send-text` の target はどちらも pane_id なので、
/// この型の id も pane_id を採用する。
public struct HerdrAgent: Codable, Hashable, Identifiable, Sendable {
    /// pane_id ("w1:p2")。
    public var id: String
    /// agent 種別 ("codex" / "claude" など)。
    public var agent: String?
    public var status: String?
    public var cwd: String?
    public var workspaceID: String?
    public var tabID: String?
    public var title: String?
    public var focused: Bool?
    /// Agent の TUI が入力を受け付けられる状態か。
    /// 起動直後はスプラッシュ表示などで false になり、この間に送った Prompt は落ちる。
    public var interactiveReady: Bool?

    public init(
        id: String, agent: String? = nil, status: String? = nil, cwd: String? = nil,
        workspaceID: String? = nil, tabID: String? = nil, title: String? = nil, focused: Bool? = nil,
        interactiveReady: Bool? = nil
    ) {
        self.id = id
        self.agent = agent
        self.status = status
        self.cwd = cwd
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.title = title
        self.focused = focused
        self.interactiveReady = interactiveReady
    }

    private enum CodingKeys: String, CodingKey {
        case id = "pane_id"
        case agent
        case status = "agent_status"
        case cwd
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case title = "terminal_title_stripped"
        case focused
        case interactiveReady = "interactive_ready"
    }

    /// pane_id と agent id は同一。Paste も Submit も同じ target を使う。
    public var paneID: String { id }

    public var agentName: String { agent ?? "agent" }

    public var projectName: String? {
        cwd.map { ($0 as NSString).lastPathComponent }
    }

    /// 通知やメニューでの表示名。例: "ComposerSketch / Codex"
    public var displayName: String {
        "\(projectName ?? title ?? id) / \(agentName.capitalized)"
    }

    public var isIdle: Bool { (status ?? "").lowercased() == "idle" }

    /// 応答中。割り込むと進行中の作業を邪魔するので、送信先としては避けたい。
    public var isWorking: Bool { (status ?? "").lowercased() == "working" }

    /// cwd 比較用に正規化したパス。
    public var normalizedCwd: String? {
        guard let cwd else { return nil }
        var path = ((cwd as NSString).expandingTildeInPath as NSString).standardizingPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

public enum HerdrError: LocalizedError, Equatable {
    case notInstalled
    case notRunning(String)
    case noAgent(agent: String?, project: String?)
    case multipleAgents([HerdrAgent])
    case commandFailed(command: String, code: String, message: String)
    case decodingFailed(command: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "herdr コマンドが見つかりません。Settings で herdr のパスを指定してください。"
        case .notRunning(let detail):
            return "Herdr が起動していません。Herdr を起動してから再実行してください。(\(detail))"
        case .noAgent(let agent, let project):
            let agentPart = agent.map { "\($0) " } ?? ""
            let projectPart = project.map { " (\($0))" } ?? ""
            return "対象の \(agentPart)Agent が見つかりません\(projectPart)"
        case .multipleAgents(let agents):
            return "候補が複数あります: \(agents.map(\.displayName).joined(separator: ", "))"
        case .commandFailed(let command, let code, let message):
            return "herdr \(command) が失敗しました [\(code)]: \(message)"
        case .decodingFailed(let command):
            return "herdr \(command) の出力を解釈できませんでした"
        }
    }
}
