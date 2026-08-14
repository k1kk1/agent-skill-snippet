import XCTest
@testable import AgentRecipesCore
@testable import HerdrKit

final class RichResultTests: XCTestCase {
    private let payload = #"""
    {
      "schema": "agent-recipes.result/v1",
      "title": "Rich Result Test",
      "blocks": [
        {"type": "markdown", "content": "**bold** and [link](https://example.com)"},
        {"type": "table", "columns": ["Name", "Value"], "rows": [["alpha", "1"], ["beta", "2"]]},
        {"type": "list", "style": "checklist", "items": ["[x] parsed", "[ ] rendered"]},
        {"type": "json", "value": {"ok": true, "count": 2}}
      ]
    }
    """#

    func testParsesFencedDocumentOutOfPaneOutput() {
        let output = """
        terminal prompt and old output
        ```agent-recipes-result
        \(payload)
        ```
        status line
        """

        guard case .rich(let document) = RichResultParser.parse(output) else {
            return XCTFail("rich result should be detected")
        }
        XCTAssertEqual(document.schema, RichResultDocument.schema)
        XCTAssertEqual(document.title, "Rich Result Test")
        XCTAssertEqual(document.blocks.count, 4)
        XCTAssertEqual(document.blocks[1], .table(
            columns: ["Name", "Value"], rows: [["alpha", "1"], ["beta", "2"]]
        ))
        XCTAssertEqual(document.blocks[2], .list(
            style: .checklist, items: ["[x] parsed", "[ ] rendered"]
        ))
    }

    func testUsesLastFencedDocument() {
        let old = payload.replacingOccurrences(of: "Rich Result Test", with: "Old")
        let output = """
        ```agent-recipes-result
        \(old)
        ```
        ```agent-recipes-result
        \(payload)
        ```
        """
        guard case .rich(let document) = RichResultParser.parse(output) else {
            return XCTFail("rich result should be detected")
        }
        XCTAssertEqual(document.title, "Rich Result Test")
    }

    func testParsesBareDocument() {
        guard case .rich(let document) = RichResultParser.parse(payload) else {
            return XCTFail("bare JSON should be detected")
        }
        guard case .json(let value) = document.blocks[3] else {
            return XCTFail("JSON block should be decoded")
        }
        XCTAssertTrue(value.prettyPrinted.contains(#""ok" : true"#))
    }

    func testParsesDocumentRenderedWithoutFenceByCodexTUI() {
        let output = """
        › agent-recipes-rich-result-test スキルを使ってください

        • \(payload)

        ────────────────────────────────────────
        status: done
        """
        guard case .rich(let document) = RichResultParser.parse(output) else {
            return XCTFail("embedded JSON should be detected")
        }
        XCTAssertEqual(document.title, "Rich Result Test")
        XCTAssertEqual(document.blocks.count, 4)
    }

    func testEmbeddedParserIgnoresBracesInsideJSONString() {
        let withBraces = payload.replacingOccurrences(
            of: "**bold** and [link](https://example.com)",
            with: "object {value}, array [value], and escaped \\\"quote\\\""
        )
        guard case .rich(let document) = RichResultParser.parse("prefix • \(withBraces) suffix") else {
            return XCTFail("braces in strings should not end the object")
        }
        XCTAssertEqual(document.blocks.count, 4)
    }

    func testUnknownSchemaFallsBackToPlainText() {
        let output = payload.replacingOccurrences(of: RichResultDocument.schema, with: "other/v1")
        XCTAssertEqual(RichResultParser.parse(output), .plain(output))
    }

    func testMalformedFenceFallsBackToPlainText() {
        let output = "```agent-recipes-result\n{broken}\n```"
        XCTAssertEqual(RichResultParser.parse(output), .plain(output))
    }

    func testDocumentRoundTrip() throws {
        let source = RichResultDocument(title: "Round trip", blocks: [
            .markdown("Hello **world**"),
            .list(style: .numbered, items: ["one", "two"]),
            .json(.array([.number(1), .string("two"), .null])),
        ])
        let data = try JSONCoding.encoder.encode(source)
        XCTAssertEqual(try JSONCoding.decoder.decode(RichResultDocument.self, from: data), source)
    }

    /// 手動・CI の実接続確認用。pane id を渡したときだけ Herdr の画面出力を直接解析する。
    func testLiveHerdrPaneWhenConfigured() throws {
        guard let pane = ProcessInfo.processInfo.environment["AGENTRECIPES_RICH_RESULT_PANE"],
              !pane.isEmpty else {
            throw XCTSkip("AGENTRECIPES_RICH_RESULT_PANE が未指定")
        }
        let output = try HerdrClient().readPane(pane, lines: 200)
        guard case .rich(let document) = RichResultParser.parse(output) else {
            return XCTFail("Herdr pane \(pane) の構造化結果を検出できませんでした")
        }
        XCTAssertEqual(document.schema, RichResultDocument.schema)
        XCTAssertEqual(document.blocks.count, 4)
    }
}
