---
name: agent-recipes-check
description: Agent Recipes の動作確認スキル。届いた Prompt・変数展開・作業ディレクトリ・新規セッション・MCP の見え方を点検し、リッチ結果の契約で返す。読み取りと応答だけを行い、ファイル変更・外部送信はしない。Agent Recipes の動作確認以外では使わない。
---

# Agent Recipes Check

Agent Recipes（macOS メニューバーアプリ）から Herdr 経由で届いた Prompt を点検し、
アプリ側の機能が一通り動いているかを 1 回の応答で報告する。**読み取りと応答だけ**を行う。

Prompt の `CHECK:` 行でモードが決まる。

| CHECK | やること |
| --- | --- |
| `full`（既定） | 下の点検項目をすべて確認し、リッチ結果で返す |
| `confirm` | 確認ダイアログの動作確認。質問を 1 つ返して**そこで応答を終える** |

## CHECK: full

### 点検項目

Prompt には次の行が入っている。値が `{{...}}` のまま残っていたら、その項目は fail。

```
MARKER:    <マーカー文字列>
SENT_AT:   <日付 時刻>
PROJECT:   <Project 名。未設定なら空>
CWD:       <Agent が動くべき作業ディレクトリ>
CLIPBOARD: <クリップボードの内容。空のこともある>
```

これをもとに、次の 7 項目を判定する。

| id | 見るもの | ok の条件 |
| --- | --- | --- |
| `delivery` | MARKER / SENT_AT | 値が入っていて、`{{` が残っていない |
| `variables` | SENT_AT / CWD / CLIPBOARD | 日付・時刻・パスの形になっている（CLIPBOARD は空でも可） |
| `cwd` | `pwd` の結果 | Prompt の CWD と一致する |
| `session` | この会話の履歴 | この Prompt が最初のやり取り（新規セッション） |
| `skill` | このスキル自身 | 読み込めている（この応答が返せている時点で ok） |
| `mcp` | 使える MCP ツール | 一覧を報告する。0 件でも ok、取得できなければ unknown |
| `rich` | 応答の形式 | 下の契約どおりに返せている |

- 実行してよいコマンドは **`pwd` だけ**。それ以外は使わない
- CLIPBOARD は**内容を書き写さない**。先頭 20 文字と文字数だけ報告する
- MCP ツールは**名前だけ**を挙げる（呼び出さない）

### 返し方

説明文をフェンスの外に書かず、`agent-recipes-result` コードフェンスに JSON を 1 つだけ入れる。

````
```agent-recipes-result
{
  "schema": "agent-recipes.result/v1",
  "title": "Agent Recipes 動作確認",
  "blocks": [
    { "type": "markdown", "content": "**結果: 7/7 ok**\n\nマーカー `PING` / 送信 2026-08-17 15:00" },
    {
      "type": "table",
      "columns": ["項目", "結果", "詳細"],
      "rows": [
        ["delivery", "ok", "MARKER=PING SENT_AT=2026-08-17 15:00"],
        ["variables", "ok", "未展開の {{ }} なし"],
        ["cwd", "ok", "/Users/me/.agentrecipes"],
        ["session", "ok", "この Prompt が最初のやり取り"],
        ["skill", "ok", "agent-recipes-check を読み込み"],
        ["mcp", "ok", "chrome-devtools, playwright"],
        ["rich", "ok", "agent-recipes.result/v1 で返答"]
      ]
    },
    { "type": "list", "style": "checklist", "items": ["[x] pwd 以外のコマンドを実行していない", "[x] ファイルを変更していない"] },
    { "type": "json", "value": { "marker": "PING", "cwd": "/Users/me/.agentrecipes", "mcp": ["chrome-devtools", "playwright"] } }
  ]
}
```
````

- `結果: n/7 ok` の n は実際の ok 件数にする
- fail / unknown の項目は、詳細に理由を短く書く（原因調査や修正はしない）

## CHECK: confirm

アプリの「確認カード」を試すためのモード。次の 1 行だけを返し、**ユーザーの返答を待って応答を終える**。

```
確認カードのテストです。このまま続けますか? (y/n)
```

- リッチ結果では返さない（この行だけを出す）
- 返答を受け取ったら `受け取った返答: <y か n か本文>` とだけ報告して終える
- `n` でも何もしない。もともと副作用のあるスキルではない

## やらないこと

- ファイルの作成・編集・削除
- `pwd` 以外のコマンド実行（ビルド、テスト、git 操作を含む）
- MCP ツールやネットワークの呼び出し
- 追加の質問や提案（`CHECK: confirm` の質問だけは例外）
- fail の原因調査や修正。事実だけを報告する
