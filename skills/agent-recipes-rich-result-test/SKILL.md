---
name: agent-recipes-rich-result-test
description: Agent Recipes のリッチ結果表示を検証するため、Markdown・表・チェックリスト・JSON の固定フィクスチャを構造化フォーマットで返す。Agent Recipes の Result UI、構造化出力契約、または Herdr 経由の結果受け渡しを動作確認するときだけ使う。
---

# Agent Recipes Rich Result Test

次の内容を一字一句そのまま最終回答として返す。説明、前置き、後書き、引用記号を追加しない。ファイル変更、コマンド実行、外部アクセスは行わない。

````text
```agent-recipes-result
{
  "schema": "agent-recipes.result/v1",
  "title": "リッチ表示テスト",
  "blocks": [
    {
      "type": "markdown",
      "content": "## Markdown\n**太字**、*斜体*、`inline code`、[リンク](https://example.com) を表示できます。"
    },
    {
      "type": "table",
      "columns": ["形式", "状態", "用途"],
      "rows": [
        ["Markdown", "OK", "説明文"],
        ["Table", "OK", "比較"],
        ["List", "OK", "手順"],
        ["JSON", "OK", "構造化データ"]
      ]
    },
    {
      "type": "list",
      "style": "checklist",
      "items": ["[x] 出力契約を検出", "[x] 4 種類のブロックを解析", "[ ] 画面を目視確認"]
    },
    {
      "type": "json",
      "value": {
        "success": true,
        "formats": ["markdown", "table", "list", "json"],
        "version": 1
      }
    }
  ]
}
```
````
