import XCTest
@testable import AgentRecipesCore

final class AgentQuestionParserTests: XCTestCase {
    /// Claude Code の許可プロンプト。番号キーで答える。
    func testNumberedPermissionPromptIsParsed() throws {
        let output = """
        ● Fetch(https://example.com)
          ⎿  Running…

        Do you want to allow Claude to fetch this content?
        ❯ 1. Yes
          2. Yes, and don't ask again for example.com
          3. No, and tell Claude what to do differently
        """
        let question = try XCTUnwrap(AgentQuestionParser.parse(output))
        XCTAssertEqual(question.prompt, "Do you want to allow Claude to fetch this content?")
        XCTAssertEqual(question.options.map(\.label), [
            "Yes",
            "Yes, and don't ask again for example.com",
            "No, and tell Claude what to do differently",
        ])
        XCTAssertEqual(question.options.map(\.keys), [["1"], ["2"], ["3"]])
        XCTAssertEqual(question.options.map(\.isAffirmative), [true, true, false])
    }

    /// ANSI 装飾つきでも読める。
    func testANSIDecoratedPromptIsParsed() throws {
        let output = """
        \u{1B}[1mAllow this command?\u{1B}[0m
        \u{1B}[36m❯ 1. Yes\u{1B}[0m
          2. No
        """
        let question = try XCTUnwrap(AgentQuestionParser.parse(output))
        XCTAssertEqual(question.prompt, "Allow this command?")
        XCTAssertEqual(question.options.count, 2)
    }

    /// `(y/n)` 形式の一行確認。Enter まで送る。
    func testYesNoPromptSendsEnter() throws {
        let output = """
        Some earlier output
        Overwrite existing file? (y/N)
        """
        let question = try XCTUnwrap(AgentQuestionParser.parse(output))
        XCTAssertTrue(question.prompt.contains("Overwrite existing file?"))
        XCTAssertEqual(question.options.map(\.keys), [["y", "enter"], ["n", "enter"]])
    }

    /// 普通の回答を確認と誤検出しない。
    func testNormalAnswerIsNotAQuestion() {
        let output = """
        WEB-RESEARCH
        url   : https://example.com
        points:
        - Swift パッケージの配布を扱う
        - macOS と Linux をサポート
        完了しました。
        """
        XCTAssertNil(AgentQuestionParser.parse(output))
    }

    /// 番号付きの箇条書きが 1 つだけの回答は確認にしない。
    func testSingleNumberedLineIsNotAQuestion() {
        let output = """
        まとめ:
        1. ビルドは通ります
        """
        XCTAssertNil(AgentQuestionParser.parse(output))
    }

    /// 最後の確認だけを見る (過去のやり取りに引きずられない)。
    func testLatestQuestionWins() throws {
        let output = """
        Do you want to allow the first thing?
        ❯ 1. Yes
          2. No

        ● Done.

        Do you want to allow the second thing?
        ❯ 1. Allow
          2. Deny
        """
        let question = try XCTUnwrap(AgentQuestionParser.parse(output))
        XCTAssertEqual(question.prompt, "Do you want to allow the second thing?")
        XCTAssertEqual(question.options.map(\.label), ["Allow", "Deny"])
    }
}
