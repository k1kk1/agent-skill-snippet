import Foundation

/// 送信先の LLM。Herdr の `agent start --kind` の値と対応する。
/// Recipe には持たせず、アプリ全体の設定として切り替える。
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case gemini

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// Herdr が agent 一覧で返す種別名。
    public var herdrKind: String { rawValue }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    /// ログイン時に起動する。
    public var launchAtLogin: Bool
    /// 送信結果の通知を出す。
    public var notificationsEnabled: Bool
    /// herdr 実行ファイルのパス。空なら自動検出。
    public var herdrExecutablePath: String
    /// Recipe ディレクトリの差し替え (空なら既定)。
    public var recipesDirectory: String
    /// Herdr とのやり取りをログに残す。
    public var debugLogging: Bool
    public var historyLimit: Int
    /// 新規 Recipe の既定モード。
    public var defaultMode: ExecutionMode
    /// 送信先の LLM (既定 Claude Code)。
    public var agent: AgentKind
    /// Submit のあと応答完了まで待ち、結果を表示する。
    public var waitForResult: Bool
    /// 応答待ちのタイムアウト (秒)。
    public var resultTimeoutSeconds: Int
    /// Skill を探すディレクトリ。
    public var skillSources: [SkillSource]
    /// SKILL.md を開くエディタのコマンド。空なら OS の既定アプリ。
    public var editorCommand: String

    public init(
        schemaVersion: Int = 2,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = true,
        herdrExecutablePath: String = "",
        recipesDirectory: String = "",
        debugLogging: Bool = false,
        historyLimit: Int = 200,
        defaultMode: ExecutionMode = .submit,
        agent: AgentKind = .claude,
        waitForResult: Bool = true,
        resultTimeoutSeconds: Int = 600,
        skillSources: [SkillSource] = SkillSource.defaults,
        editorCommand: String = "code"
    ) {
        self.schemaVersion = schemaVersion
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.herdrExecutablePath = herdrExecutablePath
        self.recipesDirectory = recipesDirectory
        self.debugLogging = debugLogging
        self.historyLimit = historyLimit
        self.defaultMode = defaultMode
        self.agent = agent
        self.waitForResult = waitForResult
        self.resultTimeoutSeconds = resultTimeoutSeconds
        self.skillSources = skillSources
        self.editorCommand = editorCommand
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, launchAtLogin, notificationsEnabled, herdrExecutablePath
        case recipesDirectory, debugLogging, historyLimit, defaultMode, skillSources, editorCommand
        case waitForResult, resultTimeoutSeconds, agent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        herdrExecutablePath = try c.decodeIfPresent(String.self, forKey: .herdrExecutablePath) ?? d.herdrExecutablePath
        recipesDirectory = try c.decodeIfPresent(String.self, forKey: .recipesDirectory) ?? d.recipesDirectory
        debugLogging = try c.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? d.debugLogging
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        defaultMode = try c.decodeIfPresent(ExecutionMode.self, forKey: .defaultMode) ?? d.defaultMode
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? d.agent
        waitForResult = try c.decodeIfPresent(Bool.self, forKey: .waitForResult) ?? d.waitForResult
        resultTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .resultTimeoutSeconds) ?? d.resultTimeoutSeconds
        skillSources = try c.decodeIfPresent([SkillSource].self, forKey: .skillSources) ?? d.skillSources
        editorCommand = try c.decodeIfPresent(String.self, forKey: .editorCommand) ?? d.editorCommand
    }
}

public final class SettingsRepository: @unchecked Sendable {
    public let layout: StorageLayout

    public init(layout: StorageLayout = StorageLayout()) {
        self.layout = layout
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: layout.settingsFile),
              let settings = try? JSONCoding.decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try layout.ensureDirectories()
        let data = try JSONCoding.encoder.encode(settings)
        try data.write(to: layout.settingsFile, options: .atomic)
    }
}

/// Herdr とのやり取りを追うための最小限のログ。settings.debugLogging が有効なときだけ書く。
public struct DebugLog: Sendable {
    private let url: URL?

    public init(layout: StorageLayout, enabled: Bool) {
        self.url = enabled ? layout.logFile : nil
    }

    public func write(_ message: String) {
        guard let url else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
