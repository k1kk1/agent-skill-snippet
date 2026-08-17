import SwiftUI
import AppKit
import AgentRecipesCore
import HerdrKit

struct RecipeManagerView: View {
    @ObservedObject var model: AppModel

    @State private var selectedItem: SidebarItem?
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
                    onAutoSave: { save(showToast: false) }
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
                Button {
                    PanelPresenter.shared.showSettings(model: model)
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
                .help("設定を開く")
            }
        }
        .onAppear {
            model.reload()
            model.refreshHerdr()
            model.reloadSkills()
            selectInitialRecipeIfNeeded()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            List(selection: Binding(get: { selectedItem }, set: { requestSelection($0) })) {
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { recipe in
                            ManagerRecipeRow(recipe: recipe)
                                .tag(SidebarItem.recipe(recipe.id))
                        }
                    }
                }
                if !unconfiguredSkills.isEmpty {
                    Section("未設定の Skill") {
                        ForEach(unconfiguredSkills) { entry in
                            ManagerSkillRow(skill: entry.skill, sources: entry.sources)
                                .tag(SidebarItem.skill(entry.skill.id))
                        }
                    }
                }
                ForEach(groupedCategories, id: \.self) { category in
                    Section(category.isEmpty ? "Other" : category) {
                        ForEach(recipes(in: category)) { recipe in
                            ManagerRecipeRow(recipe: recipe)
                                .tag(SidebarItem.recipe(recipe.id))
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button { NSWorkspace.shared.open(model.layout.recipesDirectory) } label: {
                    Image(systemName: "folder")
                }
                .help("Recipe フォルダを開く")
                Spacer()
                Text("\(visibleSkills.count) Skills · \(model.recipes.count) Recipes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(minWidth: 320)
        .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 400)
    }

    /// リストの上に固定する検索欄。
    /// `.searchable(placement: .sidebar)` はスクロールした行が透けて重なるため、自前で置く。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $filter)
                .textFieldStyle(.plain)
            // 入力の有無でボタンが出入りすると文字位置がずれるので、場所は常に確保する。
            Button {
                filter = ""
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(filter.isEmpty ? 0 : 1)
            .disabled(filter.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
        .padding(10)
        // サイドバーの素材越しに行が透けないよう、不透明な背景を敷く。
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var visibleRecipes: [Recipe] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.recipes : model.recipes.filter { $0.matches(query) }
    }

    private var visibleSkills: [DiscoveredSkill] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.skills : model.skills.filter { $0.matches(query) }
    }

    private var favorites: [Recipe] {
        visibleRecipes.filter(\.favorite).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// まだ Recipe を持たない Skill。設定済みの Skill は Recipe としてカテゴリに並ぶ。
    /// claude / codex の両方にある同名の Skill は 1 行にまとめる。
    private var unconfiguredSkills: [SkillEntry] {
        var order: [String] = []
        var grouped: [String: SkillEntry] = [:]
        for skill in visibleSkills where recipe(for: skill) == nil {
            if var entry = grouped[skill.name] {
                if !entry.sources.contains(skill.source) { entry.sources.append(skill.source) }
                grouped[skill.name] = entry
            } else {
                order.append(skill.name)
                grouped[skill.name] = SkillEntry(skill: skill, sources: [skill.source])
            }
        }
        return order.compactMap { grouped[$0] }
    }

    /// 同名 Skill をまとめた 1 行分。
    struct SkillEntry: Identifiable {
        var skill: DiscoveredSkill
        var sources: [String]
        var id: String { skill.id }
    }

    private var groupedCategories: [String] {
        Array(Set(visibleRecipes.map { $0.category ?? "" })).sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func recipes(in category: String) -> [Recipe] {
        visibleRecipes
            .filter { ($0.category ?? "") == category }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.skills.isEmpty ? "sparkles" : "sidebar.left")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(model.skills.isEmpty ? "Agent Skill が見つかりません" : "Skill を選択してください")
                .font(.title3.weight(.semibold))
            Text(model.skills.isEmpty
                 ? "~/.claude/skills などに SKILL.md を置くと、ここに並びます。"
                 : "左の一覧から選ぶと、実行方法と Prompt を編集できます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectInitialRecipeIfNeeded() {
        guard selectedItem == nil else { return }
        let initial = visibleRecipes.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite && !rhs.favorite }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.first
        loadRecipe(id: initial?.id)
    }

    private func save(showToast: Bool = true) {
        guard var draft else { return }
        if draft.id.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.id = model.recipeRepository.uniqueID(base: Recipe.makeID(from: draft.name))
        }
        model.save(draft, originalID: originalID)
        originalID = draft.id
        // 保存すると Skill 行はカテゴリ内の Recipe 行に変わるので、選択もそちらへ移す。
        selectedItem = .recipe(draft.id)
        self.draft = draft
        if showToast {
            ToastPresenter.shared.show(Toast(message: "'\(draft.name)' を保存しました", isError: false))
        }
    }

    private var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        guard let originalID else { return true }
        return model.recipes.first(where: { $0.id == originalID }) != draft
    }

    private func requestSelection(_ item: SidebarItem?) {
        guard item != selectedItem else { return }
        if hasUnsavedChanges {
            // 自動保存の待機中でも、画面移動前に最新値を確定させる。
            save(showToast: false)
        }
        switch item {
        case .recipe(let id): loadRecipe(id: id)
        case .skill(let path): selectSkill(path: path)
        case nil: loadRecipe(id: nil)
        }
    }

    private func loadRecipe(id: String?) {
        selectedItem = id.map(SidebarItem.recipe)
        guard let id, let recipe = model.recipes.first(where: { $0.id == id }) else {
            draft = nil
            originalID = nil
            return
        }
        draft = recipe
        originalID = recipe.id
    }

    private func recipe(for skill: DiscoveredSkill) -> Recipe? {
        model.recipes.first {
            $0.skill?.name == skill.name && $0.skill?.source == skill.source
        }
    }

    private func selectSkill(path: String) {
        // Skill 由来の Recipe を開いても、選択は押した Skill 行に残す。
        selectedItem = .skill(path)
        guard let skill = model.skills.first(where: { $0.id == path }) else { return }
        if let existing = recipe(for: skill) {
            draft = existing
            originalID = existing.id
            return
        }

        // Skill 自体は変更せず、Recipe 側に Prompt・入力・実行設定を持つ。
        draft = Recipe(
            id: "",
            name: skill.name,
            description: skill.description,
            category: "Agent Skills",
            skill: SkillReference(name: skill.name, source: skill.source),
            mode: model.settings.defaultMode,
            target: TargetSpec(),
            body: skill.defaultPrompt ?? skill.examples.first ?? ""
        )
        originalID = nil
    }

    private enum SidebarItem: Hashable {
        case recipe(String)
        case skill(String)
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
            // Skill から作った Recipe は、カテゴリに並んでも由来が分かるようにする。
            Image(systemName: recipe.skill == nil ? modeIcon : "sparkles")
                .font(.caption)
                .foregroundStyle(recipe.skill == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 14)
                .help(recipe.skill.map { "Agent Skill: \($0.displayName)" } ?? recipe.mode.explanation)
            VStack(alignment: .leading, spacing: 1) {
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
                    .font(.caption2)
                    .accessibilityLabel("お気に入り")
            }
        }
        .padding(.vertical, 2)
    }
}

/// まだ Recipe を持たない Agent Skill の行。
private struct ManagerSkillRow: View {
    let skill: DiscoveredSkill
    /// 同名 Skill が置かれている場所 (claude / codex)。
    let sources: [String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name)
                    .lineLimit(1)
                Text(skill.description ?? "選択して実行設定を追加")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(sources.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help("Skill を選ぶと、実行方法と Prompt を設定できます")
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
    let onAutoSave: () -> Void

    @State private var tagText: String = ""
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var showsAdvancedBasics = false

    private enum WorkspaceChoice: Hashable {
        case none
        case specified
    }

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
                EditorSection(title: "引数", icon: "switch.2") {
                    argumentsSection
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .onAppear { tagText = recipe.tags.joined(separator: ", ") }
        .onChange(of: recipe.id) { _, _ in tagText = recipe.tags.joined(separator: ", ") }
        .onChange(of: recipe) { _, _ in scheduleAutoSave() }
        .onDisappear { autoSaveTask?.cancel() }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recipe.name.isEmpty ? "名称未設定の Recipe" : recipe.name)
                    .font(.title2.weight(.semibold))
                Button {
                    model.activate(recipe)
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .help("実行")
                Button {
                    recipe.favorite.toggle()
                } label: {
                    Image(systemName: recipe.favorite ? "star.fill" : "star")
                        .foregroundStyle(recipe.favorite ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(recipe.favorite ? "お気に入りから外す" : "お気に入りに追加")
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

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            onAutoSave()
        }
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: 8) {
            basicRow("Name") {
                TextField("", text: $recipe.name).labelsHidden()
            }
            basicRow("Description") {
                TextField("", text: Binding(
                    get: { recipe.description ?? "" },
                    set: { recipe.description = $0.isEmpty ? nil : $0 }
                )).labelsHidden()
            }
            basicRow("Category") {
                TextField("", text: Binding(
                    get: { recipe.category ?? "" },
                    set: { recipe.category = $0.isEmpty ? nil : $0 }
                )).labelsHidden()
            }
            // ID とタグは普段いじらないので畳んでおく。
            DisclosureGroup(isExpanded: $showsAdvancedBasics) {
                VStack(alignment: .leading, spacing: 8) {
                    basicRow("ID") {
                        TextField("", text: $recipe.id).labelsHidden()
                            .font(.system(.body, design: .monospaced))
                    }
                    basicRow("Tags") {
                        TextField("comma separated", text: $tagText)
                            .labelsHidden()
                            .onChange(of: tagText) { _, _ in
                                recipe.tags = tagText
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("ID とタグ").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func basicRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .frame(width: 92, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("デフォルトの動作")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 1) {
                ForEach(ExecutionMode.allCases, id: \.self) { mode in
                    Button {
                        recipe.mode = mode
                    } label: {
                        Label(mode.editorDisplayName, systemImage: mode.editorIcon)
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .foregroundStyle(recipe.mode == mode ? .white : .primary)
                            .background(recipe.mode == mode ? Color.accentColor : .clear)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help(mode.explanation)
                    .accessibilityLabel(mode.editorDisplayName)
                    .accessibilityAddTraits(recipe.mode == mode ? .isSelected : [])
                }
            }
            .padding(1)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if recipe.mode == .submit, !recipe.arguments.isEmpty {
                Label("必要な入力が足りない場合は、チャットに入力してから送信します。", systemImage: "text.cursor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if recipe.mode != .copy {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("送信先", systemImage: "paperplane")
                        .font(.subheadline.weight(.semibold))
                    targetRow("Agent の選び方") {
                        Picker("", selection: $recipe.target.session) {
                            ForEach(SessionPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .labelsHidden()
                    }
                    Text(recipe.target.session.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    targetRow("Herdr workspace") {
                        Picker("", selection: workspaceSelection) {
                            Text("指定なし").tag(WorkspaceChoice.none)
                            Text("指定あり").tag(WorkspaceChoice.specified)
                        }
                        .labelsHidden()
                    }
                    if workspaceSelection.wrappedValue == .specified {
                        targetRow("workspace 名") {
                            HStack(spacing: 6) {
                                TextField("AgentRecipes", text: workspaceNameBinding)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                Menu {
                                    ForEach(model.workspaces) { workspace in
                                        Button(workspace.displayName) {
                                            recipe.target.workspaceID = workspace.id
                                            recipe.target.workspaceName = workspace.displayName
                                        }
                                    }
                                } label: {
                                    Label("既存から選ぶ", systemImage: "list.bullet")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .disabled(model.workspaces.isEmpty)
                            }
                        }
                        Text("その workspace の空き Agent だけを再利用します。同じ名前の workspace が無ければ、実行時に作成します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if recipe.target.session == .reuseIfAvailable {
                        reuseDestination
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("ローカル作業フォルダ", systemImage: "folder")
                            .font(.subheadline.weight(.semibold))
                        if let project = model.project(for: recipe) {
                            HStack(spacing: 8) {
                                Label(project.name, systemImage: "folder.fill")
                                    .font(.callout.weight(.medium))
                                Text(project.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button("変更…") { chooseWorkingDirectory() }
                                Button("解除") {
                                    recipe.target.projectID = nil
                                    recipe.target.askProject = false
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Text("指定なし")
                                    .foregroundStyle(.secondary)
                                Button("ディレクトリを選択…", systemImage: "folder.badge.plus") {
                                    chooseWorkingDirectory()
                                }
                                .buttonStyle(.link)
                            }
                        }
                        Text("Agent の cwd。未設定なら Settings の既定を使います。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if recipe.mode == .submit {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("結果の表示", systemImage: "rectangle.3.group")
                            .font(.subheadline.weight(.semibold))
                        LabeledContent("結果の形式") {
                            Picker("", selection: $recipe.resultFormat) {
                                ForEach(ResultFormat.allCases, id: \.self) { format in
                                    Text(format.displayName).tag(format)
                                }
                            }
                            .labelsHidden()
                        }
                        Text(recipe.resultFormat.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("クリップボードへコピーするだけなので、実行先は設定しません。", systemImage: "clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reuseDestination: some View {
        let project = model.project(for: recipe)
        let resolver = TargetResolver()
        let candidate = resolver.rank(resolver.filter(
            agents: model.agents,
            target: recipe.target,
            project: project,
            agentKind: model.settings.agent
        ))
        .first { !$0.isWorking }

        return Group {
            if let candidate {
                Label(
                    "今回の再利用先: \(candidate.displayName)（\(candidate.status ?? "unknown")）",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .foregroundStyle(.tint)
            } else {
                Label(
                    "再利用できる \(model.settings.agent.displayName) の Agent はありません。新しい Agent を起動します。",
                    systemImage: "plus.circle"
                )
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func chooseWorkingDirectory() {
        if let added = model.addWorkingDirectory() {
            recipe.target.askProject = false
            recipe.target.projectID = added.id
        }
    }

    private var workspaceSelection: Binding<WorkspaceChoice> {
        Binding(
            get: {
                (recipe.target.workspaceID == nil && recipe.target.workspaceName == nil) ? .none : .specified
            },
            set: { selection in
                switch selection {
                case .specified:
                    let workspace = model.workspaces.first
                    recipe.target.workspaceID = workspace?.id
                    recipe.target.workspaceName = workspace?.displayName ?? ""
                case .none:
                    recipe.target.workspaceID = nil
                    recipe.target.workspaceName = nil
                }
            }
        )
    }

    /// 自由入力。既存の workspace 名と一致すればその id も覚えておく。
    private var workspaceNameBinding: Binding<String> {
        Binding(
            get: {
                if let name = recipe.target.workspaceName { return name }
                guard let id = recipe.target.workspaceID else { return "" }
                return model.workspaces.first { $0.id == id }?.displayName ?? id
            },
            set: { name in
                recipe.target.workspaceName = name
                recipe.target.workspaceID = model.workspaces.first {
                    $0.displayName.caseInsensitiveCompare(name) == .orderedSame
                }?.id
            }
        )
    }

    private func targetRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .frame(width: 132, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
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

            // 入力のたびに警告行が出入りすると、編集中にレイアウトが動いてしまう。
            // 行の高さは常に確保しておき、中身だけ切り替える。
            let undeclared = PromptBuilder.undeclaredVariables(in: recipe)
            HStack(spacing: 6) {
                if undeclared.isEmpty {
                    Text(" ").font(.caption)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("未定義の変数: \(undeclared.joined(separator: ", "))").font(.caption)
                    Button("引数として追加") {
                        for name in undeclared {
                            recipe.arguments.append(ArgumentSpec(name: name, label: name))
                        }
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 18)
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
                    recipe.arguments.append(ArgumentSpec(name: nextArgumentName()))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            if recipe.arguments.isEmpty {
                Text("引数なし (選択すると即実行されます)").font(.caption).foregroundStyle(.secondary)
            }

            Toggle("補足プロンプトを受け付ける", isOn: $recipe.acceptsAdditionalPrompt)
            Text("明示した引数とは別に、Skill が判断材料として使える任意のテキストを渡せます。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach($recipe.arguments) { $argument in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Prompt の変数名")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("例: focus", text: $argument.name)
                                .font(.system(.body, design: .monospaced))
                        }
                        .frame(width: 130)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("フォームでの表示名")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("例: 確認項目", text: Binding(
                                get: { argument.label ?? "" },
                                set: { argument.label = $0.isEmpty ? nil : $0 }
                            ))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("形式")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $argument.type) {
                                ForEach(ArgumentType.allCases, id: \.self) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .labelsHidden()
                        }
                        .frame(width: 110)
                        Button {
                            recipe.arguments.removeAll { $0.id == argument.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Toggle("必須", isOn: $argument.required)
                        Toggle("Clipboard を既定値に", isOn: $argument.useClipboardAsDefault)
                        LabeledContent("既定値") {
                            TextField("未指定", text: Binding(
                                get: { argument.defaultValue ?? "" },
                                set: { argument.defaultValue = $0.isEmpty ? nil : $0 }
                            ))
                        }
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func nextArgumentName() -> String {
        var index = 1
        while recipe.arguments.contains(where: { $0.name == "arg\(index)" }) { index += 1 }
        return "arg\(index)"
    }

}
