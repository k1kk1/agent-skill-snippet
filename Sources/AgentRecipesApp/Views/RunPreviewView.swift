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
            Text("プレビューする Recipe がありません")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ preview: RunPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(preview)
            choices(preview)
            destination(preview)
            prompt(preview)

            HStack {
                Toggle("次回から確認しない", isOn: Binding(
                    get: { !model.settings.previewBeforeRun },
                    set: { model.settings.previewBeforeRun = !$0 }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                Spacer()
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
        .padding(16)
        .frame(minWidth: 520, minHeight: 440)
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.recipe.name).font(.title3.weight(.semibold))
                if let description = preview.recipe.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(preview.choices) { argument in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(argument.displayLabel).font(.caption).bold()
                            if argument.required {
                                Text("*").font(.caption).foregroundStyle(.red)
                            }
                        }
                        ChoiceField(
                            argument: argument,
                            value: Binding(
                                get: { model.previewRequest?.values[argument.name] ?? "" },
                                set: { model.previewRequest?.values[argument.name] = $0 }
                            )
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// どこへ送るか。新しいセッションを立てるのかどうかが一番知りたい情報。
    private func destination(_ preview: RunPreview) -> some View {
        let agent = model.settings.agent
        let cwd = preview.project?.path ?? model.settings.expandedDefaultWorkingDirectory
        return VStack(alignment: .leading, spacing: 6) {
            row("送信先", systemImage: "paperplane") {
                HStack(spacing: 6) {
                    AgentBrandIcon(kind: agent, active: true, size: 15)
                    Text(sessionText(preview, agent: agent))
                }
            }
            row("作業フォルダ", systemImage: "folder") {
                Text(cwd).lineLimit(1).truncationMode(.head)
            }
            if let skill = preview.recipe.skill {
                row("Skill", systemImage: "sparkles") {
                    Text(skill.displayName)
                }
            }
            row("結果", systemImage: "rectangle.3.group") {
                Text(resultText(preview))
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func row(
        _ title: String,
        systemImage: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func prompt(_ preview: RunPreview) -> some View {
        let text = model.preview(
            recipe: preview.recipe,
            values: preview.values,
            project: preview.project
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("送信する Prompt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if preview.recipe.arguments.contains(where: \.useClipboardAsDefault) {
                    Label("クリップボードの内容を含みます", systemImage: "doc.on.clipboard")
                        .font(.caption2).foregroundStyle(.purple)
                }
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
