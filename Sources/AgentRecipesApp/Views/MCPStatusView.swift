import SwiftUI
import AppKit
import AgentRecipesCore

extension AgentKind {
    /// グリフに付ける色。背景が透けるぶん、線の色でブランドを示す。
    var tint: Color {
        switch self {
        // Anthropic のクレイオレンジ。
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        // OpenAI のマークは黒／白なので、外観に合わせる。
        case .codex: return .primary
        case .gemini: return .indigo
        }
    }

    /// アイコンを借りる公式アプリと、その中のメニューバー用テンプレート画像。
    ///
    /// アプリ本体のアイコン (icns) は角丸の塗り四角なので、一覧に並べると
    /// 背景のタイルだけが浮いて見える。メニューバー用の画像は背景が透明な
    /// 単色グリフなので、こちらを読んで配色はアプリ側で付ける。
    /// 画像は同梱せず実行時に読むため、ロゴの再配布にもならない。
    var brandGlyph: (bundleIdentifiers: [String], resourceNames: [String])? {
        switch self {
        case .claude:
            return (
                ["com.anthropic.claudefordesktop", "com.anthropic.claude"],
                ["TrayIconTemplate@3x.png", "TrayIconTemplate@2x.png", "TrayIconTemplate.png"]
            )
        case .codex:
            return (
                ["com.openai.codex", "com.openai.chat"],
                ["chatgptTemplate@2x.png", "chatgptTemplate.png"]
            )
        // Gemini / Antigravity は透過のグリフを持たない (icns だけ) ので、
        // 下のフォールバック (4 芒星) で描く。
        case .gemini:
            return nil
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

/// 公式アプリのグリフを 1 度だけ読み出して使い回す。
@MainActor
final class BrandIconCache {
    static let shared = BrandIconCache()
    private var cache: [AgentKind: NSImage?] = [:]

    private init() {}

    func icon(for kind: AgentKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let image = Self.load(kind)
        cache[kind] = image
        return image
    }

    private static func load(_ kind: AgentKind) -> NSImage? {
        guard let glyph = kind.brandGlyph else { return nil }
        let apps = glyph.bundleIdentifiers.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        for app in apps {
            for name in glyph.resourceNames {
                let url = app.appending(path: "Contents/Resources").appending(path: name)
                guard let image = NSImage(contentsOf: url) else { continue }
                // 余白の大きさは公式アプリごとに違うので、絵の部分だけに切り詰める。
                // そのまま並べるとグリフの大きさが揃わない。
                let glyphImage = trimmingTransparentEdges(image) ?? image
                // 単色のテンプレート画像として扱い、色はアプリ側で付ける。
                glyphImage.isTemplate = true
                return glyphImage
            }
        }
        return nil
    }

    /// 透明な余白を落として、絵の部分だけの画像にする。
    private static func trimmingTransparentEdges(_ image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = NSBitmapImageRep(cgImage: cgImage).representationUsingPixels
        else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                // 圧縮のにじみを拾わないよう、ごく薄い点は余白として扱う。
                guard bitmap.alpha(x: x, y: y) > 12 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        // CGImage も走査も左上が原点なので、そのまま切り出せる。
        let box = CGRect(
            x: minX, y: minY,
            width: maxX - minX + 1, height: maxY - minY + 1
        )
        guard let cropped = cgImage.cropping(to: box) else { return nil }
        return NSImage(
            cgImage: cropped,
            size: NSSize(width: cropped.width, height: cropped.height)
        )
    }
}

/// アルファだけを見るための、画素そのままのビットマップ。
private struct PixelAlpha {
    let data: [UInt8]
    let width: Int
    let bytesPerRow: Int
    let alphaOffset: Int

    func alpha(x: Int, y: Int) -> UInt8 {
        data[y * bytesPerRow + x * 4 + alphaOffset]
    }
}

private extension NSBitmapImageRep {
    /// 画素を直接読める形にそろえる。colorAt は 1 画素ずつ色空間の変換が入り、
    /// アイコン数×画素数ぶん呼ぶと目に見えて遅い。
    var representationUsingPixels: PixelAlpha? {
        let width = pixelsWide
        let height = pixelsHigh
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PixelAlpha(data: buffer, width: width, bytesPerRow: width * 4, alphaOffset: 3)
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
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                // 未設定の LLM は薄いグレーにして、使えるものだけ目立たせる。
                .foregroundStyle(active ? kind.tint : Color.secondary.opacity(0.35))
        } else if let gradient = kind.fallbackGradient {
            // Gemini の 4 芒星。カラーのときだけブランド配色のグラデーションで描く。
            // グリフ側は余白を落として枠いっぱいに描くので、記号も揃える。
            Image(systemName: "sparkle")
                .font(.system(size: size))
                .foregroundStyle(active ? AnyShapeStyle(gradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.symbolName)
                .font(.system(size: size * 0.95))
                .foregroundStyle(active ? kind.tint : Color.secondary.opacity(0.35))
                .frame(width: size, height: size)
        }
    }
}

/// MCP 1 件を、対応する LLM のアイコンとともに 1 行で示す。
/// 使える LLM だけカラー、それ以外はグレー。
struct MCPGroupRow: View {
    let group: MCPServerGroup
    /// アイコンを出す LLM。設定で隠したものは渡さない。
    var agents: [AgentKind] = AgentKind.allCases
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
                ForEach(agents, id: \.self) { kind in
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
