# Agent Recipes

Herdr 上で動いている Agent へ、定型作業（Recipe）の Prompt を最短で投げ込む macOS メニューバーアプリ。

ユーザーが選ぶ単位は Skill ではなく **Recipe**（やりたい作業）。
Terminal.app / iTerm2 / tmux / Codex CLI / Claude CLI の直接操作は行わず、**実行基盤は Herdr 専用**。

> [!WARNING]
> `paste` / `submit` は、Clipboard・Prompt変数・Project名・cwd を含みうるPromptを
> Herdrと選択中のAgentへ渡します。機密情報を扱う前に、利用するAgentと接続先の
> 組織ポリシーを確認してください。詳しくは [SECURITY.md](SECURITY.md) を参照。

## 構成

```
Sources/
  AgentRecipesCore/   Recipe / Argument Resolver / Variable Resolver / Template Renderer
                      Storage / Projects / Settings / History / Rich Result  ← GUI・Herdr 非依存
  HerdrKit/           HerdrClient (herdr CLI との唯一の接点) / TargetResolver / RecipeRunner
  agentrecipes/       CLI
  AgentRecipesApp/    MenuBar UI / Run Form / Recipe Editor / Settings
Tests/AgentRecipesCoreTests/   83 tests
```

パイプラインは仕様どおりの分割:

```
Recipe ─▶ Argument Resolver ─▶ Variable Resolver ─▶ Template Renderer ─┐
                                                                       ├─▶ Herdr Client
Recipe + Project + Agent + Herdr State ─▶ Target Resolver ─────────────┘
```

GUI・CLI とも `RecipeRunner` を呼ぶだけで、UI から `herdr` を直接叩くことはない。

## ビルドと起動

### 必要環境

- macOS 14 以降
- Swift 6 対応のXcode
- [Herdr](https://herdr.dev/) 0.8 以降（Copy モードだけは不要）

アプリは外部Swiftパッケージを使わず、Herdrを同梱しない。Herdrは利用者の環境に
別途インストールされているCLIを呼び出す。

```bash
swift test                        # まずローカルで検証
./scripts/build-app.sh          # .app を組み立てて ad-hoc 署名
open build/AgentRecipes.app
cp .build/release/agentrecipes /usr/local/bin/   # CLI を使う場合
```

初回起動でサンプル Recipe 4 件（引数なし / 引数あり / Clipboard 利用 / リッチ表示テスト）が作られる。
**Herdr が必要**（`herdr` が PATH にあり、サーバーが起動していること）。Copy モードだけは Herdr なしでも動く。

### 仕事・チームで使う場合

最初は、レビュー済みのソースをprivateリポジトリから各自ローカルビルドする運用を推奨する。
ビルド方法をローカルにしても、実行したPromptの送信先がローカルになるわけではない。
ClipboardやProject情報を含むPromptがHerdrとAgentの設定先へ渡ることを前提に、会社のAI利用・
データ持ち出しポリシーを確認する。

不特定多数へ`.app`を配布する場合は、ad-hoc署名済みの`build/`をそのまま配らず、Developer ID署名と
notarizationを行う。詳細な公開チェックリストは [RELEASING.md](RELEASING.md) を参照。

## プライバシーとローカルデータ

- アプリ独自の分析・テレメトリー・ネットワーク通信はない。実行時の外部通信や保存はHerdrと選択したAgentの設定に従う。
- Clipboardは `{{clipboard}}` または「Clipboard を既定値に」を使うRecipeを解決するときだけ読む。
- Recipe本文は設定したRecipeディレクトリに、履歴・設定・Projectは既定で
  `~/Library/Application Support/AgentRecipes/` に保存する。
- 履歴にはPrompt本文と引数値を保存しない。Debug loggingは既定でOFFであり、調査後はログを確認・削除する。

公開リポジトリには、上記のアプリデータ、個別Skill、Agent transcript、スクリーンショット、
APIキーを含めないこと。

### メニューバーにアイコンが出ないとき

メニューバーが埋まっていると、macOS はアイコンをノッチの下に置いてしまい見えなくなる
（アプリ側から配置は指定できない）。この状態を検出すると起動時にダイアログで知らせる。

対処は、システム設定 →「コントロールセンター」で項目を減らすか、常駐アプリをひとつ終了して
35pt ほど空けること。一度表示されれば ⌘ドラッグで移動でき、位置は `autosaveName` で記憶される。

メニューバーを経由せず Recipe 一覧を直接開くこともできる:

```bash
open -a AgentRecipes --args --manage
```

## 使い方

**メニューバーのアイコン → Recipe をクリックするだけ。** アプリ側でフォームは開かない。
メニューは、他のアプリやAgent Recipesの別windowをクリックすると自動的に閉じる。

| Recipe の設定 | クリックすると |
| --- | --- |
| **実行** | Prompt を LLM に送って実行し、**結果をアプリに表示する** |
| **チャットに入力** | LLM のチャット欄に入れて前面に出す。編集して自分で送る |
| **コピー** | クリップボードにコピーするだけ（Herdr 不要） |

引数がある Recipe は **Clipboard の内容が自動で入る**ので、URL をコピー → クリックだけで実行できる。
Clipboard も既定値も空で埋まらないときは、**フォームを出さずに「チャットに入力」に切り替える**
（続きは LLM のチャットで書けばよい）。

フォームが開くのは、Recipe を「実行時に Project を選ぶ / 送信先を毎回選ぶ」に設定したときと、
**⌥ + クリック**（引数・送信先・Preview を細かく調整したいとき）だけ。

メニュー下部に Herdr の接続状態と Agent 数、応答待ちの Recipe を表示する。

内部的には 実行 = `herdr agent prompt`、チャットに入力 = `herdr pane send-text` + `herdr agent focus`。

### 実行するセッション

**既定は「毎回新しいセッション」**。Herdr に新しい tab を作り、Agent を起動してから実行するので、
作業中の既存セッションに入力が混ざらない。Recipe ごとに変更できる:

| セッション | 動作 |
| --- | --- |
| **新しいセッション**（既定） | `AgentRecipes` space 内にtabを作成 → `herdr agent start` → 実行 |
| 空いていれば再利用 | 同じ LLM の idle な Agent を使う（作業中は避ける）。無ければ新規 |
| 毎回選ぶ | フォームで送信先を選ぶ |

⌥クリックのフォームや CLI の `--agent <pane-id>` で明示指定したときは、その送信先に送る。

`AgentRecipes` space がまだ無い場合は最初の実行時に作成し、workspace作成時のroot paneを使用する。
2回目以降は既存の同名spaceへ新しいtabを追加する。

> 新しい Claude Code セッションは、初回のネットワーク取得などで許可を求めることがある。
> その場合は Result に許可待ちの画面が出るので、Herdr 側で応答する。

### 使用する LLM

**どの LLM に送るかは Recipe ではなくアプリ設定で決める**（Settings → General → 使用する LLM）。
既定は **Claude Code**。Codex / Gemini に切り替えると、すべての Recipe の送信先が変わる。

Recipe 側には Agent 種別を持たせない（Skill を使うのが目的で、LLM の紐付けは不要なため）。
旧スキーマの `target.agent` は読み込み時に無視される。

### 再利用するときの選び方

「空いていれば再利用」にした Recipe では、割り込みにくい順（idle → done → unknown → blocked）で
1 件を選ぶ。**作業中 (working) の Agent は使わず**、その場合は新しいセッションを立てる。
Recipe に Project を設定してあると、cwd が一致する Agent だけを再利用対象にする。

## CLI

```bash
agentrecipes init                                  # 保存先を初期化してサンプルを作成
agentrecipes list [query] [--favorites] [--json]
agentrecipes show <recipe>
agentrecipes preview web-research --url https://example.com
agentrecipes run review-diff --project ComposerSketch
agentrecipes copy|paste|submit <recipe> [--<arg> <value> ...] [--agent <pane-id>]
agentrecipes agents | panes | workspaces | status  # Herdr の状態と現在の LLM
agentrecipes projects [--add ~/src/foo]
agentrecipes history [--limit 20]
```

送信先が確定しないときは候補を一覧表示して終了し、`--agent <pane-id>` で明示指定できる。

## ファイル管理

```
~/Library/Application Support/AgentRecipes/
  settings.json
  projects.json          … Project は Recipe から独立したデータ (id / name / path)
  history.jsonl
  debug.log              … Debug logging を有効にしたときだけ
  recipes/<id>/recipe.json
  recipes/<id>/prompt.md
```

Prompt は JSON に埋めず `prompt.md` に分離してあるので、普通のエディタで編集できる。
Recipe ディレクトリは Settings で差し替え可能（任意ディレクトリの Git 管理は将来対応）。
`AGENTRECIPES_HOME` を設定すると保存先ごと差し替えられる（テスト・検証用）。

## テンプレート

`{{name}}` のみ。if / loop / function は入れない。

- 引数: Recipe に定義した `{{url}}` など（型は **String / Multiline String / URL** の 3 つ）
- Built-in 変数: `{{clipboard}} {{date}} {{time}} {{project}} {{cwd}}`

Shell を経由しないため、シェルエスケープの概念自体が無い。

## Skill と結果形式

Recipe Editor の **Skill & Result** では、検出済みのSkillをRecipeへ関連付けられる。
選択したSkill名は実行Promptへ自動で追加される。Skillの参照元と現在のLLMが違う場合は警告を出す。

結果の形式を **リッチ結果 (JSON)** にすると、Skill／Agentへ `agent-recipes.result/v1` の出力契約を自動付与する。
ResultウィンドウはMarkdown・表・リスト・JSONを構造化表示する。通常テキストを選んでも、Skill自身が同契約で返した場合は自動検出してリッチ表示する。

## 実行結果の確認

Submit したあと **応答完了まで待って結果を表示する**（Settings → General、既定 ON）。

- メニューバーのパネルに「応答待ち: <Recipe 名>」を表示
- 完了すると Result ウィンドウに Agent の出力（末尾）を表示。`Herdr で開く` でその Agent に移動、`コピー` でクリップボードへ
- Skill が `agent-recipes.result/v1` 契約で返した場合は、Markdown・表・リスト・JSON をリッチ表示する。不正または未対応の出力はプレーンテキストへフォールバックする
- 通知（右上の HUD）: 送信時 `Web ページ調査 — Sent to my-home / Codex`、完了時 `… の応答が完了しました`
- 待たない運用にするなら Settings でトグルを OFF。その場合は送信通知だけ出る

内部では `herdr agent prompt --wait --timeout` で待ち、`herdr pane read` で出力を読み取る。
CLI も同じで `--wait [--timeout <ms>]`。

リッチ結果の JSON 契約と Skill 側の書き方は [docs/rich-results.md](docs/rich-results.md) を参照。

## Skill 一覧

Settings → **Skills** で `~/.claude/skills` と `~/.codex/skills`（追加可）を走査し、
SKILL.md の front matter から名前と説明を読んで一覧表示する。

- 行をダブルクリック、または「エディタで開く」で **VS Code** に SKILL.md を開く（`code` コマンド）
- エディタは Settings の「エディタコマンド」で変更可。空にすると OS の既定アプリ
- 右クリックで Finder 表示 / パスのコピー

```bash
agentrecipes skills                          # 一覧
agentrecipes skills web --json               # 検索して JSON で
agentrecipes skills --open web-page-research # SKILL.md をエディタで開く
```

## Settings

使用する LLM（既定 Claude Code）/ Launch at Login / 通知 / 応答待ちと結果表示 / herdr のパス / Herdr 接続状態 /
Skill Sources とエディタ / Recipe ディレクトリ / Debug logging / 履歴件数。

メニューバーを使わずに開く場合:

```bash
open -a AgentRecipes --args --manage           # Recipe 一覧
open -a AgentRecipes --args --settings skills  # Settings の Skills タブ
```

## Herdr 連携について

このマシンにインストールされている **herdr 0.8 の実際の CLI 契約** に合わせて実装・検証済み:

```
herdr agent list      -> {"id":...,"result":{"agents":[{ "pane_id","agent","agent_status","cwd","workspace_id",... }]}}
herdr pane list       -> {"result":{"panes":[...]}}
herdr workspace list  -> {"result":{"workspaces":[...]}}
herdr tab list        -> {"result":{"tabs":[...]}}
herdr pane send-text <PANE_ID> <TEXT>
herdr agent prompt <TARGET> <TEXT>          # TARGET は pane_id
herdr workspace create --label AgentRecipes --no-focus    # 専用spaceが無いとき
herdr tab create --workspace <ID> --cwd <PATH> --label <NAME> --no-focus
herdr agent start <NAME> --kind <KIND> --pane <ID>
herdr agent wait <TARGET> --until idle --timeout <MS>
```

注意点として、**herdr は失敗時も終了コード 0 を返し `{"error":{"code","message"}}` を出力する**ため、
エラー判定はこのエンベロープを見ている。エラーは 未インストール / 未起動 / Agent なし / 候補複数 /
コマンド失敗 / デコード失敗 に分類され、UI にはそのまま日本語で出る。
CLI 契約が変わった場合の修正は `Sources/HerdrKit/HerdrClient.swift` 内で閉じる。

## MVP 範囲

実装済み: 既存 Herdr Agent の探索 → Recipe から Prompt 生成 → Copy / Paste / Submit、
Project + Agent による Target 解決と自動選択、該当なし時の Agent 新規起動、
Recipe CRUD、Favorite / Recent / Search / Category、Preview、履歴表示、Settings、CLI。

未実装（仕様どおり後回し）:

- Command Palette / グローバルショートカット（Raycast 等と重複するため）
- Shell Command Recipe
- Skill Import（一覧・Recipeへの関連付けは実装済み）
- Number / Boolean / Enum / File / Directory 引数
- Workflow Recipe、Recipe Packs、Smart Routing

## 動作確認用スキル

`skills/` に、副作用のない確認用スキルを 3 つ置いてある。

- `agent-recipes-check` — 配送確認だけを行う
- `web-page-research` — URL を読んで決まった形式で要点を返す（`Webページ調査` Recipe が使う）
- `agent-recipes-rich-result-test` — Markdown・表・リスト・JSON のリッチ表示をまとめて確認する

`~/.claude/skills/` と `~/.codex/skills/` にコピーして使う。

```bash
cp -R skills/* ~/.claude/skills/
cp -R skills/* ~/.codex/skills/
```

対応する Recipe「動作確認」(`agent-recipes-check`) は、マーカー・送信日時・Project・cwd を
埋めた Prompt を送り、Agent 側は受け取った内容と実際の `pwd` の一致を報告するだけ。
既定は Submit ＋ Agent Only (codex) ＋ 新規作成なので、メニューから 1 クリックで確認できる。

```bash
agentrecipes submit agent-recipes-check                       # 自動で送信先を決めて実行
agentrecipes paste  agent-recipes-check --agent w1:p2         # 送信先を明示（Enter は押さない）
```

Agent 側は次の形式で返す:

```
AGENT-RECIPES-CHECK OK
  marker : NEWAGENT-01
  target : agent-skill-snippet / /path/to/agent-skill-snippet
  actual : /path/to/agent-skill-snippet
  match  : yes
```

## テスト

```bash
swift test
```

Template / 引数検証 / ファイル入出力 / Project / History / Herdr CLI のコマンド生成とエラー分類 /
Target Resolver の全 Strategy と優先順位 / 新規 Agent 起動シーケンス / RecipeRunner の Copy・Paste・Submit をカバー。
Herdr は Fake Runner に差し替えているので、テスト実行で実際の Agent へ送信されることはない。

## 公開・ライセンス

このプロジェクトは [MIT License](LICENSE) で公開する想定である。公開前に`LICENSE`の
`<YOUR NAME OR ORGANIZATION>`を正しい著作権者名へ置き換えること。

IssueやPull Requestを送る場合は [CONTRIBUTING.md](CONTRIBUTING.md)、脆弱性や意図しない
データ開示は [SECURITY.md](SECURITY.md) を参照する。
