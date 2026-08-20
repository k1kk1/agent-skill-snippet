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
            inputs(preview)
            destination(preview)
            prompt(preview)

            ActionBar {
                if preview.isPreviewOnly {
                    Label("プレビュー。実行はしません", systemImage: "eye")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    // 設定を書き換えるだけだと保存されず、次の起動で戻ってしまう。
                    Toggle("次回から確認しない", isOn: Binding(
                        get: { !model.settings.previewBeforeRun },
                        set: {
                            model.settings.previewBeforeRun = !$0
                            model.scheduleSettingsSave()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .help("Settings の General からいつでも戻せます")
                }
            } trailing: {
                if preview.isPreviewOnly {
                    Button("閉じる") { model.cancelPreview() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("キャンセル") { model.cancelPreview() }
                        .keyboardShortcut(.cancelAction)
                    ForEach(ExecutionMode.allCases.filter { $0 != preview.mode }, id: \.self) { mode in
                        if preview.showsDetails || mode == .paste {
                            Button(mode.displayName) { model.runPreview(preview, mode: mode) }
                                .disabled(mode.requiresHerdr && !model.connection.isHealthy)
                        }
                    }
                    Button {
                        model.runPreview(preview)
                    } label: {
                        // 一覧から消した記号は、この実行ボタンに集約する。
                        Label(preview.mode.displayName, systemImage: preview.mode.symbolName)
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(hasMissingInput(preview))
                }
            }
            .controlSize(.large)
        }
        .windowPadding()
        .frame(minWidth: 520, minHeight: 460)
        .onChange(of: model.settings) { _, _ in model.scheduleSettingsSave() }
        .onAppear { model.refreshHerdr() }
    }

    /// 必須の入力がまだ埋まっていないか。
    private func hasMissingInput(_ preview: RunPreview) -> Bool {
        preview.recipe.arguments.contains { argument in
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
            Label(preview.mode.displayName, systemImage: preview.mode.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }

    /// 引数の入力。通常は選択式だけ、⌥ クリックなどの詳細表示ではすべて出す。
    /// 補足はいつでも書ける。
    private func inputs(_ preview: RunPreview) -> some View {
        SectionBox(title: "入力", systemImage: "slider.horizontal.3") {
            ForEach(preview.editableArguments) { argument in
                LabeledContent {
                    ArgumentField(
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
            // Recipe ごとの設定にすると、⌥ クリックを知らない限り一度も使えないままになる。
            // 送る前にひとこと足せる場所として、この画面に常駐させる。
            LabeledContent("補足") {
                TextEditor(text: Binding(
                    get: { model.previewRequest?.additionalPrompt ?? "" },
                    set: { model.previewRequest?.additionalPrompt = $0 }
                ))
                .font(.system(.callout, design: .monospaced))
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            }
        }
    }

    /// どこへ送るか。新しいセッションを立てるのかどうかが一番知りたい情報。
    private func destination(_ preview: RunPreview) -> some View {
        let agent = model.settings.agent
        let cwd = preview.project?.path ?? model.settings.expandedDefaultWorkingDirectory
        return SectionBox(title: "送信先", systemImage: "paperplane") {
            if preview.showsDetails {
                if preview.recipe.target.askProject {
                    LabeledContent("作業フォルダ") {
                        Picker("", selection: Binding(
                            get: { model.previewRequest?.project?.id ?? "" },
                            set: { id in
                                model.previewRequest?.project = model.projects.first { $0.id == id }
                            }
                        )) {
                            Text("指定なし").tag("")
                            ForEach(model.projects) { project in
                                Text(project.name).tag(project.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
                LabeledContent("送信先 Agent") {
                    Picker("", selection: Binding(
                        get: { model.previewRequest?.agentID ?? "" },
                        set: { model.previewRequest?.agentID = $0 }
                    )) {
                        Text(sessionText(preview, agent: agent)).tag("")
                        ForEach(model.candidates(for: preview.recipe, project: preview.project)) { candidate in
                            Text("\(candidate.displayName)\(candidate.isIdle ? " (idle)" : "")")
                                .tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                }
            } else {
                LabeledContent("送信先 Agent") {
                    HStack(spacing: 6) {
                        AgentBrandIcon(kind: agent, active: true, size: 15)
                        Text(sessionText(preview, agent: agent))
                    }
                }
            }
            if !preview.showsDetails || !preview.recipe.target.askProject {
                LabeledContent("作業フォルダ") {
                    Text(cwd).lineLimit(1).truncationMode(.head)
                }
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
