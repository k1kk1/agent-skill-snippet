import SwiftUI
import AppKit
import AgentRecipesCore
import HerdrKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// 起動引数から開くタブを指定できる (`--settings skills` など)。
    @State var selection: Tab = .general

    enum Tab: String, Hashable {
        case general, herdr, mcp, skills, projects, history
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            HerdrSettings(model: model)
                .tabItem { Label("Herdr", systemImage: "square.stack.3d.up") }.tag(Tab.herdr)
            MCPSettings(model: model)
                .tabItem { Label("MCP", systemImage: "cable.connector") }.tag(Tab.mcp)
            SkillSettings(model: model)
                .tabItem { Label("Skills", systemImage: "book.closed") }.tag(Tab.skills)
            ProjectSettings(model: model)
                .tabItem { Label("Projects", systemImage: "folder") }.tag(Tab.projects)
            HistorySettings(model: model)
                .tabItem { Label("History", systemImage: "clock") }.tag(Tab.history)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 460)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("使用する LLM") {
                Picker("送信先", selection: $model.settings.agent) {
                    ForEach(AgentKind.allCases, id: \.self) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
                .pickerStyle(.segmented)
                Text("すべての Recipe はここで選んだ LLM の Agent に送られます（Recipe 側では指定しません）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("ログイン時に起動する", isOn: $model.settings.launchAtLogin)
            Toggle("送信結果を通知する", isOn: $model.settings.notificationsEnabled)
            Toggle("Submit のあと応答完了まで待って結果を表示する", isOn: $model.settings.waitForResult)
            if model.settings.waitForResult {
                Stepper("応答待ちの上限: \(model.settings.resultTimeoutSeconds) 秒",
                        value: $model.settings.resultTimeoutSeconds, in: 30...3600, step: 30)
            }
            Picker("新規 Recipe の既定モード", selection: $model.settings.defaultMode) {
                ForEach(ExecutionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Section("作業ディレクトリ（既定）") {
                HStack {
                    TextField("既定: ~/.agentrecipes", text: $model.settings.defaultWorkingDirectory)
                        .font(.system(.caption, design: .monospaced))
                    Button("選択...") { chooseDefaultWorkingDirectory() }
                }
                Text("Recipe に作業フォルダを設定していないとき、新しい Agent をここで起動します。既定は Skill 実行用の空ディレクトリ `~/.agentrecipes`（無ければ自動作成）。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.settings.expandedDefaultWorkingDirectory)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }

            Section("Recipe Directory") {
                HStack {
                    TextField("既定: Application Support/AgentRecipes/recipes", text: $model.settings.recipesDirectory)
                        .font(.system(.caption, design: .monospaced))
                    Button("選択...") { chooseRecipesDirectory() }
                    Button("開く") { NSWorkspace.shared.open(model.layout.recipesDirectory) }
                }
                Text(model.layout.recipesDirectory.path)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }

            Section("Debug") {
                Toggle("Herdr とのやり取りをログに残す", isOn: $model.settings.debugLogging)
                HStack {
                    Text(model.layout.logFile.path)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("ログを開く") { NSWorkspace.shared.open(model.layout.logFile) }
                        .disabled(!FileManager.default.fileExists(atPath: model.layout.logFile.path))
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.settings) { _, _ in model.scheduleSettingsSave() }
    }

    private func chooseDefaultWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.defaultWorkingDirectory = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseRecipesDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.recipesDirectory = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

private struct HerdrSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                LabeledContent("herdr のパス") {
                    HStack {
                        TextField("空なら自動検出", text: $model.settings.herdrExecutablePath)
                            .font(.system(.caption, design: .monospaced))
                        Button("選択...") { chooseExecutable() }
                    }
                }
                LabeledContent("接続状態") {
                    HStack {
                        Circle()
                            .fill(model.connection.isHealthy ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(model.connection.displayText)
                        Spacer()
                        Button("再確認") { model.refreshHerdr() }
                    }
                }
            }
            .formStyle(.grouped)

            Text("Agents").font(.headline)
            if model.agents.isEmpty {
                Text("Agent がいません。Herdr で Agent を起動してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Table(model.agents) {
                TableColumn("Agent") { Text($0.agentName) }.width(90)
                TableColumn("Project") { Text($0.projectName ?? "-") }
                TableColumn("cwd") { Text($0.cwd ?? "-").font(.caption) }
                TableColumn("Pane") { Text($0.paneID) }.width(80)
                TableColumn("Status") { Text($0.status ?? "-") }.width(80)
            }

            Text("Paste は herdr pane send-text、Submit は herdr agent prompt を使用します。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model.refreshHerdr() }
        .onChange(of: model.settings) { _, _ in model.scheduleSettingsSave() }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.herdrExecutablePath = url.path
    }
}

/// LLM ごとの MCP 接続状況。
/// Skill が MCP のツールを使う場合、未接続だと実行が途中で止まるため、事前に確認できるようにする。
private struct MCPSettings: View {
    @ObservedObject var model: AppModel

    private var groups: [MCPServerGroup] {
        MCPInspection.grouped(AgentKind.allCases.compactMap { model.mcp[$0] })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP 接続状況").font(.headline)
                    Text("`<llm> mcp list` の結果です。作業ディレクトリ: \(model.settings.expandedDefaultWorkingDirectory)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if !model.mcpChecking.isEmpty { ProgressView().controlSize(.small) }
                Button {
                    model.refreshMCP()
                } label: {
                    Label("再チェック", systemImage: "arrow.clockwise")
                }
                .disabled(!model.mcpChecking.isEmpty)
            }

            legend

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if groups.isEmpty {
                        Text(model.mcpChecking.isEmpty ? "MCP サーバーは見つかりませんでした。" : "確認中…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(groups) { group in
                        MCPGroupRow(group: group)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        if let inspection = model.mcp[kind], let message = inspection.message {
                            Label("\(kind.displayName): \(message)", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.mcp[.codex]?.servers.isEmpty == false {
                        Text("Codex は接続確認に対応していないため、設定されていれば「設定あり」として表示します。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .onAppear { if model.mcp.isEmpty { model.refreshMCP() } }
    }

    /// アイコンの読み方。カラー = その LLM で使える。
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(AgentKind.allCases, id: \.self) { kind in
                HStack(spacing: 4) {
                    AgentBrandIcon(kind: kind, active: true, size: 16)
                    Text(kind.displayName)
                        .font(.caption)
                        .foregroundStyle(kind == model.settings.agent ? .primary : .secondary)
                    if kind == model.settings.agent {
                        Text("使用中")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
            Text("グレー = 未設定")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// 検出された Skill の一覧と、SKILL.md の表示。
private struct SkillSettings: View {
    @ObservedObject var model: AppModel
    @State private var filter: String = ""
    @State private var selection: DiscoveredSkill.ID?
    @State private var newSourcePath: String = ""

    private var visible: [DiscoveredSkill] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.skills : model.skills.filter { $0.matches(query) }
    }

    private var selected: DiscoveredSkill? {
        model.skills.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Skill を検索", text: $filter).textFieldStyle(.roundedBorder)
                Button("再スキャン") { model.reloadSkills() }
            }

            if model.skills.isEmpty {
                Text("Skill が見つかりません。下の Skill Sources のパスを確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            List(visible, selection: $selection) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(skill.name).bold()
                        Text(skill.source)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        Spacer()
                    }
                    if let description = skill.description {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(skill.path)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                .padding(.vertical, 2)
                .tag(skill.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.openSkillFile(skill) }
                .contextMenu {
                    Button("エディタで開く") { model.openSkillFile(skill) }
                    Button("Finder で表示") { model.revealSkillInFinder(skill) }
                    Button("パスをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(skill.path, forType: .string)
                    }
                }
            }

            HStack {
                Button("エディタで開く") { selected.map { model.openSkillFile($0) } }
                    .disabled(selected == nil)
                Button("Finder で表示") { selected.map { model.revealSkillInFinder($0) } }
                    .disabled(selected == nil)
                Spacer()
                Text("行をダブルクリックでも開きます").font(.caption2).foregroundStyle(.secondary)
            }

            Divider()
            Form {
                LabeledContent("エディタコマンド") {
                    TextField("code（空なら既定のアプリ）", text: $model.settings.editorCommand)
                        .font(.system(.caption, design: .monospaced))
                }
                LabeledContent("Skill Sources") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach($model.settings.skillSources) { $source in
                            HStack {
                                TextField("name", text: $source.name).frame(width: 90)
                                TextField("path", text: $source.path)
                                    .font(.system(.caption, design: .monospaced))
                                Button {
                                    model.settings.skillSources.removeAll { $0.id == source.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("ディレクトリを追加...") { addSource() }
                            .buttonStyle(.link)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 190)
        }
        .onAppear { model.reloadSkills() }
        .onChange(of: model.settings) { _, _ in
            model.scheduleSettingsSave(rescanSkills: true)
        }
    }

    private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.skillSources.append(SkillSource(
            name: url.deletingLastPathComponent().lastPathComponent,
            path: (url.path as NSString).abbreviatingWithTildeInPath
        ))
    }
}

private struct ProjectSettings: View {
    @ObservedObject var model: AppModel
    @State private var selection: Project.ID?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Project は Recipe と Herdr Agent の cwd を突き合わせるために使います。")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach($model.projects) { $project in
                    HStack {
                        TextField("name", text: $project.name).frame(width: 160)
                        TextField("path", text: $project.path)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .tag(project.id)
                }
            }
            HStack {
                Button { addProject() } label: { Image(systemName: "plus") }
                Button {
                    model.projects.removeAll { $0.id == selection }
                    model.saveProjects()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Spacer()
                Button("保存") { model.saveProjects() }
            }
            .buttonStyle(.borderless)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.projects.append(Project(
            name: url.lastPathComponent,
            path: (url.path as NSString).abbreviatingWithTildeInPath
        ))
        model.saveProjects()
    }
}

private struct HistorySettings: View {
    @ObservedObject var model: AppModel
    @State private var entries: [HistoryEntry] = []

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading) {
            Table(entries) {
                TableColumn("Time") { Text(Self.formatter.string(from: $0.timestamp)) }.width(90)
                TableColumn("Recipe") { Text($0.recipeName) }
                TableColumn("Project") { Text($0.project ?? "-") }
                TableColumn("Agent") { Text($0.agent ?? "-") }.width(80)
                TableColumn("Mode") { Text($0.mode.displayName) }.width(70)
                TableColumn("Result") { entry in
                    Text(entry.result.rawValue)
                        .foregroundStyle(entry.result == .success ? Color.secondary : Color.orange)
                }.width(70)
            }

            HStack {
                Stepper("保存件数: \(model.settings.historyLimit)",
                        value: $model.settings.historyLimit, in: 20...2000, step: 20)
                    .onChange(of: model.settings.historyLimit) { _, _ in model.scheduleSettingsSave() }
                Spacer()
                Button("再読み込み") { entries = model.historyRepository.recent(limit: 100) }
                Button("履歴を消去") {
                    model.historyRepository.clear()
                    entries = []
                }
            }
            Text("Prompt 全文と引数は保存されません。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { entries = model.historyRepository.recent(limit: 100) }
    }
}
