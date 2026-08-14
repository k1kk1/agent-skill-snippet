import SwiftUI
import AgentRecipesCore
import HerdrKit

/// メニューバーの主導線。Search / Favorites / Recent / Projects / Categories。
struct MenuBarView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @FocusState private var searchFocused: Bool

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
            model.refreshHerdr()
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
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
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
                    Menu {
                        ForEach(model.recipes(forProject: project)) { recipe in
                            Button(recipe.name) {
                                dismiss()
                                model.activate(recipe)
                            }
                        }
                    } label: {
                        Label(project.name, systemImage: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 12)
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
                    Menu {
                        ForEach(model.recipes(inCategory: category)) { recipe in
                            Button(recipe.name) {
                                dismiss()
                                model.activate(recipe)
                            }
                        }
                    } label: {
                        Label(category, systemImage: "square.grid.2x2")
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 12)
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
                    Text("応答待ち: \(model.pendingResults.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12)
            }
            statusLine
        }
        .padding(.vertical, 6)
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
                Text(recipe.name).lineLimit(1)
                Spacer(minLength: 0)
                Text(effectiveMode.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
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
