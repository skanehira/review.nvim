# ai-prompt (コメントの AI エージェント向けプロンプト出力)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした。MUST 5)

## 何を作るか

蓄積したコメントを、AI コーディングエージェント (Claude Code 等) にそのまま渡せるプロンプト文字列として整形し、クリップボードと yank レジスタへコピーする。ファイルパスはエージェントがファイル添付として解釈できる先頭トークン `@<path>` の形式とする。

## 入出力と振る舞い

**プロンプト書式 (コア決定)** — 1 コメント = 見出し行 (`@` パス + 行アンカー) + 本文行の組。コメント間は空行:

```text
Review the changes in main..feature. Please address the comments below.

@lua/review/handlers/comments.lua#L42-L48
この関数は行番号計算を重複実装している。core/diff に寄せて削除してよい

@lua/review/core/diff.lua#L10
setup 側で config を deep merge したい
```

- 行アンカー: range が 1 行なら `#L<行>`、複数行なら `#L<始>-L<終>` (ともに 1 始まり、new 側ファイルの行番号 = head 窓の実バッファ行。**保存済み内容に対する行番号** — プロンプト生成時点で head 窓に未保存編集があっても行番号は直近保存/リフレッシュ基準。エージェントはディスクを読める)
- パスの規則: worktree あり (PR) は worktree 内の絶対 path (`@<worktree>/<file>#L..`)、なし (branch) はリポジトリ相対 path (`@<file>#L..`)。いずれも「開いたエージェントが実際に読める」ことを保証する — branch モードは現在のチェックアウト (未コミット含む保存済み状態) がそのもの、PR は自前 worktree が head チェックアウト + ユーザー編集
- 見出し行 (all 出力のみ、1 行)。完全な定型文 — ブランチ: `Review the changes in <base>..<head>. Please address the comments below.`、PR: `Review PR #<n> (<url>) — <base>..<head>. Please address the comments below.` (上記サンプルと一致させる)
- 本文 (body) は複数行のまま続く行として置く。行内に `@` を含む body は加工しない (エージェント側解釈に任せる)
- `state=outdated` のコメントは既定で除外し、除外個数を INFO 通知する (位置が信用できないものをプロンプトに入れない)

**出力経路**:

| 経路 | 挙動 |
| --- | --- |
| `:Review prompt [file]` | 全コメント (file 指定時はそのファイルのみ) を 1 文字列に整形。クリップボード provider (`+`/`*` レジスタ) があれば両方に、常に `"0` へも入れる。本文 0 件なら「コメントがありません」INFO |
| キーマップ `y` (head 窓) | カーソル行 range に含まれるコメントのみ同上 (outdated の既定除外も同じルール。カーソル行のコメントがすべて outdated の場合はコピーせず INFO「outdated のためプロンプトに含めませんでした」) |
| Lua API | `require("review").prompt_all(opts)` / `prompt_for_file(path, opts)` が結果型 `{ok, data={text, count}}` を返し、copy を opts (`copy=false` 可) で制御 (テストフック) |

整形は純粋関数 `core/prompt.lua` (build(comments, ctx) → string) に置き、UI 層はクリップボード書込のみ担う。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| プロンプト文字列組み立て (行アンカー・パス規則・outdated 除外・見出し) | core | `lua/review/core/prompt.lua` (+ `_spec`) |
| コピー先解決 (レジスタ・クリップボード) | handlers | `lua/review/handlers/prompt.lua` |
| `:Review prompt` 委譲・file 引数解決 | facade | `lua/review/init.lua` (command 拡張) |
| `y` キーマップ | handlers | `lua/review/handlers/comments.lua` (既存拡張) |

## エッジケースの決定

- active セッションが無い状態の `:Review prompt` / `prompt_*`: `E_NOT_ACTIVE` を同期で返す DESIGN.md「API 一覧」の契約どおり、WARN「レビュー進行中セッションがありません」を出す (クリップボードは触れない)
- クリップボード provider が無い (`clipboard.provider()` が nil、headless 等): WARN を出し `"0` には入れる (失敗で止めない。E2E はこのレジスタで検証する)
- file 引数に diff に存在しないパス: 「そのファイルはレビュー対象の diff にありません」INFO。曖昧パスの補完 (`<Tab>` customlist = 対象ファイル一覧) を付ける
- body が空のコメントは作成時点で入力 float が拒否 (1 文字以上必須)
- 全コメントが outdated のセッション: 見出し + 除外 INFO のみで本文なしのプロンプトは生成しない (「有効なコメントがありません」で終了)
- scratch 縮退セッションの prompt/y: `@<相対 path>#L` は現在のチェックアウトの内容を指し、レビュー時の head 内容と一致する保証がない — プロンプトの定型見出しは変更せず、生成・コピー時に INFO « scratch レビューのため @path は現在の作業ツリーを指します (レビュー時内容と違う場合があります)» を添える (エージェントへ暗黙に誤った前提を置かせない)
- 巨大コメント数 (100 件超): 連結文字列の生成はループ 1 回。性能上の分割は不要と判断 (クリップボード自体の上限は対象外)

## テスト方針

- 単体 (core/prompt): ブランチ/PR ヘッダ、worktree 絶対パス / 相対パスの切替、1 行・複数行 range アンカー、複数行 body の連結、outdated 除外と件数、コメント順 (作成順 = id 昇順)
- E2E (golden path): fixture でコメント 2 件作成 → `y` で `"0` レジスタに `@<path>#L..` と本文が入る → `:Review prompt` でヘッダ + 全件を含むことと順序が正しいことを assert (レジスタ比較は headless でも決定論的)
