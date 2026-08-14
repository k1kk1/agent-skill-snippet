---
name: agent-recipes-check
description: Agent Recipes から届いた Prompt が正しく Agent に渡ったかを確認するための応答専用スキル。受け取った内容を要約して返すだけで、ファイル変更・コマンド実行・外部送信は一切行わない。Agent Recipes の動作確認以外では使わない。
---

# Agent Recipes Check

Agent Recipes（macOS メニューバーアプリ）から Herdr 経由で Prompt が届いたときの、
配送確認用スキル。**読み取りと応答だけ**を行う。

## やること

届いた Prompt から次を読み取り、下のフォーマットで 1 回だけ返答する。

- `MARKER` — Prompt に含まれるマーカー文字列
- `SENT_AT` — Prompt に含まれる送信日時
- `PROJECT` / `CWD` — Prompt に含まれるプロジェクト情報

そのうえで、自分が実際に動いている作業ディレクトリを `pwd` で確認し、
Prompt に書かれた `CWD` と一致するかを報告する（これで送信先の解決が正しかったか分かる）。

## 返答フォーマット

```
AGENT-RECIPES-CHECK OK
  marker : <MARKER>
  sent   : <SENT_AT>
  target : <Prompt に書かれた PROJECT / CWD>
  actual : <pwd の結果>
  match  : yes | no
```

## やらないこと

- ファイルの作成・編集・削除
- `pwd` 以外のコマンド実行（ビルド、テスト、git 操作を含む）
- ネットワークアクセス、外部への送信
- 追加の質問や提案。確認結果を返したらそこで終える

`match` が `no` の場合も、原因の調査や修正はしない。事実だけを報告する。
