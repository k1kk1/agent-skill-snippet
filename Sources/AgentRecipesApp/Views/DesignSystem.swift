import SwiftUI

/// 画面をまたいで同じ余白・間隔を使うための定数。
/// SwiftUI / macOS の標準に寄せて 8 の倍数で刻む。
enum Metrics {
    /// ウィンドウの外周。
    static let windowPadding: CGFloat = 20
    /// セクション同士の間隔。
    static let sectionSpacing: CGFloat = 16
    /// セクション内の要素の間隔。
    static let itemSpacing: CGFloat = 8
    /// ラベルと値の間隔。
    static let labelSpacing: CGFloat = 12
}

/// 見出し + 内容のまとまり。標準の GroupBox に寄せて、素材や角丸を自前で描かない。
struct SectionBox<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Metrics.itemSpacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }
}

/// ウィンドウ下部のアクションバー。
/// macOS の作法どおり、右端を主アクションにして、その左に副次アクションを置く。
struct ActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Metrics.itemSpacing) {
            leading()
            Spacer(minLength: Metrics.labelSpacing)
            trailing()
        }
    }
}

extension View {
    /// パネル系ウィンドウの共通の外周。
    func windowPadding() -> some View {
        padding(Metrics.windowPadding)
    }
}
