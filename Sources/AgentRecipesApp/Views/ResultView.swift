import SwiftUI
import AppKit
import AgentRecipesCore
import HerdrKit

/// Submit の応答結果。契約済みの JSON はリッチ表示し、それ以外は従来どおり表示する。
struct ResultView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.recipeName).font(.title3).bold()
                        Text(result.agent.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let status = result.agent.status {
                        Text(status)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
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
                    Spacer()
                    Text(result.isRich ? "Skill の構造化結果を表示しています" : "Agent の画面出力をそのまま読み取っています")
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
            if let markdown = try? AttributedString(markdown: content) {
                Text(markdown).font(.body)
            } else {
                Text(content).font(.body)
            }

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
            ScrollView(.horizontal) {
                Text(value.prettyPrinted)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
