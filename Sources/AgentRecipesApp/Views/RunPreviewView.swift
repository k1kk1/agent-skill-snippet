import SwiftUI
import AgentRecipesCore
import HerdrKit

/// 実行前の確認。何が・どこへ送られるかを見せてから実行する。
/// フォーム（引数入力）とは別で、値はすでに解決済み。
struct RunPreviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let preview = model.previewRequest {
            content(preview)
        } else {
            ContentUnavailableView(
                "プレビューする Recipe がありません",
                systemImage: "eye.slash"
            )
        }
    }

    private func content(_ preview: RunPreview) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header(preview)
            choices(preview)
            destination(preview)
            prompt(preview)

            ActionBar {
                if preview.isPreviewOnly {
                    Label("プレビュー。実行はしません", systemImage: "eye")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("次回から確認しない", isOn: Binding(
                        get: { !model.settings.previewBeforeRun },
                        set: { model.settings.previewBeforeRun = !$0 }
                    ))
                    .toggleStyle(.checkbox)
                }
            } trailing: {
                if preview.isPreviewOnly {
                    Button("閉じる") { model.cancelPreview() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("キャンセル") { model.cancelPreview() }
                        .keyboardShortcut(.cancelAction)
                    if preview.mode != .paste {
                        Button("チャットに入力") { model.runPreview(preview, mode: .paste) }
                    }
                    Button(preview.mode.displayName) { model.runPreview(preview) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(hasUnansweredChoice(preview))
                }
            }
            .controlSize(.large)
        }
        .windowPadding()
        .frame(minWidth: 520, minHeight: 460)
        .onChange(of: model.settings) { _, _ in model.scheduleSettingsSave() }
        .onAppear { model.refreshHerdr() }
    }

    /// 必須の選択がまだ埋まっていないか。
    private func hasUnansweredChoice(_ preview: RunPreview) -> Bool {
        preview.choices.contains { argument in
            argument.required && (preview.values[argument.name] ?? "").isEmpty
        }
    }

    private func header(_ preview: RunPreview) -> some View {
        HStack(alignment: .top, spacing: Metrics.labelSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.recipe.name).font(.title3.weight(.semibold))
                if let description = preview.recipe.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if preview.isPreviewOnly {
                Text("プレビュー")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
            // ボタンと紛らわしくならないよう、モードは控えめなラベルで出す。
            Label(preview.mode.displayName, systemImage: preview.mode.editorIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }

    /// 選択式の引数。ここで選んだ値がそのまま Prompt に入る。
    @ViewBuilder
    private func choices(_ preview: RunPreview) -> some View {
        if !preview.choices.isEmpty {
            SectionBox(title: "入力", systemImage: "slider.horizontal.3") {
                ForEach(preview.choices) { argument in
                    LabeledContent {
                        ChoiceField(
                            argument: argument,
                            value: Binding(
                                get: { model.previewRequest?.values[argument.name] ?? "" },
                                set: { model.previewRequest?.values[argument.name] = $0 }
                            )
                        )
                    } label: {
                        HStack(spacing: 2) {
                            Text(argument.displayLabel)
                            if argument.required {
                                Text("*").foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
    }

    /// どこへ送るか。新しいセッションを立てるのかどうかが一番知りたい情報。
    private func destination(_ preview: RunPreview) -> some View {
        let agent = model.settings.agent
        let cwd = preview.project?.path ?? model.settings.expandedDefaultWorkingDirectory
        return SectionBox(title: "送信先", systemImage: "paperplane") {
            LabeledContent("Agent") {
                HStack(spacing: 6) {
                    AgentBrandIcon(kind: agent, active: true, size: 15)
                    Text(sessionText(preview, agent: agent))
                }
            }
            LabeledContent("作業フォルダ") {
                Text(cwd).lineLimit(1).truncationMode(.head)
            }
            if let skill = preview.recipe.skill {
                LabeledContent("Skill") { Text(skill.displayName) }
            }
            LabeledContent("結果") { Text(resultText(preview)) }
        }
    }

    private func sessionText(_ preview: RunPreview, agent: AgentKind) -> String {
        switch preview.recipe.target.session {
        case .newSession:
            return "新しい \(agent.displayName) セッションを起動"
        case .reuseIfAvailable:
            let candidate = TargetResolver().rank(TargetResolver().filter(
                agents: model.agents,
                target: preview.recipe.target,
                project: preview.project,
                agentKind: agent
            )).first { !$0.isWorking }
            if let candidate {
                return "\(candidate.displayName)（\(candidate.status ?? "unknown")）を再利用"
            }
            return "空きが無いため新しい \(agent.displayName) セッションを起動"
        }
    }

    private func resultText(_ preview: RunPreview) -> String {
        guard preview.mode == .submit else { return "チャットに入力するだけで、実行はしません" }
        guard model.settings.waitForResult else { return "送信のみ（応答は待ちません）" }
        let format = preview.recipe.resultFormat.displayName
        return "応答を最大 \(model.settings.resultTimeoutSeconds) 秒待って表示（\(format)）"
    }

    private func prompt(_ preview: RunPreview) -> some View {
        let text = model.preview(
            recipe: preview.recipe,
            values: preview.values,
            project: preview.project
        )
        return SectionBox(title: "送信する Prompt", systemImage: "text.alignleft") {
            if preview.recipe.arguments.contains(where: \.useClipboardAsDefault) {
                Label("クリップボードの内容を含みます", systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }
}
