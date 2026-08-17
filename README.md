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

### アイコンを作り直す

アイコンは画像素材ではなく `scripts/make-icon.swift` が図形で描く。色や形を変えたらこれを実行するだけ。

```bash
swift scripts/make-icon.swift plane --icns Resources/AppIcon.icns   # 差し替え
swift scripts/make-icon.swift card icon.png 512                     # 候補を PNG で確認
```

`plane`（紙飛行機・既定）/ `card`（レシピカード）/ `spark`（4 芒星）の 3 種類を用意してある。

### 更新する

`scripts/update.sh` が「最新ソースの取得 → テスト → ビルド → `/Applications` の差し替え → 再起動」を一度に行う。
**git は不要**（ZIP を展開してビルドするだけ）なので、ZIP を手で落としている環境でもそのまま使える。

```bash
./scripts/update.sh                  # GitHub の main から更新
./scripts/update.sh --ref v0.3.0     # タグ / ブランチを指定
./scripts/update.sh --zip ~/dl.zip   # 手元の ZIP から更新（ネットワーク制限がある環境）
./scripts/update.sh --local          # 今のソースのまま作り直すだけ
./scripts/update.sh --install-cli /usr/local/bin   # CLI も入れ替える
```

インストール先は `AGENTRECIPES_INSTALL_DIR`、取得元は `AGENTRECIPES_REPO` で変えられる。
ダウンロードした ZIP 由来の隔離属性は差し替え時に外すので、Gatekeeper に止められない。

ビルドした `.app` にはソースの識別子が入る（例 `0.2.0 (35b7cfb)`、ZIP からのビルドは `0.2.0 (src-20260817)`）。
`/usr/libexec/PlistBuddy -c 'print :CFBundleShortVersionString' /Applications/AgentRecipes.app/Contents/Info.plist` で確認できる。

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

フォームが開くのは、Recipe を「実行時に Project を選ぶ」に設定したときと、
**⌥ + クリック**（引数・送信先・Preview を細かく調整したいとき）だけ。

メニュー下部に Herdr の接続状態と Agent 数、応答待ちの Recipe を表示する。

内部的には 実行 = `herdr agent prompt`、チャットに入力 = `herdr pane send-text` + `herdr agent focus`。

### 送信先の選び方

**既定は「新しいセッション」**。既存の作業に割り込まないよう、実行のたびに Agent を起動する。
実行時に送信先を聞くことはしない。Recipe ごとに変更できる:

| セッション | 動作 |
| --- | --- |
| **新しいセッション**（既定） | tab を作成 → `herdr agent start` → 実行 |
| 空いていれば再利用 | 同じ LLM の idle / done な Agent を使う（作業中は避ける）。無ければ新規 |

⌥クリックのフォームや CLI の `--agent <pane-id>` で明示指定したときは、その送信先に送る。

新しい Agent は Herdr workspace に作る。Recipe の「Herdr workspace」を「指定なし」にしていれば
`AgentRecipes` space を使い、無ければ最初の実行時に作成する（workspace作成時のroot paneを使用）。
「指定あり」にすると **workspace 名を自由入力**でき、同じ名前の space が無ければその名前で作成する。
既存の名前は「既存から選ぶ」から入力できる。

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
Recipe の「作業フォルダ」を設定してあると、cwd が一致する Agent だけを再利用対象にする。

### workspace と作業フォルダ

- **対象 workspace** は Herdr の workspace です。「空いていれば再利用」で指定すると、その workspace 内の空き Agent だけを候補にします。候補が無いときは、その workspace に新しい tab を作ります。
- **ローカル作業フォルダ** は Agent の `cwd` です。Prompt の `{{project}}` / `{{cwd}}` にも使われ、workspace とは別の概念です。
- Recipe に作業フォルダを設定していない場合は、Settings → General の **作業ディレクトリ（既定）** を使います。
  既定は Skill 実行専用の空ディレクトリ **`~/.agentrecipes`**（無ければ自動作成）。ホーム直下や
  `Application Support/AgentRecipes`（Recipe と設定の保存先）を cwd にすると、Agent から無関係なファイルや
  アプリ自身のデータに手が届いてしまうため、既定では使いません。

## CLI

```bash
agentrecipes init                                  # 保存先を初期化してサンプルを作成
agentrecipes list [query] [--favorites] [--json]
agentrecipes show <recipe>
agentrecipes preview web-research --url https://example.com
agentrecipes run review-diff --project ComposerSketch
agentrecipes copy|paste|submit <recipe> [--<arg> <value> ...] [--agent <pane-id>]
agentrecipes mcp [claude|codex|gemini] [--all]     # MCP の接続状況
agentrecipes agents | panes | workspaces | status  # Herdr の状態と現在の LLM
agentrecipes projects [--add ~/src/foo]
agentrecipes history [--limit 20]
```

Recipe の引数名が `mode` や `project` など CLI オプションの予約語と重なる場合は、
`--arg name=value` を使います。未定義の引数名はエラーとして表示されます。

```bash
agentrecipes run example --arg mode=full
```

送信先は聞き返さずに決まる。特定の Agent に送りたいときだけ `--agent <pane-id>` を指定する。

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

## 実行前のプレビュー

Recipe をクリックすると、**送る Prompt と送信先を確認する画面**を出してから実行する
（Settings → General「実行前にプレビューを表示する」、既定 ON）。

- 送信先（新しいセッションを起動するのか / どの Agent を再利用するのか）、作業フォルダ、Skill、結果の扱いを表示
- 展開済みの Prompt をそのまま確認できる（クリップボードを使う Recipe はバッジで警告）
- ボタンは「実行」「チャットに入力」「キャンセル」。画面内の「次回から確認しない」でそのまま OFF にできる

## 実行結果の確認

Submit したあと **応答完了まで待って結果を表示する**（Settings → General、既定 ON）。

- メニューバーのパネルに「応答待ち: <Recipe 名>」を表示
- 完了すると Result ウィンドウに Agent の出力（末尾）を表示。`Herdr で開く` でその Agent に移動、`コピー` でクリップボードへ
- Skill が `agent-recipes.result/v1` 契約で返した場合は、Markdown・表・リスト・JSON をリッチ表示する。不正または未対応の出力はプレーンテキストへフォールバックする
- 通知（右上の HUD）: 送信時 `Web ページ調査 — Sent to my-home / Codex`、完了時 `… の応答が完了しました`
- 待たない運用にするなら Settings でトグルを OFF。その場合は送信通知だけ出る

### 起動時の確認で止まる場合

新しいセッションの Agent は、フォルダの信頼確認・モデル選択・MCP のロードなどで、
しばらく入力を受け付けない。この間に送った Prompt は**受理されたように見えて実際には落ちる**ため、
次の順で扱う。

1. `interactive_ready` になり、状態が落ち着く (idle / done / blocked) まで待つ（最大 60 秒）
2. `blocked`（確認ダイアログ）なら **Prompt を送らない**。送るとダイアログの選択肢に文字を打ち込んでしまう
   （起動直後の一瞬の blocked は 8 秒だけ様子を見る）
3. 送ったあとに画面を読み、Prompt が入っていなければ 1 度だけ送り直す
4. 送れなかった場合は Result に「起動時の確認で止まっています」と出し、**確認に答えると続けて Prompt を送る**

画面を読めなかったときは送り直さない（同じ Prompt の二重実行を避ける）。

### Agent からの確認に答える

Agent が許可プロンプトや `(y/N)` で止まっている場合、Result ウィンドウの上部に**確認カード**が出る。

- 選択肢がボタンになり、押すと `herdr pane send-keys` で対応するキーを送る（番号選択はその数字、y/n は `y`/`n` + Enter）
- 「No, and tell Claude what to do differently」のように説明が要る場合は、自由入力欄から返信できる
- 回答後は応答が落ち着くまで待って読み直す。手動で読み直す場合は「最新を読む」
- 確認待ちのときは通知も「応答が完了しました」ではなく「確認を求めています」になる

内部では `herdr agent prompt --wait --timeout` で待ち、`herdr pane read` で出力を読み取る。
CLI も同じで `--wait [--timeout <ms>]`。

リッチ結果の JSON 契約と Skill 側の書き方は [docs/rich-results.md](docs/rich-results.md) を参照。

## MCP の接続状況

Skill が MCP のツールを使う場合、MCP が未接続だと実行が途中で止まってしまう。
Settings → **MCP** で LLM ごとの接続状況を確認できる。

一覧は **MCP ごとに 1 行**で、同じ MCP は LLM をまたいでまとめる。
右側に LLM のアイコン（Claude Code ✦ / Codex {} / Gemini ◆）を並べ、**その MCP が使える LLM だけカラー**、
未設定はグレー、接続失敗は警告アイコンになる。

```
chrome-devtools   npx -y chrome-devtools-mcp@latest      ✦ {} ◆
```

- `claude` / `gemini` は `mcp list` の health check の結果（接続済み / 接続失敗 / 承認待ち）を表示する
- `codex` は接続確認に対応していないため、設定の有無（設定あり / 無効）だけを表示する
- MCP の設定は cwd に依存するので、**Agent を起動するのと同じ作業ディレクトリ**でチェックする
- 同じ一覧を**メニューバーのパネル下部**（Herdr の接続状態の下）にも出す。クリックで MCP タブが開く

```bash
agentrecipes mcp            # 現在の LLM
agentrecipes mcp codex      # LLM を指定
agentrecipes mcp --all      # すべて（接続失敗があれば exit 1）
```

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

`Agent Recipes 用 Skill を作成` は、`agent-recipes-skill-creator` Skill を使い、
入力・副作用・結果形式が Recipe の契約に合う Codex Skill を作成するための Recipe です。

## Recipe と Agent Skill

Recipe は Agent Skill とほぼ同じ「作業単位」で、Skill に Prompt・入力・実行設定を加えた実行プリセットです。
フォーム入力、Clipboard の既定値、送信先、履歴、リッチ結果表示を Recipe 側で設定できます。Recipe Editor の
**ベース Agent Skill** で `SKILL.md` を選ぶと、その Skill の基本動作に Recipe 固有の Prompt 設定を重ねて実行します。
Skill 自体は標準の `SKILL.md` / `agents/openai.yaml` のままなので、Agent からも単独で利用できます。Recipe は Skill を生成・上書きしません。

Skill に `agents/openai.yaml` の `interface.default_prompt`、または `SKILL.md` / `agents/openai.yaml` の
`examples` があれば、Recipe Editor で既定 Prompt の取り込みや例の適用に使えます。取り込んだ後の編集内容は
Recipe 側だけに保存され、元の Skill は変更しません。

## Settings

使用する LLM（既定 Claude Code）/ Launch at Login / 通知 / 実行前プレビュー / 応答待ちと結果表示 / 作業ディレクトリ（既定）/
herdr のパス / Herdr 接続状態 / MCP 接続状況 / Skill Sources とエディタ / Recipe ディレクトリ / Debug logging / 履歴件数。

Manage Recipes 画面の右上の歯車からも開けます。

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

### 動作確認レシピ

`動作確認` (`agent-recipes-check`) は、アプリの機能を 1 クリックで一通り点検する。
Agent は次の 7 項目を判定し、**リッチ結果**で返す。

| 項目 | 見るもの |
| --- | --- |
| delivery | マーカーと送信日時が Prompt どおり届いたか |
| variables | `{{date}} {{time}} {{project}} {{cwd}} {{clipboard}}` が展開されたか |
| cwd | `pwd` が Prompt の CWD と一致するか（送信先の解決が正しいか） |
| session | この Prompt が最初のやり取りか（新しいセッションで動いたか） |
| skill | Skill が読み込めたか |
| mcp | Agent から見えている MCP ツール（名前だけ。分からなければ unknown） |
| rich | `agent-recipes.result/v1` で返せているか |

`確認カードの動作確認` (`agent-recipes-check-confirm`) は、Agent が `(y/n)` で質問して止まる状態を作る。
Result ウィンドウに確認カードが出るので、アプリから答えられるかを試せる。

どちらも `pwd` 以外のコマンドを実行せず、ファイルも変更しない。

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
Target Resolver のセッション方針と優先順位 / 新規 Agent 起動シーケンス（workspace 名の作成・再利用を含む）/ RecipeRunner の Copy・Paste・Submit をカバー。
Herdr は Fake Runner に差し替えているので、テスト実行で実際の Agent へ送信されることはない。

## 公開・ライセンス

このプロジェクトは [MIT License](LICENSE) で公開する想定である。公開前に`LICENSE`の
`<YOUR NAME OR ORGANIZATION>`を正しい著作権者名へ置き換えること。

IssueやPull Requestを送る場合は [CONTRIBUTING.md](CONTRIBUTING.md)、脆弱性や意図しない
データ開示は [SECURITY.md](SECURITY.md) を参照する。
