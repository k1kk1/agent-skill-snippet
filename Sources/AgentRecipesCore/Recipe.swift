import Foundation

/// MVP の Argument Type は 3 つだけ。
/// Number / Boolean / Enum は後続、File / Directory はさらに将来。
public enum ArgumentType: String, Codable, CaseIterable, Sendable {
    case string
    case multiline
    case url
    /// 決められた選択肢から選ぶ。値は `ArgumentSpec.options` から取る。
    case choice

    public var displayName: String {
        switch self {
        case .string: return "String"
        case .multiline: return "Multiline"
        case .url: return "URL"
        case .choice: return "選択"
        }
    }

    /// UI で入力形式を直感的に示す SF Symbol。
    public var symbolName: String {
        switch self {
        case .url: return "link"
        case .string: return "text.cursor"
        case .multiline: return "text.alignleft"
        case .choice: return "list.bullet.circle"
        }
    }
}

/// 選択肢の見せ方。
public enum ChoiceStyle: String, Codable, CaseIterable, Sendable {
    /// プルダウン。選択肢が多いときに向く。
    case menu
    /// 並べたボタン。2〜4 個くらいのときに向く。
    case buttons

    public var displayName: String {
        switch self {
        case .menu: return "プルダウン"
        case .buttons: return "ボタン"
        }
    }
}

public struct ArgumentSpec: Codable, Hashable, Identifiable, Sendable {
    /// 編集中も変わらない行の識別子。name はユーザーが編集できるため ID には使わない。
    public var id: UUID
    public var name: String
    public var label: String?
    public var type: ArgumentType
    public var required: Bool
    public var defaultValue: String?
    /// 未入力時に clipboard を既定値として使う。
    public var useClipboardAsDefault: Bool
    /// `type == .choice` のときの選択肢。
    public var options: [String]
    /// 選択肢の見せ方 (プルダウン / ボタン)。
    public var choiceStyle: ChoiceStyle
    /// 複数選べるようにする。値は「A, B」のように連結して渡す。
    public var allowsMultiple: Bool

    /// 実行前に打ち込む必要がある引数か (既定値も Clipboard も無い)。
    /// 一覧の「フォームで入力する」記号が点くのはこの条件。
    public var needsTypedValue: Bool {
        if useClipboardAsDefault { return false }
        if let defaultValue, !defaultValue.isEmpty { return false }
        return true
    }

    public var displayLabel: String { label ?? name }

    /// 空白を落とし、重複を除いた選択肢。
    public var normalizedOptions: [String] {
        var seen = Set<String>()
        return options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        label: String? = nil,
        type: ArgumentType = .string,
        required: Bool = true,
        defaultValue: String? = nil,
        useClipboardAsDefault: Bool = false,
        options: [String] = [],
        choiceStyle: ChoiceStyle = .menu,
        allowsMultiple: Bool = false
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.useClipboardAsDefault = useClipboardAsDefault
        self.options = options
        self.choiceStyle = choiceStyle
        self.allowsMultiple = allowsMultiple
    }

    /// 複数選択の値の区切り。Prompt にそのまま出るので読みやすい形にする。
    public static let choiceSeparator = ", "

    /// 連結された値を選択肢の配列に戻す。
    public static func selectedValues(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 選択肢の並び順を保ったまま連結する。
    public func joined(_ values: [String]) -> String {
        let selected = Set(values)
        let ordered = normalizedOptions.filter { selected.contains($0) }
        return ordered.joined(separator: Self.choiceSeparator)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, label, type, required, defaultValue, useClipboardAsDefault
        case options, choiceStyle, allowsMultiple
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // schema 3 までの Recipe には id が無いため、読み込み時に 1 度だけ採番する。
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        type = try c.decodeIfPresent(ArgumentType.self, forKey: .type) ?? .string
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue)
        useClipboardAsDefault = try c.decodeIfPresent(Bool.self, forKey: .useClipboardAsDefault) ?? false
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        choiceStyle = try c.decodeIfPresent(ChoiceStyle.self, forKey: .choiceStyle) ?? .menu
        allowsMultiple = try c.decodeIfPresent(Bool.self, forKey: .allowsMultiple) ?? false
    }
}

/// 送信方法。Herdr の pane / agent への投入方法に 1:1 で対応する。
public enum ExecutionMode: String, Codable, CaseIterable, Sendable {
    /// Clipboard にコピーするだけ。Herdr がなくても使える。
    case copy
    /// pane へ文字列だけ送る (Enter は押さない) → herdr pane send-text
    case paste
    /// Agent へ prompt として送る → herdr agent prompt
    case submit

    public var displayName: String {
        switch self {
        case .copy: return "Prompt をコピー"
        case .paste: return "チャットに入力"
        case .submit: return "実行"
        }
    }

    /// Recipe エディタで使う、操作対象が分かる名称とアイコン。
    public var editorDisplayName: String {
        switch self {
        case .copy: return "Prompt をコピー"
        case .paste: return "チャットに入力"
        case .submit: return "実行"
        }
    }

    /// 一覧の行で「クリックすると何が起きるか」を示す記号。
    public var symbolName: String {
        switch self {
        case .copy: return "doc.on.clipboard"
        case .paste: return "text.insert"
        case .submit: return "paperplane"
        }
    }

    /// 何が起きるかの 1 行説明。
    public var explanation: String {
        switch self {
        case .copy: return "Prompt をクリップボードにコピーするだけ"
        case .paste: return "LLM のチャット欄に入れて前面に出す。編集して自分で送る"
        case .submit: return "そのまま実行して、結果をアプリに表示する"
        }
    }

    /// Herdr を必要とするか。
    public var requiresHerdr: Bool { self != .copy }
}

/// どの Agent を送信先にするか。
/// 既定は「空いていれば再利用」。作業中の Agent には割り込まず、無ければ新規に起動する。
public enum SessionPolicy: String, Codable, CaseIterable, Sendable {
    /// Herdr に新しい tab を作り、Agent を起動して実行する。
    case newSession
    /// 空いている既存 Agent があれば使い、無ければ新規に立てる。
    case reuseIfAvailable

    public var displayName: String {
        switch self {
        case .newSession: return "新しいセッション"
        case .reuseIfAvailable: return "空いていれば再利用"
        }
    }

    public var explanation: String {
        switch self {
        case .newSession: return "毎回新しい Agent を起動する。既存の作業とは分けて実行する"
        case .reuseIfAvailable: return "同じ LLM の空き Agent を再利用する。無ければ新しい Agent を起動する"
        }
    }
}

public struct TargetSpec: Codable, Hashable, Sendable {
    public var session: SessionPolicy
    /// projects.json の Project id。新しいセッションの作業ディレクトリにも使う。
    public var projectID: String?
    /// Herdr workspace id。指定時はその workspace の Agent だけを再利用候補にする。
    public var workspaceID: String?
    /// Herdr workspace の名前。まだ存在しない名前なら、実行時にその名前で作る。
    public var workspaceName: String?
    /// 実行時に Project を選ぶ。
    public var askProject: Bool

    public init(
        session: SessionPolicy = .newSession,
        projectID: String? = nil,
        workspaceID: String? = nil,
        workspaceName: String? = nil,
        askProject: Bool = false
    ) {
        self.session = session
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.askProject = askProject
    }

    private enum CodingKeys: String, CodingKey {
        case session, projectID, workspaceID, workspaceName, askProject
        // 旧スキーマ
        case strategy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
        askProject = try c.decodeIfPresent(Bool.self, forKey: .askProject) ?? false
        // 旧スキーマ (strategy) と、廃止した "ask" は「新しいセッション」に寄せる。
        let raw = try c.decodeIfPresent(String.self, forKey: .session)
        self.session = raw.flatMap(SessionPolicy.init(rawValue:)) ?? .newSession
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(session, forKey: .session)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try c.encodeIfPresent(workspaceName, forKey: .workspaceName)
        try c.encode(askProject, forKey: .askProject)
    }
}

public struct PromptSpec: Codable, Hashable, Sendable {
    /// recipe ディレクトリからの相対パス。既定は prompt.md。
    public var file: String?
    /// 短い Prompt を JSON に直接置きたい場合。file が優先される。
    public var text: String?

    public init(file: String? = "prompt.md", text: String? = nil) {
        self.file = file
        self.text = text
    }
}

/// Recipe が使う Skill。実体は各AgentのSkillディレクトリにあり、Recipeには参照だけを保存する。
public struct SkillReference: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var source: String

    public var id: String { "\(source):\(name)" }
    public var displayName: String { "[\(source)] \(name)" }

    public init(name: String, source: String) {
        self.name = name
        self.source = source
    }
}

/// Agentへ期待する最終出力の形式。表示側は常に自動検出するが、rich指定時はPromptにも契約を付与する。
public enum ResultFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case plain
    case rich

    public var displayName: String {
        switch self {
        case .plain: return "通常テキスト"
        case .rich: return "リッチ結果 (JSON)"
        }
    }

    public var explanation: String {
        switch self {
        case .plain: return "Skill / Agent の通常出力をそのまま表示する"
        case .rich: return "Markdown・表・リスト・JSONをResultウィンドウで構造化表示する"
        }
    }
}

/// ユーザーが選ぶ単位。Skill そのものではなく「やりたい作業」。
public struct Recipe: Codable, Identifiable, Hashable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var description: String?
    public var category: String?
    public var tags: [String]
    public var favorite: Bool
    public var prompt: PromptSpec
    /// Agentへ使わせるSkill。nilならPrompt本文だけを送る。
    public var skill: SkillReference?
    /// rich指定時は構造化結果の出力契約をPromptに追加する。
    public var resultFormat: ResultFormat
    public var arguments: [ArgumentSpec]
    /// Skill が任意の補足プロンプトを受け付けるか。明示的な引数とは別の、任意の文脈・指示用。
    public var acceptsAdditionalPrompt: Bool
    public var mode: ExecutionMode
    public var target: TargetSpec

    /// prompt.md の中身。JSON には保存せず Repository が読み書きする。
    public var body: String = ""

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        tags: [String] = [],
        favorite: Bool = false,
        prompt: PromptSpec = PromptSpec(),
        skill: SkillReference? = nil,
        resultFormat: ResultFormat = .plain,
        arguments: [ArgumentSpec] = [],
        acceptsAdditionalPrompt: Bool = false,
        mode: ExecutionMode = .submit,
        target: TargetSpec = TargetSpec(),
        body: String = ""
    ) {
        self.schemaVersion = Recipe.currentSchemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.tags = tags
        self.favorite = favorite
        self.prompt = prompt
        self.skill = skill
        self.resultFormat = resultFormat
        self.arguments = arguments
        self.acceptsAdditionalPrompt = acceptsAdditionalPrompt
        self.mode = mode
        self.target = target
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, description, category, tags, favorite
        case prompt, skill, resultFormat, arguments, acceptsAdditionalPrompt, mode, target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Recipe.currentSchemaVersion
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        prompt = try c.decodeIfPresent(PromptSpec.self, forKey: .prompt) ?? PromptSpec()
        skill = try c.decodeIfPresent(SkillReference.self, forKey: .skill)
        resultFormat = try c.decodeIfPresent(ResultFormat.self, forKey: .resultFormat) ?? .plain
        arguments = try c.decodeIfPresent([ArgumentSpec].self, forKey: .arguments) ?? []
        acceptsAdditionalPrompt = try c.decodeIfPresent(Bool.self, forKey: .acceptsAdditionalPrompt) ?? false
        mode = try c.decodeIfPresent(ExecutionMode.self, forKey: .mode) ?? .submit
        target = try c.decodeIfPresent(TargetSpec.self, forKey: .target) ?? TargetSpec()
        body = ""
    }

    public var template: String {
        body.isEmpty ? (prompt.text ?? "") : body
    }

    /// 実行前にユーザーへ何か聞く必要があるか。
    /// 無ければメニューから選んだ瞬間に実行できる。
    public var needsUserInput: Bool {
        arguments.contains(where: \.needsTypedValue) || target.askProject
    }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let haystack = [name, id, description ?? "", category ?? ""] + tags
        let joined = haystack.joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { joined.contains($0) }
    }
}

public extension Recipe {
    /// 表示名から安全な recipe id (ディレクトリ名) を作る。
    static func makeID(from name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "recipe-\(UUID().uuidString.prefix(8).lowercased())" : trimmed
    }
}
