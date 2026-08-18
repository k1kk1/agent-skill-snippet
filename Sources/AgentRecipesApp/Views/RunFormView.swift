import SwiftUI
import AgentRecipesCore
import HerdrKit

/// 引数入力 + Preview + 送信先選択 (Send to...)。
struct RunFormView: View {
    @ObservedObject var model: AppModel

    @State private var values: [String: String] = [:]
    @State private var additionalPrompt: String = ""
    @State private var projectID: String = ""
    @State private var selectedAgentID: String = ""
    @State private var loadedRequestID: UUID?

    private var recipe: Recipe? { model.runRequest?.recipe }

    var body: some View {
        Group {
            if let recipe {
                content(recipe)
            } else {
                ContentUnavailableView(
                    "Recipe が選択されていません",
                    systemImage: "list.bullet.rectangle"
                )
            }
        }
        .onChange(of: model.runRequest?.id) { _, _ in loadIfNeeded() }
        .onAppear {
            model.refreshClipboardSnapshot()
            loadIfNeeded()
            model.refreshHerdr()
        }
    }

    private func content(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            HStack(alignment: .top, spacing: Metrics.labelSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name).font(.title3.weight(.semibold))
                    if let description = recipe.description {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label(recipe.mode.displayName, systemImage: modeIcon(recipe.mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RecipeInputBadges(recipe: recipe)

            if !recipe.arguments.isEmpty {
                SectionBox(title: "入力", systemImage: "slider.horizontal.3") {
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
                Label(
                    recipe.acceptsAdditionalPrompt ? "補足プロンプトなしで実行できます" : "追加の入力なしで実行できます",
                    systemImage: "checkmark.circle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if recipe.acceptsAdditionalPrompt {
                SectionBox(title: "補足プロンプト（任意）", systemImage: "text.badge.plus") {
                    Text("Skill が許可する範囲の追加条件・背景情報を渡せます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $additionalPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
            }

            if recipe.target.askProject {
                projectPicker
            }

            targetPicker(recipe)
            preview(recipe)

            Spacer(minLength: 0)
            buttons(recipe)
        }
        .windowPadding()
        .frame(minWidth: 480, minHeight: 460)
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
        let allCandidates = model.runRequest?.candidates.isEmpty == false
            ? model.runRequest!.candidates
            : model.candidates(for: recipe, project: selectedProject)
        let candidates = if let workspaceID = recipe.target.workspaceID {
            allCandidates.filter { $0.workspaceID == workspaceID }
        } else {
            allCandidates
        }

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
        }
    }

    private func preview(_ recipe: Recipe) -> some View {
        SectionBox(title: "送信する Prompt", systemImage: "text.alignleft") {
            ScrollView {
                Text(model.preview(
                    recipe: recipe,
                    values: values,
                    project: selectedProject,
                    additionalPrompt: additionalPrompt
                ))
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

    /// 主アクションは Recipe の既定モード。残りは副次アクションとして左に置く。
    private func buttons(_ recipe: Recipe) -> some View {
        ActionBar {
            if let project = selectedProject {
                Label(project.path, systemImage: "folder")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        } trailing: {
            ForEach(ExecutionMode.allCases.filter { $0 != recipe.mode }, id: \.self) { mode in
                Button { run(recipe, mode: mode) } label: {
                    Label(mode.displayName, systemImage: modeIcon(mode))
                }
                .disabled(mode.requiresHerdr && !canSendToHerdr(recipe))
            }
            Button { run(recipe, mode: recipe.mode) } label: {
                Label(recipe.mode.displayName, systemImage: modeIcon(recipe.mode))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(recipe.mode.requiresHerdr && !canSendToHerdr(recipe))
        }
        .controlSize(.large)
    }

    private func modeIcon(_ mode: ExecutionMode) -> String {
        switch mode {
        case .copy: "doc.on.doc"
        case .paste: "text.cursor"
        case .submit: "paperplane.fill"
        }
    }

    /// Herdr が使えないときは Copy だけ許す。
    private func canSendToHerdr(_ recipe: Recipe) -> Bool {
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
            agent: mode == .copy ? nil : selectedAgent,
            additionalPrompt: additionalPrompt
        )
    }

    private func loadIfNeeded() {
        guard let request = model.runRequest, loadedRequestID != request.id else { return }
        loadedRequestID = request.id
        values = request.values.isEmpty ? model.initialValues(for: request.recipe) : request.values
        additionalPrompt = request.additionalPrompt
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
                Label(argument.type.displayName, systemImage: argument.type.symbolName)
                    .font(.caption2).foregroundStyle(.tertiary)
                if argument.useClipboardAsDefault {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                        .font(.caption2).foregroundStyle(.purple)
                }
            }

            switch argument.type {
            case .multiline:
                TextEditor(text: $value)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            case .choice:
                ChoiceField(argument: argument, value: $value)
            case .string, .url:
                TextField(argument.displayLabel, text: $value)
            }
        }
    }
}

/// 選択式の入力。プルダウンか、並べたボタンで値を選ぶ。
/// 複数選択のときは、選んだ順ではなく選択肢の並び順で連結する。
struct ChoiceField: View {
    let argument: ArgumentSpec
    @Binding var value: String

    private var options: [String] { argument.normalizedOptions }

    private var selected: Set<String> {
        Set(argument.allowsMultiple ? ArgumentSpec.selectedValues(value) : (value.isEmpty ? [] : [value]))
    }

    var body: some View {
        if options.isEmpty {
            Text("選択肢が設定されていません")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if argument.choiceStyle == .buttons {
            buttons
        } else if argument.allowsMultiple {
            multiMenu
        } else {
            singleMenu
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    toggle(option)
                } label: {
                    HStack(spacing: 4) {
                        if argument.allowsMultiple {
                            Image(systemName: selected.contains(option) ? "checkmark.square.fill" : "square")
                                .font(.caption2)
                        }
                        Text(option).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(selected.contains(option) ? .accentColor : .secondary)
            }
        }
    }

    /// 複数選択のプルダウン。開いたまま複数チェックできる。
    private var multiMenu: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { selected.contains(option) },
                    set: { _ in toggle(option) }
                ))
            }
        } label: {
            Text(value.isEmpty ? "未選択" : value)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }

    private var singleMenu: some View {
        Picker("", selection: $value) {
            if !options.contains(value) {
                Text(value.isEmpty ? "未選択" : value).tag(value)
            }
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .labelsHidden()
    }

    private func toggle(_ option: String) {
        guard argument.allowsMultiple else {
            value = option
            return
        }
        var next = selected
        if next.contains(option) { next.remove(option) } else { next.insert(option) }
        value = argument.joined(Array(next))
    }
}
