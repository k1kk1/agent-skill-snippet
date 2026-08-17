import Foundation

/// Skill が Agent Recipes に返すリッチ結果の契約。
///
/// `agent-recipes.result/v1` の JSON を `agent-recipes-result` コードフェンスで囲む。
/// フェンスを使うことで、pane に Prompt や Agent の UI が残っていても最後の結果だけを抽出できる。
public struct RichResultDocument: Codable, Hashable, Sendable {
    public static let schema = "agent-recipes.result/v1"

    /// `ResultFormat.rich` のRecipeがAgentへ送る最終出力の契約。
    public static let promptInstruction = """
    最終回答は Agent Recipes の構造化結果として返してください。説明文をフェンスの外に書かず、
    `agent-recipes-result` コードフェンス内に有効な JSON を1つだけ入れてください。
    JSON は `schema` を `agent-recipes.result/v1`、`blocks` を1件以上とし、
    block の `type` は `markdown`（`content`）、`table`（`columns`, `rows`）、
    `list`（`style`, `items`）、`json`（`value`）のいずれかを使ってください。
    """

    public var schema: String
    public var title: String?
    public var blocks: [RichResultBlock]

    public init(title: String? = nil, blocks: [RichResultBlock]) {
        self.schema = Self.schema
        self.title = title
        self.blocks = blocks
    }
}

public enum RichResultBlock: Hashable, Sendable {
    case markdown(String)
    case table(columns: [String], rows: [[String]])
    case list(style: RichListStyle, items: [String])
    case json(JSONValue)
}

public enum RichListStyle: String, Codable, Hashable, Sendable {
    case bullet
    case numbered
    case checklist
}

/// Foundation の JSONSerialization に依存せず Codable / Sendable で保持できる JSON 値。
public indirect enum JSONValue: Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public var prettyPrinted: String {
        guard JSONSerialization.isValidJSONObject(foundationValue),
              let data = try? JSONSerialization.data(
                withJSONObject: foundationValue,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return String(describing: foundationValue)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private var foundationValue: Any {
        switch self {
        case .object(let value): return value.mapValues(\.foundationValue)
        case .array(let value): return value.map(\.foundationValue)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension RichResultBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, content, columns, rows, style, items, value
    }

    private enum BlockType: String, Codable {
        case markdown, table, list, json
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(BlockType.self, forKey: .type) {
        case .markdown:
            self = .markdown(try container.decode(String.self, forKey: .content))
        case .table:
            self = .table(
                columns: try container.decode([String].self, forKey: .columns),
                rows: try container.decode([[String]].self, forKey: .rows)
            )
        case .list:
            self = .list(
                style: try container.decodeIfPresent(RichListStyle.self, forKey: .style) ?? .bullet,
                items: try container.decode([String].self, forKey: .items)
            )
        case .json:
            self = .json(try container.decode(JSONValue.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .markdown(let content):
            try container.encode(BlockType.markdown, forKey: .type)
            try container.encode(content, forKey: .content)
        case .table(let columns, let rows):
            try container.encode(BlockType.table, forKey: .type)
            try container.encode(columns, forKey: .columns)
            try container.encode(rows, forKey: .rows)
        case .list(let style, let items):
            try container.encode(BlockType.list, forKey: .type)
            try container.encode(style, forKey: .style)
            try container.encode(items, forKey: .items)
        case .json(let value):
            try container.encode(BlockType.json, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum ResultPresentation: Hashable, Sendable {
    case rich(RichResultDocument)
    case plain(String)
}

public enum RichResultParser {
    public static let fenceLanguage = "agent-recipes-result"

    /// pane 出力から最後のリッチ結果を探す。無ければ元のテキストをそのまま返す。
    public static func parse(_ output: String) -> ResultPresentation {
        if let payload = lastFencedPayload(in: output), let document = decode(payload) {
            return .rich(document)
        }

        // CLI やテストから JSON 本体だけを渡した場合にも対応する。
        if let document = decode(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .rich(document)
        }

        // Codex TUI は Markdown のコードフェンスを描画せず、中の JSON だけを pane に残す。
        // Prompt やステータス表示が混ざるため、末尾側から均衡した JSON object を探す。
        if let document = lastEmbeddedDocument(in: output) {
            return .rich(document)
        }
        return .plain(output)
    }

    private static func decode(_ json: String) -> RichResultDocument? {
        if let document = decodeExactly(json) { return document }
        // TUI は幅で折り返すため、文字列の途中に改行が入って JSON が壊れることがある。
        // 改行と行頭の空白を畳んでからもう一度試す。
        let unwrapped = json.replacingOccurrences(
            of: "\n[ \t]*", with: "", options: .regularExpression
        )
        guard unwrapped != json else { return nil }
        return decodeExactly(unwrapped)
    }

    private static func decodeExactly(_ json: String) -> RichResultDocument? {
        guard let data = json.data(using: .utf8),
              let document = try? JSONCoding.decoder.decode(RichResultDocument.self, from: data),
              document.schema == RichResultDocument.schema,
              !document.blocks.isEmpty else {
            return nil
        }
        return document
    }

    private static func lastFencedPayload(in output: String) -> String? {
        let opening = "```\(fenceLanguage)"
        guard let start = output.range(of: opening, options: .backwards) else { return nil }
        let afterOpening = output[start.upperBound...]
        guard let lineBreak = afterOpening.firstIndex(of: "\n") else { return nil }
        let payloadStart = afterOpening.index(after: lineBreak)
        guard let end = output.range(of: "```", range: payloadStart..<output.endIndex) else { return nil }
        return String(output[payloadStart..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lastEmbeddedDocument(in output: String) -> RichResultDocument? {
        let starts = output.indices.filter { output[$0] == "{" }
        for start in starts.reversed() {
            guard let candidate = balancedJSONObject(in: output, from: start) else { continue }
            if let document = decode(candidate) { return document }
        }
        return nil
    }

    /// 文字列リテラル内の括弧を無視し、開始位置から最初の均衡した JSON object を返す。
    private static func balancedJSONObject(in output: String, from start: String.Index) -> String? {
        var stack: [Character] = []
        var inString = false
        var escaping = false
        var index = start

        while index < output.endIndex {
            let character = output[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{", "[": stack.append(character)
                case "}":
                    guard stack.last == "{" else { return nil }
                    stack.removeLast()
                case "]":
                    guard stack.last == "[" else { return nil }
                    stack.removeLast()
                default: break
                }
                if stack.isEmpty {
                    let end = output.index(after: index)
                    return String(output[start..<end])
                }
            }
            index = output.index(after: index)
        }
        return nil
    }
}
