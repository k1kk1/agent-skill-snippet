import SwiftUI
import AppKit
import AgentRecipesCore
import HerdrKit

struct RecipeManagerView: View {
    @ObservedObject var model: AppModel

    @State private var selectedID: String?
    @State private var draft: Recipe?
    @State private var originalID: String?
    @State private var filter: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                // NavigationSplitView が追加する標準ボタンを、この列で明示的に外す。
                // SwiftUI の API は split view 全体ではなく sidebar 側へ適用する。
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if let draft {
                RecipeEditorView(
                    model: model,
                    recipe: Binding(get: { draft }, set: { self.draft = $0 }),
                    onSave: save,
                    onDelete: delete,
                    onDuplicate: duplicate
                )
            } else {
                emptyState
            }
        }
        // 標準の sidebarToggle はサイドバーを閉じた時にツールバー右端へ移動する。
        // 一貫した操作位置にするため、常にナビゲーション領域に置く独自ボタンを使う。
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.leading")
                }
                .help("サイドバーを表示／非表示")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: createNew) {
                    Label("New Recipe", systemImage: "plus")
                }
                .help("Recipe を追加")
            }
        }
        .onAppear {
            model.reload()
            model.refreshHerdr()
            model.reloadSkills()
            selectInitialRecipeIfNeeded()
        }
        .onChange(of: selectedID) { _, new in
            guard let new, let recipe = model.recipes.first(where: { $0.id == new }) else {
                draft = nil
                originalID = nil
                return
            }
            draft = recipe
            originalID = recipe.id
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(groupedCategories, id: \.self) { category in
                    Section(category.isEmpty ? "Other" : category) {
                        ForEach(recipes(in: category)) { recipe in
                            ManagerRecipeRow(recipe: recipe)
                            .tag(recipe.id)
                        }
                    }
                }
            }
            .searchable(text: $filter, placement: .sidebar)

            Divider()
            HStack {
                Button { createNew() } label: { Image(systemName: "plus") }
                    .help("Recipe を追加")
                Button { NSWorkspace.shared.open(model.layout.recipesDirectory) } label: {
                    Image(systemName: "folder")
                }
                .help("Recipe フォルダを開く")
                Spacer()
                Text("\(model.recipes.count) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    }

    private var visibleRecipes: [Recipe] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.recipes : model.recipes.filter { $0.matches(query) }
    }

    private var groupedCategories: [String] {
        Array(Set(visibleRecipes.map { $0.category ?? "" })).sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func recipes(in category: String) -> [Recipe] {
        visibleRecipes.filter { ($0.category ?? "") == category }
    }

    private func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.recipes.isEmpty ? "square.and.pencil" : "sidebar.left")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(model.recipes.isEmpty ? "最初の Recipe を作成" : "Recipe を選択してください")
                .font(.title3.weight(.semibold))
            Text(model.recipes.isEmpty
                 ? "Prompt をテンプレートとして保存し、コピー・入力・実行をまとめて扱えます。"
                 : "左の一覧から選ぶと、設定と Prompt を編集できます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if model.recipes.isEmpty {
                Button("Recipe を作成", action: createNew)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectInitialRecipeIfNeeded() {
        guard selectedID == nil else { return }
        let initial = model.recipes.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite && !rhs.favorite }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.first
        selectedID = initial?.id
    }

    private func createNew() {
        let recipe = Recipe(
            id: model.recipeRepository.uniqueID(base: "new-recipe"),
            name: "New Recipe",
            category: "Development",
            mode: model.settings.defaultMode
        )
        model.save(recipe, originalID: nil)
        selectedID = recipe.id
    }

    private func save() {
        guard var draft else { return }
        if draft.id.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.id = Recipe.makeID(from: draft.name)
        }
        model.save(draft, originalID: originalID)
        originalID = draft.id
        selectedID = draft.id
        self.draft = draft
        ToastPresenter.shared.show(Toast(message: "'\(draft.name)' を保存しました", isError: false))
    }

    private func delete() {
        guard let draft else { return }
        model.delete(draft)
        selectedID = nil
        self.draft = nil
    }

    private func duplicate() {
        guard var draft else { return }
        draft.id = model.recipeRepository.uniqueID(base: draft.id)
        draft.name += " Copy"
        draft.favorite = false
        model.save(draft, originalID: nil)
        selectedID = draft.id
    }
}

private struct ManagerRecipeRow: View {
    let recipe: Recipe

    private var modeIcon: String {
        switch recipe.mode {
        case .copy: "doc.on.doc"
        case .paste: "text.cursor"
        case .submit: "paperplane.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.name)
                    .lineLimit(1)
                if let description = recipe.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if recipe.favorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .accessibilityLabel("お気に入り")
            }
            Image(systemName: modeIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(recipe.mode.explanation)
        }
        .padding(.vertical, 3)
    }
}

private struct EditorSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .padding(16)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct RecipeEditorView: View {
    @ObservedObject var model: AppModel
    @Binding var recipe: Recipe
    let onSave: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void

    @State private var tagText: String = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                editorHeader
                EditorSection(title: "基本情報", icon: "slider.horizontal.3") {
                    basics
                }
                EditorSection(title: "実行方法", icon: "paperplane") {
                    targetSection
                }
                EditorSection(title: "Prompt", icon: "text.alignleft") {
                    promptSection
                }
                EditorSection(title: "Skill と結果", icon: "sparkles") {
                    skillAndResultSection
                }
                EditorSection(title: "引数", icon: "switch.2") {
                    argumentsSection
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("複製", action: onDuplicate)
                Button("削除", role: .destructive) { showDeleteConfirm = true }
                Spacer()
                Button("実行") { model.activate(recipe, forceForm: true) }
                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(12)
            .background(.bar)
        }
        .confirmationDialog("'\(recipe.name)' を削除しますか?", isPresented: $showDeleteConfirm) {
            Button("削除", role: .destructive, action: onDelete)
        }
        .onAppear { tagText = recipe.tags.joined(separator: ", ") }
        .onChange(of: recipe.id) { _, _ in tagText = recipe.tags.joined(separator: ", ") }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recipe.name.isEmpty ? "名称未設定の Recipe" : recipe.name)
                    .font(.title2.weight(.semibold))
                Text(recipe.mode.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if let description = recipe.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("名前、送信方法、Prompt を設定して保存します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Name") {
                TextField("", text: $recipe.name).labelsHidden()
            }
            LabeledContent("ID") {
                TextField("", text: $recipe.id).labelsHidden()
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("Description") {
                TextField("", text: Binding(
                    get: { recipe.description ?? "" },
                    set: { recipe.description = $0.isEmpty ? nil : $0 }
                )).labelsHidden()
            }
            LabeledContent("Category") {
                TextField("", text: Binding(
                    get: { recipe.category ?? "" },
                    set: { recipe.category = $0.isEmpty ? nil : $0 }
                )).labelsHidden()
            }
            LabeledContent("Tags") {
                TextField("comma separated", text: $tagText)
                    .labelsHidden()
                    .onChange(of: tagText) { _, _ in
                        recipe.tags = tagText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }
            Toggle("Favorite", isOn: $recipe.favorite)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("クリックしたときの動作") {
                Picker("", selection: $recipe.mode) {
                    ForEach(ExecutionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(recipe.mode.explanation).font(.caption2).foregroundStyle(.secondary)
            if recipe.mode == .submit, !recipe.arguments.isEmpty {
                Text("引数が Clipboard や既定値で埋まらないときは、自動で「チャットに入力」になります。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            DisclosureGroup("詳細設定") {
              VStack(alignment: .leading, spacing: 8) {
            LabeledContent("実行するセッション") {
                Picker("", selection: $recipe.target.session) {
                    ForEach(SessionPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .labelsHidden()
            }
            Text(recipe.target.session.explanation).font(.caption2).foregroundStyle(.secondary)

            LabeledContent("Project") {
                Picker("", selection: Binding(
                    get: { recipe.target.projectID ?? "" },
                    set: { recipe.target.projectID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("指定なし").tag("")
                    ForEach(model.projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .labelsHidden()
            }
            Toggle("実行時に Project を選ぶ", isOn: $recipe.target.askProject)

              }
              .padding(.top, 6)
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("prompt.md").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("変数: " + VariableResolver.builtinNames.map { "{{\($0)}}" }.joined(separator: " "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            TextEditor(text: $recipe.body)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            let undeclared = PromptBuilder.undeclaredVariables(in: recipe)
            if !undeclared.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("未定義の変数: \(undeclared.joined(separator: ", "))").font(.caption)
                    Button("引数として追加") {
                        for name in undeclared {
                            recipe.arguments.append(ArgumentSpec(name: name, label: name))
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var argumentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recipe.arguments.isEmpty ? "引数なし" : "\(recipe.arguments.count) 件の引数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    recipe.arguments.append(ArgumentSpec(name: "arg\(recipe.arguments.count + 1)"))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            if recipe.arguments.isEmpty {
                Text("引数なし (選択すると即実行されます)").font(.caption).foregroundStyle(.secondary)
            }

            ForEach($recipe.arguments) { $argument in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("name", text: $argument.name)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 130)
                        TextField("label", text: Binding(
                            get: { argument.label ?? "" },
                            set: { argument.label = $0.isEmpty ? nil : $0 }
                        ))
                        Picker("", selection: $argument.type) {
                            ForEach(ArgumentType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Button {
                            recipe.arguments.removeAll { $0.name == argument.name }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Toggle("必須", isOn: $argument.required)
                        Toggle("Clipboard を既定値に", isOn: $argument.useClipboardAsDefault)
                        TextField("default", text: Binding(
                            get: { argument.defaultValue ?? "" },
                            set: { argument.defaultValue = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var skillAndResultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Skill") {
                Picker("", selection: Binding(
                    get: { recipe.skill?.id ?? "" },
                    set: { selectedID in
                        guard !selectedID.isEmpty else {
                            recipe.skill = nil
                            return
                        }
                        guard let selected = model.skills.first(where: {
                            "\($0.source):\($0.name)" == selectedID
                        }) else { return }
                        recipe.skill = SkillReference(name: selected.name, source: selected.source)
                    }
                )) {
                    Text("指定なし").tag("")
                    if let skill = recipe.skill,
                       !model.skills.contains(where: { $0.name == skill.name && $0.source == skill.source }) {
                        Text("\(skill.displayName) (見つかりません)").tag(skill.id)
                    }
                    ForEach(model.skills) { skill in
                        Text("[\(skill.source)] \(skill.name)").tag("\(skill.source):\(skill.name)")
                    }
                }
                .labelsHidden()
            }
            if model.skills.isEmpty {
                Text("Skillが見つかりません。Settings > Skills で検索先を確認してください。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let skill = recipe.skill, skill.source != model.settings.agent.rawValue {
                Text("選択中のSkillは \(skill.source) 用です。現在のLLM（\(model.settings.agent.displayName)）にも同名Skillを配置してください。")
                    .font(.caption2).foregroundStyle(.orange)
            }

            LabeledContent("結果の形式") {
                Picker("", selection: $recipe.resultFormat) {
                    ForEach(ResultFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
            }
            Text(recipe.resultFormat.explanation).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
