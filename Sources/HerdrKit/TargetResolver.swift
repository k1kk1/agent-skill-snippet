import Foundation
import AgentRecipesCore

/// 送信先の解決結果。
public enum TargetResolution: Hashable, Sendable {
    /// 1 件に決まった。
    case resolved(HerdrAgent)
    /// 該当が無いので、新しい Agent を起動して送る。
    case startNew(agent: String, project: Project?)
}

/// Recipe + Project + Agent + Herdr の状態から送信先を決める専用層。
/// Herdr CLI を直接呼ばず、渡された Agent 一覧だけで判断する (テストしやすさのため)。
///
/// 候補が複数あっても聞き返さず、優先順位で 1 件に決める。
/// 明示的に送信先を指定したい場合は、フォーム / CLI から Agent を渡す。
public struct TargetResolver: Sendable {
    public init() {}

    /// - Parameter agentKind: 送信先の LLM 種別。Recipe ではなくアプリ設定から渡す。
    /// - Parameter agentKind: 送信先の LLM 種別。Recipe ではなくアプリ設定から渡す。
    public func resolve(
        recipe: Recipe,
        project: Project?,
        agents: [HerdrAgent],
        agentKind: AgentKind
    ) throws -> TargetResolution {
        switch recipe.target.session {
        case .newSession:
            // 既定。既存セッションには入れず、必ず新しい Agent を起動する。
            return .startNew(agent: agentKind.herdrKind, project: project)

        case .reuseIfAvailable:
            let candidates = rank(filter(agents: agents, target: recipe.target, project: project, agentKind: agentKind))
                .filter { !$0.isWorking } // 作業中には割り込まない
            if let best = candidates.first { return .resolved(best) }
            return .startNew(agent: agentKind.herdrKind, project: project)
        }
    }

    /// 再利用できる候補を絞る。Project が指定されていれば cwd も一致させる。
    public func filter(
        agents: [HerdrAgent],
        target: TargetSpec,
        project: Project?,
        agentKind: AgentKind
    ) -> [HerdrAgent] {
        var candidates = agents.filter {
            $0.agentName.caseInsensitiveCompare(agentKind.herdrKind) == .orderedSame
        }
        if target.projectID != nil, let project {
            candidates = candidates.filter { $0.normalizedCwd == project.normalizedPath }
        }
        if let workspaceID = target.workspaceID {
            candidates = candidates.filter { $0.workspaceID == workspaceID }
        }
        return candidates
    }

    /// 送信しても差し支えない順に並べる。
    /// 作業中の Agent に割り込むのは最後の手段にする。
    public func rank(_ candidates: [HerdrAgent]) -> [HerdrAgent] {
        candidates.enumerated()
            .sorted { lhs, rhs in
                let l = priority(lhs.element)
                let r = priority(rhs.element)
                if l != r { return l < r }
                return lhs.offset < rhs.offset // 同順位は Herdr が返した順を保つ
            }
            .map(\.element)
    }

    private func priority(_ agent: HerdrAgent) -> Int {
        switch (agent.status ?? "").lowercased() {
        case "idle": return 0
        case "done": return 1
        case "unknown", "": return 2
        case "blocked": return 3
        case "working": return 4
        default: return 2
        }
    }
}
