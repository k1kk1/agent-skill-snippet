import SwiftUI
import AgentRecipesCore
import HerdrKit

/// 引数入力 + Preview + 送信先選択 (Send to...)。
struct RunFormView: View {
    @ObservedObject var model: AppModel

    @State private var values: [String: String] = [:]
    @State private var projectID: String = ""
    @State private var selectedAgentID: String = ""
    @State private var loadedRequestID: UUID?

    private var recipe: Recipe? { model.runRequest?.recipe }

    var body: some View {
        Group {
            if let recipe {
                content(recipe)
            } else {
                Text("Recipe が選択されていません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.runRequest?.id) { _, _ in loadIfNeeded() }
        .onAppear {
            loadIfNeeded()
            model.refreshHerdr()
        }
    }

    private func content(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.name).font(.title3.weight(.semibold))
                    if let description = recipe.description {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label(recipe.mode.displayName, systemImage: modeIcon(recipe.mode))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            if !recipe.arguments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("入力")
                        .font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(recipe.arguments) { argument in
                                ArgumentField(
                                    argument: argument,
                                    value: Binding(
                                        get: { values[argument.name] ?? "" },
                                        set: { values[argument.name] = $0 }
                                    )
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            } else {
                Label("追加の入力なしで実行できます", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reason = model.runRequest?.reason {
                Label(TargetPrompt.describe(reason), systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if recipe.target.askProject || !model.projects.isEmpty {
                projectPicker
            }

            targetPicker(recipe)
            preview(recipe)

            Spacer(minLength: 0)
            buttons(recipe)
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 440)
    }

    private var projectPicker: some View {
        LabeledContent("Project") {
            Picker("", selection: $projectID) {
                Text("指定なし").tag("")
                ForEach(model.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }
            .labelsHidden()
        }
    }

    /// 仕様の "Send to..."。自動解決に任せるか、明示的に Agent を選ぶ。
    private func targetPicker(_ recipe: Recipe) -> some View {
        let candidates = model.runRequest?.candidates.isEmpty == false
            ? model.runRequest!.candidates
            : model.candidates(for: recipe, project: selectedProject)

        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Send to") {
                Picker("", selection: $selectedAgentID) {
                    Text(autoLabel(recipe)).tag("")
                    ForEach(candidates) { agent in
                        Text("\(agent.displayName)\(agent.isIdle ? " (idle)" : "")").tag(agent.id)
                    }
                }
                .labelsHidden()
            }
            if candidates.isEmpty {
                Text(model.connection.isHealthy
                     ? "Herdr に Agent がいません。Copy なら実行できます。"
                     : model.connection.displayText)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func autoLabel(_ recipe: Recipe) -> String {
        let agent = model.settings.agent.displayName
        switch recipe.target.session {
        case .newSession: return "新しい \(agent) セッション"
        case .reuseIfAvailable: return "自動 (空いている \(agent))"
        case .ask: return "選択してください"
        }
    }

    private func preview(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt Preview").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(model.preview(recipe: recipe, values: values, project: selectedProject))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 120)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private func buttons(_ recipe: Recipe) -> some View {
        HStack {
            if let project = selectedProject {
                Label(project.path, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { run(recipe, mode: .copy) } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .tint(recipe.mode == .copy ? .accentColor : .secondary)
            Button { run(recipe, mode: .paste) } label: {
                Label("入力", systemImage: "text.cursor")
            }
            .buttonStyle(.bordered)
            .tint(recipe.mode == .paste ? .accentColor : .secondary)
                .disabled(!canSendToHerdr)
            Button { run(recipe, mode: .submit) } label: {
                Label("実行", systemImage: "paperplane.fill")
            }
            .buttonStyle(.bordered)
            .tint(recipe.mode == .submit ? .accentColor : .secondary)
                .disabled(!canSendToHerdr)
        }
    }

    private func modeIcon(_ mode: ExecutionMode) -> String {
        switch mode {
        case .copy: "doc.on.doc"
        case .paste: "text.cursor"
        case .submit: "paperplane.fill"
        }
    }

    /// Herdr が使えないときは Copy だけ許す。
    private var canSendToHerdr: Bool {
        model.connection.isHealthy
    }

    private var selectedProject: Project? {
        model.projects.first { $0.id == projectID }
    }

    private var selectedAgent: HerdrAgent? {
        let pool = model.runRequest?.candidates.isEmpty == false
            ? model.runRequest!.candidates
            : model.agents
        return pool.first { $0.id == selectedAgentID }
    }

    private func run(_ recipe: Recipe, mode: ExecutionMode) {
        model.execute(
            recipe: recipe,
            values: values.filter { !$0.value.isEmpty },
            project: selectedProject,
            mode: mode,
            agent: mode == .copy ? nil : selectedAgent
        )
    }

    private func loadIfNeeded() {
        guard let request = model.runRequest, loadedRequestID != request.id else { return }
        loadedRequestID = request.id
        values = request.values.isEmpty ? model.initialValues(for: request.recipe) : request.values
        projectID = request.project?.id ?? request.recipe.target.projectID ?? ""
        // 候補が 1 件だけ提示されている場合は最初から選んでおく。
        selectedAgentID = request.candidates.count == 1 ? request.candidates[0].id : ""
    }
}

struct ArgumentField: View {
    let argument: ArgumentSpec
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(argument.displayLabel).font(.caption).bold()
                if argument.required {
                    Text("*").font(.caption).foregroundStyle(.red)
                }
                Text(argument.type.displayName).font(.caption2).foregroundStyle(.tertiary)
            }

            switch argument.type {
            case .multiline:
                TextEditor(text: $value)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            case .string, .url:
                TextField(argument.displayLabel, text: $value)
            }
        }
    }
}
