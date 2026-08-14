import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Clipboard アクセスを抽象化する。テストでは差し替える。
public protocol ClipboardAccess: Sendable {
    func read() -> String
    func write(_ string: String)
}

public struct SystemClipboard: ClipboardAccess {
    public init() {}

    public func read() -> String {
        #if canImport(AppKit)
        NSPasteboard.general.string(forType: .string) ?? ""
        #else
        ""
        #endif
    }

    public func write(_ string: String) {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        #endif
    }
}

/// ユーザー入力以外の Built-in Variables。
/// MVP は clipboard / date / time / project / cwd の 5 つ。
public struct VariableResolver: Sendable {
    public static let builtinNames = ["clipboard", "date", "time", "project", "cwd"]

    public let clipboard: ClipboardAccess
    private let now: @Sendable () -> Date

    public init(
        clipboard: ClipboardAccess = SystemClipboard(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clipboard = clipboard
        self.now = now
    }

    /// 送信先として解決された Project を踏まえて値を作る。
    public func values(project: Project?) -> [String: String] {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let stamp = now()

        return [
            "clipboard": clipboard.read(),
            "date": date.string(from: stamp),
            "time": time.string(from: stamp),
            "project": project?.name ?? "",
            "cwd": project?.expandedPath ?? "",
        ]
    }
}
