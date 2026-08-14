> **注意: これは v1 (Agent Skill Snippets) の草案で、現在の実装とは範囲が異なります。**
> 現行は Herdr 専用の「Agent Recipes」にスコープを絞っており、Terminal / Shell Command /
> Command Palette / Skill Import などは対象外です。実装済みの範囲は README.md を参照してください。

以下の形にすると、単なる「定型文置き場」ではなく、**エージェント作業を開始するためのランチャー**としてかなり使いやすくなると思います。特に「Recipe」という中間概念を置き、Skill・Prompt・引数・プロジェクト・実行先をひとまとめにする設計を推します。 

# Agent Skill Snippets 設計書

- 文書種別: プロダクト・機能・技術設計
- 対象OS: macOS
- 初期形態: メニューバー常駐アプリ
- 想定実装: Swift / SwiftUI + 必要に応じて AppKit
- ステータス: Concept / MVP Draft

---

# 1. 概要

## 1.1 目的

Codex、Claude Code などのエージェントで頻繁に使用する Skill / Prompt / Command を、macOS のメニューバーからすぐ呼び出せるようにする。

通常、

1. Terminal を開く
2. 対象プロジェクトへ移動する
3. Codex / Claude Code を起動する
4. Skill を思い出す
5. Prompt を入力する
6. URLやファイル名などを入力する

という操作が必要になる。

Agent Skill Snippets ではこれを、

**メニューバー → Skill選択 → 実行**

まで短縮する。

---

# 2. プロダクトコンセプト

単純な「Snippet 管理アプリ」にはしない。

中心概念を **Recipe** とする。

```text
Recipe
├─ Skill
├─ Prompt Template
├─ Arguments
├─ Project / Working Directory
├─ Agent
├─ Execution Target
└─ Execution Mode
```

たとえば、

```text
Discography Import
```

という Recipe を作成すると、

```text
Agent
  Claude

Project
  ~/src/music-db

Prompt
  {{url}} からディスコグラフィ情報を取得してください。
  MULTI_ARTIST.md の仕様に従って JSON を生成してください。

Arguments
  url: URL

Execution
  Herdr の Claude pane

Mode
  Submit
```

のような情報をまとめて保持する。

---

# 3. 基本原則

## 3.1 3秒以内に作業開始

頻繁に使う Recipe は、

```text
MenuBar
↓
Recipe
↓
実行
```

の2クリック程度で開始できるようにする。

---

## 3.2 「入力」と「実行」を分離する

同じ Recipe でも以下を選択できる。

### Submit

Terminalへ入力し、そのまま送信する。

```text
Prompt貼付
↓
Enter
```

---

### Fill

Terminalへ入力するが、Enter は押さない。

```text
Prompt貼付
↓
ユーザーが確認・編集
↓
Enter
```

「スニペット貼り付けまで」に相当する。

誤操作を避けたい Prompt ではこれをデフォルトにできる。

---

### Copy

Clipboardへコピーするだけ。

Terminal以外でも利用可能。

---

### Command

Agent Prompt ではなく Shell Command を実行する。

例:

```bash
npm test
```

```bash
git status
```

など。

Command は Prompt Recipe とは別タイプとして扱う。

---

# 4. Recipe の種類

## 4.1 Direct Recipe

引数なし。

例:

```text
コードレビュー
```

Prompt:

```text
現在の変更内容をレビューしてください。
問題点、改善案、テスト不足を確認してください。
```

選択すると即実行する。

---

## 4.2 Parameterized Recipe

実行時に値を入力する。

例:

```text
Webページ調査
```

Prompt:

```text
{{url}} を調査してください。

特に以下を確認してください。

{{focus}}
```

実行すると小さな入力画面を表示する。

```text
Webページ調査

URL
[ https://example.com                  ]

確認項目
[ API仕様                            ]

                 [Paste] [Run]
```

---

## 4.3 Context Recipe

Clipboard や現在の Project などから自動的に引数を取得する。

例:

```text
Clipboardをレビュー
```

Prompt:

```text
以下の内容をレビューしてください。

{{clipboard}}
```

ユーザー入力なしで実行できる。

---

## 4.4 Command Recipe

Shell Command を実行する。

```text
Run Tests
```

```bash
swift test
```

---

## 4.5 Workflow Recipe

将来的な拡張。

複数の処理を順番に実行する。

```text
Issue実装開始

1. Terminal起動
2. Projectへ移動
3. Agent起動
4. Issue情報取得
5. Prompt送信
```

MVPには含めない。

---

# 5. メニューバー UI

基本画面。

```text
◆ Agent Skills
────────────────────

🔍 Search...

★ Favorites
   Code Review
   Implement Issue
   Web Research

Recent
   Fix Tests
   Generate JSON

Projects
   ComposerSketch >
   mushi-battle >
   agent-usage >

Skills
   Development >
   Research >
   Music >
   Utilities >

────────────────────
Manage Recipes...
Settings...
```

---

# 6. Recipe 選択時の動作

Recipe の設定によって挙動を変える。

## 引数なし

```text
Code Review
```

クリック

→ 即実行

---

## 引数あり

```text
Web Research…
```

クリック

→ Parameter Form

---

## Optionクリック

通常は即実行する Recipe でも、

```text
⌥ + Click
```

で Parameter / Preview 画面を表示できる。

---

# 7. Command Palette

メニューバーだけでなく、グローバルショートカットから検索できるようにする。

例:

```text
⌥ Space
```

↓

```text
Agent Skill

> rev

  Code Review
  Review Current Diff
  Review Architecture
```

Enter で実行。

これは使用頻度が高くなる可能性が高いため、MVPに含めたい。

ショートカットは変更可能にする。

---

# 8. 引数

## 8.1 Argument Type

以下をサポートする。

```text
String
Multiline String
URL
File
Directory
Number
Boolean
Enum
```

例:

```json
{
  "name": "url",
  "type": "url",
  "required": true
}
```

---

# 9. Dynamic Variables

ユーザー入力以外にも自動変数を利用できる。

```text
{{clipboard}}
{{cwd}}
{{project}}
{{date}}
{{time}}
{{home}}
```

将来的には、

```text
{{git.branch}}
{{git.root}}
{{git.diff}}
{{selectedText}}
{{frontmostApp}}
```

なども追加できる。

---

# 10. Clipboard の活用

Clipboard は特に重要な入力元とする。

たとえば URL をコピーしてから、

```text
MenuBar
↓
Web Research
```

だけで、

```text
https://example.com
```

が自動的に Prompt に入る。

Recipe 側では、

```text
{{clipboard}} を調査してください。
```

と書くだけ。

これだけでも操作回数をかなり減らせる。

---

# 11. Project Context

Recipe と Project を関連付けられるようにする。

```text
ComposerSketch
~/src/ComposerSketch

mushi-battle
~/src/mushi-battle

agent-usage
~/src/agent-usage
```

Recipe は、

```text
Project 固定
```

または

```text
実行時選択
```

にできる。

---

# 12. Agent

Agent を抽象化する。

```text
AgentAdapter

├─ CodexAdapter
├─ ClaudeAdapter
├─ CustomAgentAdapter
└─ ShellAdapter
```

Recipe 側では、

```text
agent: codex
```

のように指定する。

---

# 13. Execution Target

Agent と実行場所を分離する。

```text
Agent
  Codex

Target
  Herdr
```

のようにする。

Target候補:

```text
New Terminal
Existing Terminal
Herdr Pane
Clipboard
Custom
```

---

# 14. Herdr 連携

Herdr を利用する場合、pane を実行先として選択可能にする。

例:

```text
Send to...

● ComposerSketch / Codex
○ mushi-battle / Claude
○ agent-usage / Codex
○ New Pane
```

pane 情報として、

```text
Agent
cwd
workspace
tab
pane
status
```

などを利用する。

これにより、

```text
Skill
↓
現在動いている ComposerSketch の Codex
```

へ直接 Prompt を送れる。

---

# 15. 実行先選択ルール

Recipe ごとに Strategy を設定可能にする。

### Fixed

指定 pane / project に送る。

### Current Project

現在の Project に対応する Agent を探す。

### Agent Match

指定 Agent の pane を探す。

```text
agent = Claude
cwd = ~/src/mushi-battle
```

など。

### Ask

毎回選択する。

---

# 16. Preview

引数付き Recipe では Prompt Preview を表示できる。

```text
Web Research

URL
https://example.com

──────── Preview ────────

https://example.com を調査してください。

API仕様について重点的に確認してください。

────────────────────────

[Copy] [Paste] [Run]
```

特に長い Prompt では便利。

---

# 17. Recipe Editor

設定画面から Recipe を作成する。

```text
Name
[ Discography Import ]

Category
[ Music ]

Agent
[ Claude ▼ ]

Project
[ music-db ▼ ]

Execution
[ Submit ▼ ]

Prompt
┌─────────────────────
│ {{url}} を取得して
│ JSONを生成してください。
└─────────────────────

Arguments
URL
  type: URL
  required: YES

[ Save ]
```

---

# 18. Recipe Library

Recipe が増えてくることを前提に、以下を持つ。

```text
Category
Tags
Favorite
Recent
Search
Project
Agent
```

カテゴリー例:

```text
Development
Git
GitHub
Research
Document
Music
Podcast
Data
Utilities
```

---

# 19. ファイル管理

アプリ内部だけに閉じず、Git管理しやすくする。

推奨構造:

```text
~/.config/agent-snippets/

recipes/
  code-review/
    recipe.json
    prompt.md

  discography-import/
    recipe.json
    prompt.md

config.json
```

Prompt を JSON 内に埋め込まず、

```text
prompt.md
```

として分離する。

これにより長い Prompt を普通のエディタでも編集できる。

---

# 20. Recipe データモデル

例:

```json
{
  "schemaVersion": 1,
  "id": "discography-import",
  "name": "Discography Import",
  "description": "公式サイトからディスコグラフィJSONを生成",
  "category": "Music",
  "tags": [
    "research",
    "json"
  ],
  "favorite": true,

  "agent": {
    "type": "claude"
  },

  "project": {
    "path": "~/src/music-db"
  },

  "prompt": {
    "file": "prompt.md"
  },

  "arguments": [
    {
      "name": "url",
      "label": "URL",
      "type": "url",
      "required": true
    }
  ],

  "execution": {
    "target": "herdr",
    "mode": "submit",
    "strategy": "agentAndProject"
  }
}
```

---

# 21. Template Engine

テンプレート構文は意図的に単純にする。

```text
{{url}}
{{clipboard}}
{{cwd}}
```

最初から、

```text
if
loop
function
```

などを入れない。

高度なロジックが必要なら Script / Workflow 側へ分離する。

---

# 22. Skill Import

既存 Agent Skill を登録できるようにする。

概念的には、

```text
Skill Sources

~/.xxx/skills
~/project/.xxx/skills
Custom Directory
```

のように任意のディレクトリを Source として登録する。

アプリ側で検出して、

```text
Available Skills

code-review
discography-import
podcast-correction
...
```

のように一覧化する。

Agent ごとの Skill 形式の違いは、

```text
SkillProvider
```

で吸収する。

```text
ClaudeSkillProvider
CodexSkillProvider
CustomSkillProvider
```

具体的な Skill ファイル仕様に UI 全体を依存させない。

---

# 23. Recipe と Skill の関係

Skillそのものと Recipe は分ける。

```text
Skill
    ↓ 使用
Recipe
```

Skill:

```text
discography-import
```

Recipe:

```text
Vaundy Import
```

```text
TOMOO Import
```

```text
MyGO Import
```

のように、同じ Skill に異なる引数・Project・Prompt を設定できる。

これはかなり重要。

---

# 24. Quick Action

頻繁に使う Recipe は個別ショートカットを割り当てられる。

例:

```text
⌃⌥R
→ Code Review

⌃⌥T
→ Run Tests
```

ただし多数設定すると覚えにくいため、

基本は Command Palette を中心にする。

---

# 25. Execution History

履歴には最低限、

```text
Recipe
Time
Project
Agent
Result
```

のみ保存する。

例:

```text
12:31  Code Review        ComposerSketch   Codex
12:20  Web Research       -                Claude
11:48  Run Tests          mushi-battle     Shell
```

Prompt全文はデフォルトでは保存しない。

入力内容に機密情報が含まれる可能性があるため。

---

# 26. 再実行

History から、

```text
Run Again
Run With Arguments
Copy Prompt
```

を実行可能にする。

前回引数については設定で、

```text
保存しない
保存する
```

を選択できる。

---

# 27. Safety

Shell Command と Prompt Submit は明確に区別する。

特に Shell Command では、

```text
rm
sudo
git reset --hard
```

など危険なコマンドを誤実行する可能性がある。

Recipe に、

```text
confirmation: true
```

を設定可能にする。

---

## 引数エスケープ

Shell Recipe では単純な文字列置換を行わない。

悪い例:

```bash
command {{value}}
```

入力:

```text
foo; rm -rf ...
```

Shell 用引数は安全にエスケープする。

Prompt Template と Shell Template のレンダリング処理も分離する。

---

# 28. CLI Companion

GUI と同じ Recipe Engine を使う CLI を用意すると非常に便利。

例:

```bash
agentsnip list
```

```bash
agentsnip run code-review
```

```bash
agentsnip run web-research \
  --url https://example.com
```

```bash
agentsnip paste code-review
```

```bash
agentsnip copy code-review
```

これにより、

```text
GUI
CLI
Herdr
Shell Script
```

すべてから同じ Recipe を利用できる。

内部ロジックも CLI と GUI で共通化できるため、テストしやすくなる。

---

# 29. アーキテクチャ

```text
                ┌─────────────────┐
                │   MenuBar UI    │
                └────────┬────────┘
                         │
                ┌────────▼────────┐
                │ Recipe Library  │
                └────────┬────────┘
                         │
                ┌────────▼────────┐
                │ Recipe Resolver │
                │                 │
                │ Arguments       │
                │ Context         │
                │ Variables       │
                └────────┬────────┘
                         │
                ┌────────▼────────┐
                │ Template Engine │
                └────────┬────────┘
                         │
                ┌────────▼────────┐
                │Execution Engine │
                └────────┬────────┘
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
┌──────▼──────┐   ┌──────▼──────┐   ┌──────▼──────┐
│   Herdr     │   │   Terminal  │   │  Clipboard  │
└─────────────┘   └─────────────┘   └─────────────┘
       │
┌──────▼────────────────┐
│ Codex / Claude / etc. │
└───────────────────────┘
```

---

# 30. Swift モジュール構成案

```text
AgentSkillSnippets

App
├─ MenuBar
├─ CommandPalette
├─ RecipeEditor
└─ Settings

Core
├─ Recipe
├─ Argument
├─ Template
├─ Context
└─ History

Execution
├─ ExecutionEngine
├─ ClipboardExecutor
├─ TerminalExecutor
├─ ShellExecutor
└─ HerdrExecutor

Agents
├─ AgentAdapter
├─ CodexAdapter
├─ ClaudeAdapter
└─ CustomAgentAdapter

Skills
├─ SkillProvider
├─ SkillScanner
└─ SkillRegistry

Storage
├─ RecipeRepository
├─ SettingsRepository
└─ HistoryRepository
```

---

# 31. MVP

最初から Workflow Engine まで作る必要はない。

## MVP 1

### Recipe

- Recipe作成
- Prompt Template
- 引数
- Category
- Favorite
- Project
- Agent

### Variables

- Clipboard
- cwd
- Date

### Execution

- Copy
- Paste
- Submit

### UI

- MenuBar
- Recipe一覧
- Search
- Favorites
- Recent
- Parameter Form
- Preview
- Recipe Editor

### Terminal

- 新規Terminal起動
- 指定cwdで起動
- Agent起動
- Prompt貼り付け
- Prompt送信

### Storage

- ローカル保存
- JSON
- prompt.md
- schemaVersion

---

# 32. MVP 2

次に追加する。

- Herdr連携
- 既存pane検索
- Agent / cwd による自動pane選択
- Skill Directory Scan
- CLI Companion
- Recipe Import / Export
- Global Command Palette
- Recipe Shortcut
- Git Context

---

# 33. Version 1.0

- Workflow Recipe
- 複数ステップ実行
- Selected Text
- File / Directory Context
- Git Diff
- GitHub Issue / PR Context
- Agent 状態連携
- Recipe Packs
- Recipe Variables
- Execution History
- Conditional Actions

---

# 34. 将来的な発展案

## Agent 状態を使った Smart Routing

Herdr の状態を利用して、

```text
Claude
working

Codex
idle
```

なら、

```text
idle Agent に送る
```

という実行先選択もできる。

ただし自動振り分けは予期しない pane への入力につながるため、オプション機能とする。

---

## Project Recipe

Projectごとに Recipe Set を持てる。

```text
ComposerSketch

Run Tests
Review UI
Implement Feature
Check Architecture
```

---

## Recipe Packs

複数 Recipe を配布できる。

```text
Swift Development Pack

Code Review
Swift Test
Concurrency Review
SwiftUI Review
Accessibility Review
```

Git Repository として共有可能にする。

---

## Prompt Composer

複数の小さな Snippet を組み合わせる。

```text
[Task]
Implement feature

[Constraint]
Do not modify API

[Validation]
Run tests

[Output]
Summarize changes
```

↓

一つの Prompt を生成。

ただしMVPでは不要。

---

## Drag & Drop

ファイルを MenuBar アイコンへ Drop。

```text
example.swift
↓
Review File
```

Recipe の

```text
{{file}}
```

として渡す。

これは使い勝手の良い追加機能候補。

---

## Finder Quick Action

Finder で、

```text
ファイル右クリック
↓
Agent Skills
↓
Review
```

を可能にする。

---

## Services / Share Extension

Safari などで、

```text
選択
↓
共有
↓
Agent Skill
```

として渡す。

Web調査 Recipe と相性が良い。

---

# 35. 最も重要な追加アイデア

このアプリでは **「Skill一覧」より「自分がやりたい作業一覧」を前面に出す** 方がよい。

たとえば、

```text
discography-import
```

という Skill 名より、

```text
ディスコグラフィを取り込む
```

の方が探しやすい。

したがって UI 上では、

```text
Recipe
```

を主役にし、

```text
Agent Skill
```

は内部実装として扱う。

概念としては、

```text
Recipe
  ↓
どの Skill を使うか
  ↓
どの Agent で実行するか
  ↓
どの Project / Pane で実行するか
```

とする。

---

# 36. 推奨する最終操作フロー

最も頻繁に使うケース。

```text
⌥ Space

> disco

Discography Import
```

Enter

↓

Clipboard に URL がある場合、

```text
URL
https://example.com/discography

[Run]
```

↓

```text
ComposerSketchではなく
music-db の Claude pane を検索
```

↓

Prompt生成

↓

Claudeへ入力

↓

Enter

↓

MenuBar通知

「Discography Import を Claude に送信しました」
```

理想的にはここまで数秒で完了する。

---

# 37. 開発優先順位

## Phase 1 — Launcher

まずここだけ完成させる。

```text
MenuBar
Recipe
Prompt Template
Arguments
Clipboard
Copy / Paste / Submit
Terminal起動
```

これだけでアプリとして十分有用。

---

## Phase 2 — Context

```text
Project
cwd
Git
File
Herdr
Agent
```

を追加。

「どこで実行するか」をアプリが理解できるようにする。

---

## Phase 3 — Automation

```text
Skill Discovery
Workflow
Smart Routing
Recipe Packs
CLI
```

を追加する。

---

# 38. 成功条件

MVP完成条件を以下とする。

- メニューバーから2〜3操作以内でRecipeを実行できる
- 引数なしRecipeを即実行できる
- 引数付きRecipeをフォームから実行できる
- Clipboardを引数として利用できる
- Promptをコピーできる
- PromptをTerminalへ貼り付けられる
- Enterを押さず貼り付けだけにできる
- Promptをそのまま送信できる
- RecipeごとにProjectを指定できる
- RecipeごとにAgentを指定できる
- 実行前Previewが可能
- Favorite / Recent / Search が利用できる
- Recipeデータをファイルとして管理できる
- PromptをMarkdownとして管理できる
- schemaVersionを持つ
- GUIと実行ロジックが分離されている

---

# 39. 非目標

初期バージョンでは以下を実装しない。

- 高度なWorkflowエンジン
- Agent同士の自律的なタスク振り分け
- クラウド同期
- Recipe Marketplace
- AIによるRecipe自動生成
- 複雑なTemplate言語
- Agentの会話履歴管理
- Terminal Emulatorそのもの

あくまで、

**「やりたい作業を選ぶと、適切なAgentへ適切なPromptを素早く投入する」**

ところに集中する。

---

# 40. プロダクトの位置付け

最終的には、

```text
macOS Spotlight
        +
Raycast
        +
Snippet Manager
        +
Agent Skill Launcher
        +
Herdr
```

の Agent 作業部分だけを軽量にまとめたようなツールになる。

ただし機能を増やしすぎず、

> 「今からこの作業をAgentにやらせたい」

と思った瞬間から、

> 「Agentが作業を開始する」

までの操作を最短化することを最優先とする。

特に追加したいのは **① Clipboard変数、② Command Palette、③ Project Context、④ Herdr paneへの直接送信、⑤ CLI Companion** の5つです。

また設計上かなり重要なのが、アプリ名や内部では「Skill」を扱っていても、**ユーザーが選ぶ単位は Skill ではなく Recipe にすること**です。たとえば `github` Skill を探すより「PRをレビュー」「Issueを実装」「CIを修正」と並んでいる方が、実際に使うときは圧倒的に速いです。これなら同じ Skill から用途別のスニペットを何個でも作れます。
