import SwiftUI
import AppKit
import AgentRecipesCore

extension AgentKind {
    /// 本家アイコンが無いときのフォールバック色。
    var tint: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .teal
        case .gemini: return .indigo
        }
    }

    /// アイコンを借りる公式アプリ。インストールされていればそのアイコンを使う。
    /// アプリ側にロゴ画像を同梱しないので、再配布の問題が起きない。
    var brandBundleIdentifiers: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex: return ["com.openai.codex", "com.openai.chat"]
        // Gemini 単体の macOS アプリは無いので、同じ Google の Antigravity を代用する。
        // どちらも無ければ下のフォールバック（4 芒星）で描く。
        case .gemini: return [
            "com.google.gemini", "com.google.Gemini",
            "com.google.antigravity", "com.google.antigravity-ide",
        ]
        }
    }

    /// 公式アプリが無いときのフォールバック配色。Gemini だけグラデーションにする。
    var fallbackGradient: LinearGradient? {
        guard self == .gemini else { return nil }
        return LinearGradient(
            colors: [
                Color(red: 0.26, green: 0.52, blue: 0.96),
                Color(red: 0.61, green: 0.45, blue: 0.80),
                Color(red: 0.85, green: 0.40, blue: 0.44),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// 公式アプリのアイコンを 1 度だけ読み出して使い回す。
@MainActor
final class BrandIconCache {
    static let shared = BrandIconCache()
    private var cache: [AgentKind: NSImage?] = [:]

    private init() {}

    func icon(for kind: AgentKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let url = kind.brandBundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[kind] = image
        return image
    }
}

/// LLM を表すアイコン。使える状態のときだけカラーで描く。
struct AgentBrandIcon: View {
    let kind: AgentKind
    var active: Bool
    var failed: Bool = false
    var size: CGFloat = 15

    var body: some View {
        icon
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: size * 0.55))
                        .foregroundStyle(.orange)
                        .offset(x: size * 0.2, y: size * 0.2)
                }
            }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = BrandIconCache.shared.icon(for: kind) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                // 未設定の LLM はモノクロに落として、使えるものだけ目立たせる。
                .grayscale(active ? 0 : 1)
                .opacity(active ? 1 : 0.4)
        } else if let gradient = kind.fallbackGradient {
            // Gemini の 4 芒星。カラーのときだけブランド配色のグラデーションで描く。
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.9))
                .foregroundStyle(active ? AnyShapeStyle(gradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.symbolName)
                .font(.system(size: size * 0.85))
                .foregroundStyle(active ? kind.tint : Color.secondary.opacity(0.35))
                .frame(width: size, height: size)
        }
    }
}

/// MCP 1 件を、対応する LLM のアイコンとともに 1 行で示す。
/// 使える LLM だけカラー、それ以外はグレー。
struct MCPGroupRow: View {
    let group: MCPServerGroup
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(group.name)
                .font(compact ? .caption : .callout)
                .lineLimit(1)
            if !compact, let detail = group.detail {
                Text(detail)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            HStack(spacing: compact ? 5 : 7) {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    let state = group.state(for: kind)
                    AgentBrandIcon(
                        kind: kind,
                        active: group.isActive(for: kind),
                        failed: state == .failed,
                        size: compact ? 13 : 16
                    )
                    .help("\(kind.displayName): \(state?.displayName ?? "未設定")")
                    .accessibilityLabel("\(kind.displayName) \(state?.displayName ?? "未設定")")
                }
            }
        }
    }
}
