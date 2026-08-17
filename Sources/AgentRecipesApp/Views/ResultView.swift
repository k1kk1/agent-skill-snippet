import SwiftUI
import AppKit
import AgentRecipesCore
import HerdrKit

/// Submit の応答結果。契約済みの JSON はリッチ表示し、それ以外は従来どおり表示する。
struct ResultView: View {
    @ObservedObject var model: AppModel

    @State private var reply: String = ""

    var body: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.recipeName).font(.title3).bold()
                        Text(result.agent.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isAnswering { ProgressView().controlSize(.small) }
                    if let status = result.agent.status {
                        Text(status)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }

                if result.pendingPrompt != nil {
                    Label(
                        "起動時の確認で止まっているため、Prompt はまだ送っていません。答えると送信します。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if let question = result.question {
                    QuestionPromptView(
                        question: question,
                        reply: $reply,
                        disabled: model.isAnswering,
                        onSelect: { model.answer($0, for: result) },
                        onReply: {
                            model.answer(text: reply, for: result)
                            reply = ""
                        }
                    )
                }

                ScrollView([.horizontal, .vertical]) {
                    ResultContentView(presentation: RichResultParser.parse(result.output))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                HStack {
                    Button("Herdr で開く") { model.focusInHerdr(result.agent) }
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.output, forType: .string)
                    }
                    Button("最新を読む", systemImage: "arrow.clockwise") { model.refreshResult() }
                        .disabled(model.isAnswering)
                    Spacer()
                    Label(
                        result.isRich ? "Skill の構造化結果" : "Agent の画面出力",
                        systemImage: result.isRich ? "rectangle.3.group" : "terminal"
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        } else {
            Text("結果がありません")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Agent が確認待ちのときに出す y/n（または番号選択）の回答 UI。
private struct QuestionPromptView: View {
    let question: AgentQuestion
    @Binding var reply: String
    var disabled: Bool
    let onSelect: (AgentQuestion.Option) -> Void
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Agent が確認を求めています", systemImage: "questionmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(question.prompt)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // 選択肢は数が読めないので、折り返すレイアウトにする。
            FlowLayout(spacing: 8) {
                ForEach(question.options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        Text(option.label).lineLimit(1)
                    }
                    .buttonStyle(option.isAffirmative ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
                    .disabled(disabled)
                }
            }

            HStack(spacing: 6) {
                TextField("自由に返信して送る（Enter）", text: $reply)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onReply)
                    .disabled(disabled)
                Button("送信", action: onReply)
                    .disabled(disabled || reply.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.4))
        )
    }
}

/// ボタンスタイルを条件で切り替えるための型消去。
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { configuration in
            AnyView(Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
            }.buttonStyle(style))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// 選択肢を折り返して並べる簡易レイアウト。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: CGFloat = 1
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                height += rowHeight + spacing
                rows += 1
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ResultContentView: View {
    let presentation: ResultPresentation

    var body: some View {
        switch presentation {
        case .plain(let output):
            Text(output)
                .font(.system(.callout, design: .monospaced))
        case .rich(let document):
            RichResultDocumentView(document: document)
        }
    }
}

private struct RichResultDocumentView: View {
    let document: RichResultDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title = document.title, !title.isEmpty {
                Text(title).font(.title2).bold()
            }
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                RichResultBlockView(block: block)
            }
        }
    }
}

private struct RichResultBlockView: View {
    let block: RichResultBlock

    var body: some View {
        switch block {
        case .markdown(let content):
            // 見出し・箇条書きを行ごとに描く。1 つの AttributedString にすると改行が畳まれてしまう。
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    MarkdownLineView(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .table(let columns, let rows):
            RichTableView(columns: columns, rows: rows)

        case .list(let style, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        listMarker(style: style, index: index, item: item)
                            .frame(width: style == .numbered ? 24 : 16, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(listText(style: style, item: item))
                    }
                }
            }

        case .json(let value):
            let text = value.prettyPrinted
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("この JSON をコピー")
            }
        }
    }

    @ViewBuilder
    private func listMarker(style: RichListStyle, index: Int, item: String) -> some View {
        switch style {
        case .bullet:
            Text("•")
        case .numbered:
            Text("\(index + 1).")
        case .checklist:
            Image(systemName: isChecked(item) ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked(item) ? Color.accentColor : Color.secondary)
        }
    }

    private func isChecked(_ item: String) -> Bool {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[x]") || trimmed.hasPrefix("[X]")
    }

    private func listText(style: RichListStyle, item: String) -> String {
        guard style == .checklist else { return item }
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[x]") || trimmed.hasPrefix("[X]") || trimmed.hasPrefix("[ ]") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return item
    }
}

/// Markdown を 1 行ずつ描く。見出しと箇条書きだけ特別扱いし、装飾はインラインで解釈する。
private struct MarkdownLineView: View {
    let line: String

    var body: some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 6)
        } else if let heading = heading(trimmed) {
            Text(inline(heading.text))
                .font(heading.level == 1 ? .title3.bold() : (heading.level == 2 ? .headline : .subheadline.bold()))
                .padding(.top, 2)
        } else if let bullet = bullet(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(bullet)).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(inline(line))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ text: String) -> (level: Int, text: String)? {
        guard text.hasPrefix("#") else { return nil }
        let hashes = text.prefix { $0 == "#" }
        let rest = text.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, hashes.count <= 6 else { return nil }
        return (hashes.count, rest)
    }

    private func bullet(_ text: String) -> String? {
        for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
            return String(text.dropFirst(marker.count))
        }
        return nil
    }

    /// **強調** や `code` はインラインとして解釈する。
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct RichTableView: View {
    let columns: [String]
    let rows: [[String]]

    var body: some View {
        if columns.isEmpty {
            Text("表データがありません").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        tableCell(column, header: true)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(columns.indices, id: \.self) { columnIndex in
                            tableCell(columnIndex < row.count ? row[columnIndex] : "", header: false)
                                .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05))
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func tableCell(_ value: String, header: Bool) -> some View {
        Text(value)
            .font(header ? .headline : .callout)
            .frame(minWidth: 100, maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(header ? Color.secondary.opacity(0.12) : Color.clear)
    }
}
