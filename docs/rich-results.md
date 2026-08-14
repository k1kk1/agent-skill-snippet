# リッチ結果フォーマット

Agent Recipes は、Herdr の pane 出力に次のコードフェンスが含まれると、内部の JSON をリッチ結果として表示する。
Codex TUI のようにコードフェンスを描画しない画面では、pane 内の最後の妥当な同スキーマの JSON を検出する。
検出できない出力や不正な JSON は、従来どおりプレーンテキストで表示する。

````text
```agent-recipes-result
{
  "schema": "agent-recipes.result/v1",
  "title": "任意のタイトル",
  "blocks": []
}
```
````

## 共通フィールド

| フィールド | 必須 | 内容 |
| --- | --- | --- |
| `schema` | Yes | `agent-recipes.result/v1` 固定 |
| `title` | No | Result 上部のタイトル |
| `blocks` | Yes | 1 件以上の表示ブロック |

## ブロック

Markdown:

```json
{"type":"markdown","content":"**重要**: 完了しました"}
```

表（行の不足セルは空欄、余分なセルは表示しない）:

```json
{
  "type": "table",
  "columns": ["名前", "状態"],
  "rows": [["Build", "OK"], ["Test", "OK"]]
}
```

リスト（`style` は `bullet` / `numbered` / `checklist`。省略時は `bullet`）:

```json
{"type":"list","style":"checklist","items":["[x] 完了","[ ] 未完了"]}
```

JSON（`value` には任意の JSON 値を指定できる）:

```json
{"type":"json","value":{"success":true,"count":2}}
```

Skill には、最終回答をこのフェンスだけに限定し、有効な JSON を返すよう指示する。完全な例は
`skills/agent-recipes-rich-result-test/SKILL.md` を参照する。
