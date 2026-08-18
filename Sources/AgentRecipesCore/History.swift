import Foundation

/// 履歴は表示のためだけに持つ。Prompt 全文と引数は保存しない
/// (入力に機密情報が含まれうるため)。
public struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Result: String, Codable, Sendable {
        case success
        case failure
        /// 送れてはいないが失敗でもない状態。
        /// 起動時の確認 (フォルダの信頼など) で Agent が止まっているケース。
        case pending

        public var displayName: String {
            switch self {
            case .success: return "成功"
            case .failure: return "失敗"
            case .pending: return "確認待ち"
            }
        }

        /// 一覧の先頭に出す記号。
        public var marker: String {
            switch self {
            case .success: return " "
            case .failure: return "!"
            case .pending: return "?"
            }
        }
    }

    public var id: UUID
    public var recipeID: String
    public var recipeName: String
    public var timestamp: Date
    public var project: String?
    public var agent: String?
    /// 送信先の pane。履歴から結果を開き直すために持つ。
    public var paneID: String?
    public var mode: ExecutionMode
    public var result: Result
    public var message: String?

    public init(
        id: UUID = UUID(),
        recipeID: String,
        recipeName: String,
        timestamp: Date = Date(),
        project: String? = nil,
        agent: String? = nil,
        paneID: String? = nil,
        mode: ExecutionMode,
        result: Result,
        message: String? = nil
    ) {
        self.id = id
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.timestamp = timestamp
        self.project = project
        self.agent = agent
        self.paneID = paneID
        self.mode = mode
        self.result = result
        self.message = message
    }
}

/// JSON Lines で追記していく。壊れた行は読み飛ばす。
public final class HistoryRepository: @unchecked Sendable {
    private let layout: StorageLayout
    private let limit: Int
    private let lock = NSLock()

    public init(layout: StorageLayout = StorageLayout(), limit: Int = 200) {
        self.layout = layout
        self.limit = limit
    }

    public func append(_ entry: HistoryEntry) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONCoding.encoder.encode(entry),
              let line = String(data: data, encoding: .utf8)?
                  .replacingOccurrences(of: "\n", with: " ") else { return }

        try? layout.ensureDirectories()
        let url = layout.historyFile
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        trimIfNeeded()
    }

    /// 新しい順。
    public func recent(limit: Int = 50) -> [HistoryEntry] {
        entries().suffix(limit).reversed()
    }

    /// MenuBar の Recent 用。直近に成功した Recipe id を新しい順・重複なしで返す。
    public func recentRecipeIDs(limit: Int = 5) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries().reversed() where entry.result == .success {
            if seen.insert(entry.recipeID).inserted {
                out.append(entry.recipeID)
                if out.count == limit { break }
            }
        }
        return out
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: layout.historyFile)
    }

    private func entries() -> [HistoryEntry] {
        guard let text = try? String(contentsOf: layout.historyFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONCoding.decoder.decode(HistoryEntry.self, from: Data(line.utf8))
        }
    }

    private func trimIfNeeded() {
        let all = entries()
        guard all.count > limit else { return }
        let text = all.suffix(limit).compactMap { entry -> String? in
            guard let data = try? JSONCoding.encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\n", with: " ")
        }.joined(separator: "\n") + "\n"
        try? text.write(to: layout.historyFile, atomically: true, encoding: .utf8)
    }
}
