import Foundation
import AgentRecipesCore
#if os(macOS)
import Darwin
#endif

/// Herdr CLI との唯一の接点。
/// UI から直接 herdr を呼ばず、必ずこのクラスを経由する
/// (コマンド生成・JSON デコード・エラー分類を一箇所に集約するため)。
///
/// 実際の CLI (herdr 0.8) に合わせた契約:
/// ```
/// herdr workspace list                  -> {"result":{"workspaces":[...]}}
/// herdr tab list                        -> {"result":{"tabs":[...]}}
/// herdr pane list                       -> {"result":{"panes":[...]}}
/// herdr agent list                      -> {"result":{"agents":[...]}}
/// herdr pane send-text <PANE_ID> <TEXT> -- Paste
/// herdr agent prompt <TARGET> <TEXT>    -- Submit (TARGET は pane_id)
/// herdr agent start <NAME> --kind <KIND> --pane <ID>   (将来)
/// ```
/// 失敗しても終了コードは 0 で、`{"error":{"code","message"}}` が返る点に注意。
public final class HerdrClient: @unchecked Sendable {
    private let explicitPath: String?
    private let log: DebugLog?
    private let runner: any HerdrCommandRunning

    public init(
        executablePath: String? = nil,
        log: DebugLog? = nil,
        runner: (any HerdrCommandRunning)? = nil
    ) {
        let trimmed = executablePath?.trimmingCharacters(in: .whitespaces)
        self.explicitPath = (trimmed?.isEmpty == false) ? trimmed : nil
        self.log = log
        self.runner = runner ?? ProcessHerdrRunner()
    }

    /// herdr 実行ファイルの解決結果。nil なら未インストール。
    public var executablePath: String? {
        if let explicitPath, FileManager.default.isExecutableFile(atPath: explicitPath) {
            return explicitPath
        }
        return HerdrClient.locate()
    }

    public var isInstalled: Bool { executablePath != nil }

    // MARK: - 参照

    public func listWorkspaces() throws -> [HerdrWorkspace] {
        try decode(WorkspaceListResult.self, command: ["workspace", "list"]).workspaces
    }

    public func listTabs() throws -> [HerdrTab] {
        try decode(TabListResult.self, command: ["tab", "list"]).tabs
    }

    public func listPanes() throws -> [HerdrPane] {
        try decode(PaneListResult.self, command: ["pane", "list"]).panes
    }

    public func listAgents() throws -> [HerdrAgent] {
        try decode(AgentListResult.self, command: ["agent", "list"]).agents
    }

    public func agent(target: String) throws -> HerdrAgent {
        try decode(AgentInfoResult.self, command: ["agent", "get", target]).agent
    }

    /// pane の出力を読む。Submit の結果を受け取るために使う。
    /// このコマンドだけは成功時に生テキストを返し、失敗時だけ JSON エンベロープになる。
    public func readPane(_ pane: String, lines: Int = 200) throws -> String {
        let output = try readPane(pane, lines: lines, source: nil)
        // 既定の source (recent) は pane によって空を返すことがあるので、
        // その場合だけ表示中の画面を読み直す。
        guard output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return output }
        return (try? readPane(pane, lines: lines, source: "visible")) ?? output
    }

    private func readPane(_ pane: String, lines: Int, source: String?) throws -> String {
        var args = ["pane", "read", pane, "--lines", String(lines)]
        if let source { args += ["--source", source] }
        let output = try run(args)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let envelope = try? JSONCoding.decoder.decode(HerdrEnvelope<AnyIgnored>.self, from: data),
           let remote = envelope.error {
            throw classify(remote, command: "pane read")
        }
        return output
    }

    /// 接続状態の確認 (メニューバー / Settings 表示用)。
    public func connectionStatus() -> HerdrConnectionStatus {
        guard isInstalled else { return .notInstalled }
        do {
            return .connected(agentCount: try listAgents().count)
        } catch let error as HerdrError {
            if case .notRunning = error { return .notRunning }
            return .error(error.localizedDescription)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - 送信

    /// Paste: pane へ文字列だけ送る (Enter は押さない)。
    public func sendText(_ text: String, toPane pane: String) throws {
        try runVoid(["pane", "send-text", pane, text])
    }

    /// キー入力を送る。Agent の確認 (許可プロンプトや y/n) に答えるために使う。
    /// キー名は herdr の表記に従う (`enter` / `esc` など)。
    public func sendKeys(_ keys: [String], toPane pane: String) throws {
        guard !keys.isEmpty else { return }
        try runVoid(["pane", "send-keys", pane] + keys)
    }

    /// Submit: Agent へ prompt として送る。target は pane_id。
    /// - Parameter waitTimeoutMS: 指定すると、herdr 側で応答が落ち着くまで待つ。
    ///   (送信直後は idle のままのことがあるので、自前で wait せず herdr の --wait を使う)
    public func promptAgent(_ text: String, target: String, waitTimeoutMS: Int? = nil) throws {
        var args = ["agent", "prompt", target, text]
        if let waitTimeoutMS {
            args += ["--wait", "--timeout", String(waitTimeoutMS)]
        }
        try runVoid(args)
    }

    /// Herdr 側でその Agent を前面に出す。結果を確認しに行くときに使う。
    public func focusAgent(target: String) throws {
        try runVoid(["agent", "focus", target])
    }

    // MARK: - 新規 Agent の作成

    /// workspace を作り、同時に生成された最初の root pane を返す。
    public func createWorkspace(cwd: String?, label: String) throws -> HerdrPane {
        var args = ["workspace", "create", "--no-focus"]
        if let cwd { args += ["--cwd", cwd] }
        if !label.isEmpty { args += ["--label", label] }
        return try decode(WorkspaceCreatedResult.self, command: args).rootPane
    }

    /// tab を作り、その root pane を返す。workspaceID 指定時はそのspace内に作る。
    public func createTab(cwd: String?, label: String?, workspaceID: String? = nil) throws -> HerdrPane {
        var args = ["tab", "create", "--no-focus"]
        if let workspaceID { args += ["--workspace", workspaceID] }
        if let cwd { args += ["--cwd", cwd] }
        if let label, !label.isEmpty { args += ["--label", label] }
        return try decode(TabCreatedResult.self, command: args).rootPane
    }

    /// 既存 pane で Agent を起動する。pane はシェルプロンプト状態である必要がある。
    @discardableResult
    public func startAgent(name: String, kind: String, pane: String) throws -> HerdrAgent {
        try decode(AgentStartedResult.self, command: ["agent", "start", name, "--kind", kind, "--pane", pane]).agent
    }

    /// TUI が入力を受け付けられるようになるまで待つ。
    ///
    /// 起動直後の Claude Code / Codex はスプラッシュを描いている間 `interactive_ready` が false で、
    /// この間に `agent prompt` を送っても受理されたように見えて実際には入力が落ちる。
    @discardableResult
    public func waitUntilInteractive(target: String, timeoutMS: Int = 30_000) -> HerdrAgent? {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        var latest: HerdrAgent?
        repeat {
            latest = try? agent(target: target)
            // 情報を返さない herdr でも止まらないよう、不明なら待たない。
            guard let ready = latest?.interactiveReady else { return latest }
            if ready { return latest }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return latest
    }

    /// Agent が受け付けられる状態になるまで待つ。
    /// 起動直後は信頼確認などで blocked になることがあるため、待てなくてもエラーにはしない。
    @discardableResult
    public func waitForAgent(target: String, timeoutMS: Int = 20_000) -> HerdrAgent? {
        let agent = try? decode(
            AgentInfoResult.self,
            command: ["agent", "wait", target, "--until", "idle", "--timeout", String(timeoutMS)]
        ).agent
        return agent ?? (try? self.agent(target: target))
    }

    // MARK: - 内部

    private func decode<Result: Decodable>(_ type: Result.Type, command: [String]) throws -> Result {
        let output = try run(command)
        let label = command.joined(separator: " ")
        guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              !data.isEmpty else {
            throw HerdrError.decodingFailed(command: label)
        }
        let envelope: HerdrEnvelope<Result>
        do {
            envelope = try JSONCoding.decoder.decode(HerdrEnvelope<Result>.self, from: data)
        } catch {
            log?.write("decode failed: \(label): \(error)")
            throw HerdrError.decodingFailed(command: label)
        }
        if let remote = envelope.error { throw classify(remote, command: label) }
        guard let result = envelope.result else { throw HerdrError.decodingFailed(command: label) }
        return result
    }

    /// 出力の中身を使わないコマンド。エラーエンベロープだけ確認する。
    private func runVoid(_ command: [String]) throws {
        let output = try run(command)
        let label = command.prefix(2).joined(separator: " ")
        guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              !data.isEmpty else { return }
        // 送信系は result の形が一定しないので、error の有無だけを見る。
        if let envelope = try? JSONCoding.decoder.decode(HerdrEnvelope<AnyIgnored>.self, from: data),
           let remote = envelope.error {
            throw classify(remote, command: label)
        }
    }

    private func run(_ args: [String]) throws -> String {
        guard let executablePath else { throw HerdrError.notInstalled }
        log?.write("herdr \(args.prefix(2).joined(separator: " "))")

        let result = try runner.run(executable: executablePath, arguments: args, input: nil)
        guard result.exitCode == 0 else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            log?.write("herdr exit \(result.exitCode): \(message)")
            // 一部の Herdr コマンドは非0終了と同時に JSON error envelope を stderr へ返す。
            // code を保持すると、呼び出し側で再試行可能なエラーを判別できる。
            for candidate in [result.standardError, result.standardOutput] {
                if let data = candidate.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                   let envelope = try? JSONCoding.decoder.decode(HerdrEnvelope<AnyIgnored>.self, from: data),
                   let remote = envelope.error {
                    throw classify(remote, command: args.prefix(2).joined(separator: " "))
                }
            }
            if HerdrClient.looksLikeNotRunning(message) {
                throw HerdrError.notRunning(message.isEmpty ? "exit \(result.exitCode)" : message)
            }
            throw HerdrError.commandFailed(
                command: args.prefix(2).joined(separator: " "),
                code: "exit_\(result.exitCode)",
                message: message.isEmpty ? "exit \(result.exitCode)" : message
            )
        }
        return result.standardOutput
    }

    private func classify(_ remote: HerdrRemoteError, command: String) -> HerdrError {
        log?.write("herdr error [\(remote.code)] \(remote.message)")
        if HerdrClient.looksLikeNotRunning(remote.code + " " + remote.message) {
            return .notRunning(remote.message)
        }
        return .commandFailed(command: command, code: remote.code, message: remote.message)
    }

    private static func looksLikeNotRunning(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("not running")
            || lowered.contains("no server")
            || lowered.contains("server_unavailable")
            || lowered.contains("connection refused")
            || lowered.contains("could not connect")
            || lowered.contains("no such file or directory (os error 2)")
    }

    private static func locate() -> String? {
        let candidates = [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/herdr"),
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // PATH からも探す。GUI アプリの PATH は限定的なのであくまで補助。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "herdr"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

/// result の中身に興味がないとき用。
struct AnyIgnored: Decodable {}

public enum HerdrConnectionStatus: Hashable, Sendable {
    case notInstalled
    case notRunning
    case connected(agentCount: Int)
    case error(String)

    public var displayText: String {
        switch self {
        case .notInstalled: return "herdr が見つかりません"
        case .notRunning: return "Herdr が起動していません"
        case .connected(let count): return "接続済み (Agent \(count) 件)"
        case .error(let message): return "エラー: \(message)"
        }
    }

    public var isHealthy: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - コマンド実行

public struct HerdrCommandResult: Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol HerdrCommandRunning: Sendable {
    func run(executable: String, arguments: [String], input: String?) throws -> HerdrCommandResult
}

enum HerdrProcessError: LocalizedError {
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let command): return "herdr が時間内に完了しませんでした: \(command)"
        }
    }
}

/// Swift の Process で `/usr/bin/env herdr ...` を起動する。
struct ProcessHerdrRunner: HerdrCommandRunning {
    /// 通常コマンドの上限。`--timeout` 指定の待機系はその値に余裕を加える。
    let defaultTimeout: TimeInterval
    let timeoutGrace: TimeInterval

    init(defaultTimeout: TimeInterval = 30, timeoutGrace: TimeInterval = 15) {
        self.defaultTimeout = defaultTimeout
        self.timeoutGrace = timeoutGrace
    }

    func run(executable: String, arguments: [String], input: String?) throws -> HerdrCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // stdout / stderr は必ず並行に消費する。片方の pipe が満杯になっても
        // 子プロセスと相互に待ち続けないようにする。
        let group = DispatchGroup()
        let outData = DataBox()
        let errData = DataBox()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            outData.set(data)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errData.set(data)
            group.leave()
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        let timeout = commandTimeout(arguments: arguments)
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 2) == .timedOut {
                #if os(macOS)
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
                _ = terminated.wait(timeout: .now() + 2)
            }
            group.wait()
            throw HerdrProcessError.timedOut(command: ([executable] + arguments.prefix(2)).joined(separator: " "))
        }
        group.wait()

        return HerdrCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData.get(), as: UTF8.self),
            standardError: String(decoding: errData.get(), as: UTF8.self)
        )
    }

    private func commandTimeout(arguments: [String]) -> TimeInterval {
        guard let index = arguments.firstIndex(of: "--timeout"),
              arguments.indices.contains(index + 1),
              let milliseconds = TimeInterval(arguments[index + 1]) else {
            return defaultTimeout
        }
        return max(defaultTimeout, milliseconds / 1_000 + timeoutGrace)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
