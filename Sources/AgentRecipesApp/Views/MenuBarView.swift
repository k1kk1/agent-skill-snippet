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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.filtered.isEmpty {
                        emptyState
                    } else if !model.searchText.isEmpty {
                        section("Results", model.filtered)
                    } else {
                        if !model.favorites.isEmpty { section("★ Favorites", model.favorites) }
                        if !model.recents.isEmpty { section("Recent", model.recents) }
                        projectsSection
                        categoriesSection
                        if !model.uncategorized.isEmpty { section("Other", model.uncategorized) }
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 400)

            Divider()
            herdrStatus
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
                .onSubmit {
                    model.filtered.first.map {
                        dismiss()
                        model.activate($0)
                    }
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
            Text(model.recipes.isEmpty ? "Recipe がまだありません" : "一致する Recipe がありません")
                .foregroundStyle(.secondary)
            if model.recipes.isEmpty {
                Button("Recipe を作成...") {
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
                    RecipeRow(recipe: recipe, effectiveMode: model.effectiveMode(recipe)) { forceForm in
                        dismiss()
                        model.activate(recipe, forceForm: forceForm)
                    }
                }
            }
        }
    }

    /// Herdr は MVP の前提なので、常に状態が見えるようにしておく。
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
            mcpStatus
        }
        .padding(.vertical, 6)
    }

    /// MCP が使えないと Skill の実行が途中で止まるので、接続状態をここで見せる。
    /// 行は MCP ごと。使える LLM のアイコンだけカラーになる。
    @ViewBuilder
    private var mcpStatus: some View {
        let groups = model.mcpGroups
        if model.settings.showMCPInMenu, !groups.isEmpty || !model.mcpChecking.isEmpty {
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
                RecipeRow(recipe: recipe, effectiveMode: model.effectiveMode(recipe)) { forceForm in
                    dismiss()
                    model.activate(recipe, forceForm: forceForm)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption).bold()
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

/// Recipe 1 行。⌥ クリックで入力・Preview を強制表示する。
struct RecipeRow: View {
    let recipe: Recipe
    /// クリックしたときに実際に起きること。
    let effectiveMode: ExecutionMode
    let action: (_ forceForm: Bool) -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(recipe.name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RecipeInputBadges(recipe: recipe, compact: true)
                    .frame(width: 80, alignment: .trailing)
                Text(effectiveMode.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 58, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(recipe.description ?? recipe.name)\n\(effectiveMode.explanation)\n⌥クリックで詳細フォーム")
    }

    private var icon: String {
        switch effectiveMode {
        case .copy: return "doc.on.clipboard"
        case .paste: return "text.insert"
        case .submit: return "paperplane"
        }
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
