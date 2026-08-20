import SwiftUI
import AgentRecipesCore
import HerdrKit

/// メニューバーの主導線。Search / Favorites / Recent / Projects / Categories。
struct MenuBarView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @FocusState private var searchFocused: Bool
    /// 展開している Projects / Categories。
    @State private var expandedGroups: Set<String> = []
    /// ↑↓ で選んでいる行。Enter で実行する。
    @State private var highlightedID: Recipe.ID?

    /// Projects / Categories に分けるのは、数が多いときだけにする。
    /// 件数が少ないと、階層が深いぶん探しにくくなる。
    private static let groupingThreshold = 12

    /// ↑↓ でたどれる行。検索中は結果、通常は画面に出ている順。
    private var navigable: [Recipe] {
        if !model.searchText.isEmpty { return model.filtered }
        var seen = Set<Recipe.ID>()
        return (model.favorites + model.recents + flatRecipes).filter { seen.insert($0.id).inserted }
    }

    /// グループを作らないときに並べる Recipe。
    private var flatRecipes: [Recipe] {
        let pinned = Set((model.favorites + model.recents).map(\.id))
        return model.filtered.filter { !pinned.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.labelSpacing) {
                        if model.filtered.isEmpty {
                            emptyState
                        } else if !model.searchText.isEmpty {
                            section("Results", model.filtered)
                        } else {
                            if !model.favorites.isEmpty { section("Favorites", model.favorites) }
                            if !model.recents.isEmpty { section("Recent", model.recents) }
                            if model.recipes.count > Self.groupingThreshold {
                                projectsSection
                                categoriesSection
                                if !model.uncategorized.isEmpty { section("Other", model.uncategorized) }
                            } else if !flatRecipes.isEmpty {
                                section("All", flatRecipes)
                            }
                        }
                    }
                    .padding(.vertical, Metrics.itemSpacing)
                }
                .frame(maxHeight: 400)
                .onChange(of: highlightedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: .center) }
                }
            }

            Divider()
            herdrStatus
            // Herdr の Agent と MCP は別の話なので、区切って並べる。
            if showsMCPSection {
                Divider()
                mcpStatus
            }
            Divider()
            footer
        }
        .frame(width: 330)
        .onAppear {
            model.reload()
            model.refreshClipboardSnapshot()
            model.refreshHerdr()
            // 結果が古いときだけ調べ直す (health check に数秒かかるため)。
            model.refreshMCP()
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search...", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { activateHighlighted() }
                // ↑↓ で選べないと、検索したあと結局マウスに戻ることになる。
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onChange(of: model.searchText) { _, _ in
                    highlightedID = model.filtered.first?.id
                }
            // 入力の有無でボタンが出入りすると文字位置がずれるので、場所は常に確保する。
            Button {
                model.searchText = ""
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(model.searchText.isEmpty ? 0 : 1)
            .disabled(model.searchText.isEmpty)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.recipes.isEmpty ? "Skill を設定すると、ここに並びます" : "一致する Recipe がありません")
                .foregroundStyle(.secondary)
            if model.recipes.isEmpty {
                Button("Manage Recipes...") {
                    dismiss()
                    PanelPresenter.shared.showManager(model: model)
                }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var projectsSection: some View {
        let projects = model.projects.filter { !model.recipes(forProject: $0).isEmpty }
        if !projects.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Projects")
                ForEach(projects) { project in
                    expandableGroup(
                        id: "project:" + project.id,
                        title: project.name,
                        systemImage: "folder",
                        recipes: model.recipes(forProject: project)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        if !model.categories.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Categories")
                ForEach(model.categories, id: \.self) { category in
                    expandableGroup(
                        id: "category:" + category,
                        title: category,
                        systemImage: "square.grid.2x2",
                        recipes: model.recipes(inCategory: category)
                    )
                }
            }
        }
    }

    /// その場で開く折りたたみ。ポップアップメニューだと、狙っていない項目を
    /// クリックしやすく、Recent などの一覧とも操作感が変わってしまう。
    @ViewBuilder
    private func expandableGroup(
        id: String,
        title: String,
        systemImage: String,
        recipes: [Recipe]
    ) -> some View {
        let isExpanded = expandedGroups.contains(id)
        VStack(alignment: .leading, spacing: 2) {
            MenuRowButton(
                title: title,
                systemImage: systemImage,
                accessory: "\(recipes.count)",
                chevron: isExpanded ? "chevron.down" : "chevron.right"
            ) {
                if isExpanded {
                    expandedGroups.remove(id)
                } else {
                    expandedGroups.insert(id)
                }
            }
            if isExpanded {
                ForEach(recipes) { recipe in
                    row(recipe)
                }
            }
        }
    }

    /// Herdr の状態 (接続と Agent 数)。MVP の前提なので常に見せる。
    private var herdrStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.pendingResults.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("応答待ち: \(model.pendingResults.map(\.recipeName).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12)
            }
            statusLine
        }
        .padding(.vertical, 6)
    }

    private var showsMCPSection: Bool {
        model.settings.showMCPInMenu && (!model.mcpGroups.isEmpty || !model.mcpChecking.isEmpty)
    }

    /// MCP が使えないと Skill の実行が途中で止まるので、接続状態をここで見せる。
    /// 行は MCP ごと。使える LLM のアイコンだけカラーになる。
    @ViewBuilder
    private var mcpStatus: some View {
        let groups = model.mcpGroups
        if showsMCPSection {
            Button {
                dismiss()
                PanelPresenter.shared.showSettings(model: model, tab: .mcp)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("MCP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if !model.mcpChecking.isEmpty {
                            ProgressView().controlSize(.small)
                        }
                        Spacer(minLength: 0)
                        if groups.count > Self.visibleMCPRows {
                            Text("\(groups.count) 件")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if model.currentMCPFailures.isEmpty == false {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    // 件数が多いとメニューが伸び続けるので、5 行までにして残りはスクロール。
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(groups) { group in
                                MCPGroupRow(
                                    group: group,
                                    agents: model.settings.mcpVisibleAgents,
                                    compact: true
                                )
                            }
                        }
                    }
                    .frame(maxHeight: Self.mcpListMaxHeight(rows: groups.count))
                    .scrollDisabled(groups.count <= Self.visibleMCPRows)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .help("Settings の MCP タブを開く")
            .padding(.vertical, 6)
        }
    }

    /// スクロールせずに出す最大行数。
    private static let visibleMCPRows = 5
    private static let mcpRowHeight: CGFloat = 19

    private static func mcpListMaxHeight(rows: Int) -> CGFloat {
        CGFloat(min(rows, visibleMCPRows)) * mcpRowHeight
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Text("Herdr").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Circle()
                .fill(model.connection.isHealthy ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.connection.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.refreshHerdr()
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    private func section(_ title: String, _ recipes: [Recipe]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle(title)
            ForEach(recipes) { recipe in
                row(recipe)
            }
        }
    }

    private func row(_ recipe: Recipe) -> some View {
        RecipeRow(
            recipe: recipe,
            effectiveMode: model.effectiveMode(recipe),
            isHighlighted: highlightedID == recipe.id,
            isRunning: model.isRunning(recipe)
        ) { forceForm in
            dismiss()
            model.activate(recipe, forceForm: forceForm)
        }
        .id(recipe.id)
    }

    /// ↑↓ の移動。端では止める (行き過ぎて先頭に戻ると、どこにいるか分からなくなる)。
    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        let rows = navigable
        guard !rows.isEmpty else { return .ignored }
        let current = highlightedID.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = min(max((current ?? -1) + offset, 0), rows.count - 1)
        highlightedID = rows[next].id
        return .handled
    }

    private func activateHighlighted() {
        let rows = navigable
        let recipe = highlightedID.flatMap { id in rows.first { $0.id == id } } ?? rows.first
        guard let recipe else { return }
        dismiss()
        model.activate(recipe)
    }

    /// セクション見出し。macOS のサイドバー見出しに合わせて小さめ・控えめにする。
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRowButton(title: "Manage Recipes...") {
                dismiss()
                PanelPresenter.shared.showManager(model: model)
            }
            // 結果を閉じたあとでも辿れる入口。Settings の中だけだと見つからない。
            MenuRowButton(title: "History...") {
                dismiss()
                PanelPresenter.shared.showSettings(model: model, tab: .history)
            }
            MenuRowButton(title: "Settings...") {
                dismiss()
                PanelPresenter.shared.showSettings(model: model)
            }
            MenuRowButton(title: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Recipe 1 行。クリックで実行し、⌥ クリック・右クリックで詳細を指定する。
struct RecipeRow: View {
    let recipe: Recipe
    /// クリックしたときに実際に起きること。
    let effectiveMode: ExecutionMode
    /// ↑↓ で選ばれている行。
    var isHighlighted = false
    /// 実行中。結果が返るまでローディングを出す。
    var isRunning = false
    let action: (_ forceForm: Bool) -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: 9) {
                Text(recipe.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 場所が足りないときに縮むのは名前。記号は動かさない。
                    .layoutPriority(0)
                Spacer(minLength: 4)
                if showsAction {
                    trailingAccessory.layoutPriority(1)
                }
                RecipeInputBadges(recipe: recipe)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(background)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 詳細の入口はボタンを増やさず、⌥ クリックと右クリックに寄せる。
        .contextMenu {
            // 1 行目はクリックしたときと同じ動き。
            Button(effectiveMode.displayName) { action(false) }
            Button("入力と送信先を指定して実行...") { action(true) }
        }
        .help("\(recipe.description ?? recipe.name)\n\(effectiveMode.explanation)\n⌥クリックまたは右クリックで詳細を指定")
    }

    /// 記号の代わりに出すもの。実行中が最優先。
    private var showsAction: Bool { isRunning || hovering || isHighlighted }

    @ViewBuilder
    private var trailingAccessory: some View {
        HStack(spacing: 5) {
            if isRunning {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("実行中")
            } else {
                Text(effectiveMode.displayName)
                Image(systemName: "return")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var background: Color {
        if isHighlighted { return Color.accentColor.opacity(0.25) }
        return hovering ? Color.accentColor.opacity(0.15) : .clear
    }
}

struct MenuRowButton: View {
    let title: String
    /// 見出しに付けるアイコン (Projects / Categories 用)。
    var systemImage: String?
    /// 右端に出す補足 (件数など)。
    var accessory: String?
    /// 開閉を示す記号。折りたたみの見出しにだけ付ける。
    var chevron: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let chevron {
                    Image(systemName: chevron)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                Spacer(minLength: 4)
                if let accessory {
                    Text(accessory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
