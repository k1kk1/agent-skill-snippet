import XCTest
@testable import AgentRecipesCore

final class MCPScannerTests: XCTestCase {
    /// Claude Code / Gemini の health check 付き出力。
    func testClaudeStyleOutputIsParsedWithConnectionState() {
        let text = """
        Checking MCP server health...

        github: https://api.githubcopilot.com/mcp/ (HTTP) - ✓ Connected
        playwright: npx @playwright/mcp@latest - ✗ Failed to connect
        internal: node server.js - ⏸ Pending approval
        """
        let servers = MCPScanner.parseListOutput(text)
        XCTAssertEqual(servers.map(\.name), ["github", "playwright", "internal"])
        XCTAssertEqual(servers.map(\.state), [.connected, .failed, .pending])
        XCTAssertEqual(servers[0].detail, "https://api.githubcopilot.com/mcp/ (HTTP)")
    }

    /// 見出しや案内文は行として拾わない。
    func testNoiseLinesAreIgnored() {
        let text = """
        Checking MCP server health...
        No MCP servers configured. Use `claude mcp add` to add a server.
        """
        XCTAssertTrue(MCPScanner.parseListOutput(text).isEmpty)
    }

    func testANSIEscapesAreStripped() {
        let text = "\u{1B}[1mgithub\u{1B}[0m: https://example.com - \u{1B}[32m✓ Connected\u{1B}[0m"
        let servers = MCPScanner.parseListOutput(text)
        XCTAssertEqual(servers.first?.name, "github")
        XCTAssertEqual(servers.first?.state, .connected)
    }

    /// Codex は接続確認しないので、有効／無効だけを見る。
    func testCodexJSONIsParsedAsConfiguredOrDisabled() {
        let json = """
        [
          {"name":"computer-use","enabled":false,"transport":{"type":"stdio","command":"/bin/cu"}},
          {"name":"node_repl","enabled":true,"transport":{"type":"stdio","command":"/bin/node_repl"}}
        ]
        """
        let servers = MCPScanner.parseCodexJSON(json)
        XCTAssertEqual(servers.map(\.name), ["computer-use", "node_repl"])
        XCTAssertEqual(servers.map(\.state), [.disabled, .configured])
        XCTAssertEqual(servers[1].detail, "/bin/node_repl")
    }

    /// CLI が無い LLM は「未インストール」として扱い、失敗にはしない。
    func testMissingCLIIsReportedWithoutServers() {
        let scanner = MCPScanner(locator: { _ in nil }, runner: { _, _, _, _ in ("", "") })
        let inspection = scanner.inspect(agent: .gemini, workingDirectory: NSHomeDirectory())
        XCTAssertFalse(inspection.isInstalled)
        XCTAssertTrue(inspection.servers.isEmpty)
        XCTAssertFalse(inspection.hasFailure)
        XCTAssertNotNil(inspection.message)
    }

    /// MCP 設定は cwd 依存なので、指定した作業ディレクトリで実行する。
    func testInspectRunsInTheGivenWorkingDirectory() {
        final class Box: @unchecked Sendable { var cwd = ""; var arguments: [String] = [] }
        let box = Box()
        let scanner = MCPScanner(
            locator: { "/usr/local/bin/\($0)" },
            runner: { _, arguments, cwd, _ in
                box.cwd = cwd
                box.arguments = arguments
                return ("github: https://example.com - ✓ Connected", "")
            }
        )
        let inspection = scanner.inspect(agent: .claude, workingDirectory: "/tmp/work")
        XCTAssertEqual(box.cwd, "/tmp/work")
        XCTAssertEqual(box.arguments, ["mcp", "list"])
        XCTAssertTrue(inspection.healthChecked)
        XCTAssertEqual(inspection.servers.first?.state, .connected)
        XCTAssertEqual(inspection.summary, "1/1 接続済み")
    }

    func testCodexUsesJSONOutputAndIsNotHealthChecked() {
        final class Box: @unchecked Sendable { var arguments: [String] = [] }
        let box = Box()
        let scanner = MCPScanner(
            locator: { "/usr/local/bin/\($0)" },
            runner: { _, arguments, _, _ in
                box.arguments = arguments
                return (#"[{"name":"a","enabled":true,"transport":{"command":"/bin/a"}}]"#, "")
            }
        )
        let inspection = scanner.inspect(agent: .codex)
        XCTAssertEqual(box.arguments, ["mcp", "list", "--json"])
        XCTAssertFalse(inspection.healthChecked)
        XCTAssertEqual(inspection.summary, "1 件設定（接続確認は非対応）")
    }

    func testFailureIsSummarised() {
        let scanner = MCPScanner(
            locator: { "/usr/local/bin/\($0)" },
            runner: { _, _, _, _ in
                ("a: cmd - ✓ Connected\nb: cmd - ✗ Failed to connect", "")
            }
        )
        let inspection = scanner.inspect(agent: .claude)
        XCTAssertTrue(inspection.hasFailure)
        XCTAssertEqual(inspection.failures.map(\.name), ["b"])
        XCTAssertEqual(inspection.summary, "1 件が接続失敗（1/2 接続済み）")
    }
}

final class MCPGroupingTests: XCTestCase {
    /// 同じ名前の MCP は 1 行にまとめ、LLM ごとの状態を持つ。
    func testSameServerIsGroupedAcrossAgents() {
        let claude = MCPInspection(
            agent: .claude,
            executablePath: "/bin/claude",
            servers: [
                MCPServer(name: "chrome-devtools", detail: "npx chrome-devtools-mcp", state: .connected),
                MCPServer(name: "playwright", state: .failed),
            ],
            healthChecked: true
        )
        let codex = MCPInspection(
            agent: .codex,
            executablePath: "/bin/codex",
            servers: [
                MCPServer(name: "chrome-devtools", state: .configured),
                MCPServer(name: "node_repl", state: .disabled),
            ]
        )

        let groups = MCPInspection.grouped([claude, codex])
        XCTAssertEqual(groups.map(\.name), ["chrome-devtools", "node_repl", "playwright"])

        let chrome = groups[0]
        XCTAssertEqual(chrome.detail, "npx chrome-devtools-mcp")
        XCTAssertTrue(chrome.isActive(for: .claude))
        XCTAssertTrue(chrome.isActive(for: .codex))
        // 未設定の LLM は状態を持たず、アイコンはグレーになる。
        XCTAssertNil(chrome.state(for: .gemini))
        XCTAssertFalse(chrome.isActive(for: .gemini))
        XCTAssertEqual(chrome.activeAgents, [.claude, .codex])

        // 無効 / 接続失敗はアクティブ扱いにしない。
        XCTAssertFalse(groups[1].isActive(for: .codex))
        XCTAssertFalse(groups[2].isActive(for: .claude))
        XCTAssertTrue(groups[2].hasFailure)
    }

    /// 実際の Claude Code 0.x の出力（✔ を使う）も接続済みとして読む。
    func testHeavyCheckmarkIsTreatedAsConnected() {
        let text = """
        Checking MCP server health…

        playwright: npx -y @playwright/mcp@latest - ✔ Connected
        chrome-devtools: npx -y chrome-devtools-mcp@latest - ✔ Connected
        """
        let servers = MCPScanner.parseListOutput(text)
        XCTAssertEqual(servers.map(\.name), ["playwright", "chrome-devtools"])
        XCTAssertEqual(servers.map(\.state), [.connected, .connected])
    }
}

final class DefaultWorkingDirectoryTests: XCTestCase {
    /// 未設定なら Skill 実行用の専用ディレクトリを使う (ホーム直下や保存先ではない)。
    func testFallbackIsDedicatedDirectory() {
        let settings = AppSettings()
        XCTAssertEqual(
            settings.expandedDefaultWorkingDirectory,
            ("~/.agentrecipes" as NSString).expandingTildeInPath
        )
    }

    func testConfiguredPathIsExpanded() {
        var settings = AppSettings()
        settings.defaultWorkingDirectory = "~/src/foo"
        XCTAssertEqual(
            settings.expandedDefaultWorkingDirectory,
            ("~/src/foo" as NSString).expandingTildeInPath
        )
    }

    func testEnsureCreatesTheDirectory() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentrecipes-cwd-\(UUID().uuidString)")
        var settings = AppSettings()
        settings.defaultWorkingDirectory = temp.path
        defer { try? FileManager.default.removeItem(at: temp) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertEqual(settings.ensureDefaultWorkingDirectory(), temp.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
    }
}
