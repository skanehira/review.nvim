# コメント一覧 (横断)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした)

## 何を作るか

セッションの全コメントをファイル横断の一覧で閲覧し、任意のコメント位置へ移動できる
(MUST 6)。`<leader>c` (head/base 窓・file panel) または `:Review comments` で
専用バッファ `review://comments/<session-id>` をレビュー tab の最下部に全幅
(高さ既定 10 行・`config.comment_list_height` で変更可) の水平分割で開く。どの
窓・どの tab から押しても位置は変わらない。一覧はコメント CRUD・
差分再取得 (drift 再検証)・close に追随して再 render される。行操作で削除/編集/
prompt yank までできる (diff 窓の同名キーと同一動作)。

## 入出力と振る舞い

### 表示

1 行 = 1 コメント:

```
<path>:<line>[-<end>]  [<id>]  <body 1 行目 (60 字 + …)>[ ⚠ outdated]
```

- body は `\n` 分割の 1 行目のみ。60 **文字**を超える場合 `vim.fn.strcharpart` で
  60 文字に切詰め + `…` (UTF-8 を分断しない。複数行 body も 1 行目のみ = 一覧は
  索引。全文はジャンプ先 `i` の閲覧 float)
- `state == 'outdated'` は末尾 ` ⚠ outdated`。path span は `ReviewPanelFile`、
  outdated 印 span は `ReviewCommentOutdated` (新規 hl グループは作らない)
- 対象集合: 絞り込み (`/`) 適用後のファイル集合。折畳は反映しない (折り畳んだ
  dir のコメントも出す — view 操作でデータを隠さない)
- 並び: **file panel と同一の tree 表示順** (`handlers/session` の既存 local
  `visible_order()` を公開 API 化 (`opts = { collapsed?, mode? }`)。一覧は
  `{ collapsed = {}, mode = 'tree' }` で呼ぶ — panel が `i` の list 表示でも一覧は
  tree 順固定 = `treelist.build` を単一源にする。`file_order_sorted` は path 昇順
  なので直接使わない) → 同一ファイル内 line 昇順 (end_line は見ない) → 同一 line
  はセッション配列順 (作成順)
- 直近 parse の files map に無いファイルのコメント (refresh 後などで順序リストに
  現れない): 末尾へ path 昇順。絞り込み外のファイルのコメントは末尾にも出さない
  (上の対象集合の規則が優先)
- 0 件: «コメントはありません» の 1 行
- winbar: `<base>..<head 表示名 (diff-review「窓装飾」)> · <N> comments` (N =
  一覧の表示行数 = 絞り込み適用後のコメント件数。0 件時は 0) + 一覧に出る outdated
  が 1 件以上のとき ` · ⚠M` (M = 表示中の outdated 総数)。panel winbar の `⚠N`
  (集約先の無い outdated) とは別の数

### 操作

| 操作 | 起きること |
| --- | --- |
| `<leader>c` / `:Review comments` | 一覧を開く (レビュー tab の最下部に全幅の水平分割 — どの窓・どの tab から押しても位置は変わらない。tab gate を持たないため、別 tab から押すと review tab へ切替えてから開く)。既に開いていればその窓へ focus (別 tab でも tab を切替えて focus。再分割しない。内容は常に最新)。active 0 件はコマンド層が WARN «アクティブなセッションがありません»、handler は `E_NOT_ACTIVE` を返す |
| `<CR>` | カーソル行コメントの位置へジャンプ (下記) |
| `d` | 行コメントを削除 (一覧専用の arming 二重押し = 同じ comment id・2 秒内。diff 窓の arming とは共有しない。arming は編集確定・削除確定で解除する (diff 窓と同じ規則)。通知文言は diff と同じ «コメント %s を削除しました») |
| `e` | 行コメントを編集 (diff `e` と同じ float。確定で session 永続化 + 追随) |
| `y` | 行コメント 1 件の prompt を "0 (+クリップボード) へ (書式は features/ai-prompt.md「出力経路」。outdated 行は diff 窓と同じくコピーせず INFO «outdated のためプロンプトに含めませんでした») |
| `q` | 一覧窓を閉じる (セッション状態は変えない) |

### ジャンプ

この節の INFO / WARN 文言が正本 (DESIGN.md キーマップ表から参照される)。

- ジャンプ前に review tab を current tab にする (`open_file` はレビュー 3 窓前提)。
  review tab / active セッションが無ければ WARN «アクティブなセッションがありません»
- 対象ファイルが現在の差分にあり、`open_file` が実ファイルまたは scratch 縮退 head
  を開けるとき: `open_file(path, { line })` 相当で開き、head 窓を記録行
  (`comment.line`) へ移動する (行数外は最終行へクランプ)。fold に隠れた行は
  `zv` で開く
- outdated コメント: 記録行へ移動し INFO
  «コメントは outdated です。記録された行へ移動します»
- 差分に無いファイル: 移動せず WARN «このファイルは現在の差分に無いため移動できません»
- binary / 削除の告知表示 (差分にはあるが実体を開けない): 移動せず WARN
  «binary / 削除の告知表示のため移動できません»
- 縮退 head (scratch) は `git show` の非同期充填後に位置決めする (open_file の
  «移動行» オプションで確定時に行移動 = 呼び出し側で待たない)

### 追随 (再 render)

- コメント CRUD (commit_comment_change) / 差分再取得 (refresh → anchor 再検証) /
  **絞り込みの適用 (`/` の確定)** で一覧を再 render (表示中のときだけ。非表示は
  開く時に最新を render)
- カーソルは comment id で追従。削除で選択行が消えた場合は同じ行位置の次コメント
  (末尾なら最終行) へ
- session close (`q` / `:Review close`) では再 render せず、一覧窓を閉じるだけに
  する (バッファは bufhidden=wipe。閉じる直前の render は行わない)
- ユーザーが `:close` / TabClosed で一覧窓を手で閉じた場合: bufhidden=wipe で
  バッファも消え、`BufUnload` で一覧 state を掃除する。次回 `<leader>c` は最下部に
  新規の一覧窓を作る

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| 一覧バッファの render (行整形・並び・hl span・winbar・カーソル追従) | ui | `lua/review/ui/commentlist.lua` (新規。buffer `review://comments/<session-id>`、filetype `review-list`、`review_meta = { kind = 'commentlist', session_id }`) |
| 一覧バッファの buffer-local キー張込 (`keymaps.commentlist`) | ui | `lua/review/ui/commentlist.lua` (render 時に張る) |
| 開閉・ジャンプ・削除/編集/yank・追随 | handlers | `lua/review/handlers/comments_list.lua` (新規。sessions_list.lua と同型) |
| 表示順の解決 (絞り込み適用・折畳無視・tree 固定) | handlers | `lua/review/handlers/session.lua` の既存 local `visible_order()` を公開 API 化 (`opts = { collapsed?, mode? }`。省略時は現行 = panel の折畳/mode、一覧は `{ collapsed = {}, mode = 'tree' }`)。`treelist.build` を単一源にする (`file_order_sorted` は path 昇順なので直接使わない) |
| «移動行つき open» | handlers | `lua/review/handlers/session.lua` の `open_file(path, opts{line})` へ任意引数を追加 (既存呼び出しは nil) |
| `<leader>c` mapping | ui | `lua/review/ui/keygate.lua` (`comments_list` op。`DISPATCH.comments_list = { 'review.handlers.comments_list', 'open' }` を登録してから install_sync で張る) |
| file panel の `<leader>c` 張込 | ui | `lua/review/ui/filepanel.lua` の `paint_keymaps` に `keymaps.sidebar.comments_list` を追加 (sidebar キーは keygate ではなく filepanel が張る) |
| 既定キー | config | `lua/review/config.lua` に `keymaps.diff.comments_list` / `keymaps.sidebar.comments_list` + `keymaps.commentlist` (`jump='<CR>'` / `delete='d'` / `edit='e'` / `yank='y'` / `close='q'`。意味は diff と同一・config 節は独立) |
| `:Review comments` | facade | `lua/review/init.lua` に `cmd_comments` を追加し、`M.subcommands` / `USAGE` / customlist 補完を更新 (`plugin/review.lua` は登録のみで変更不要) |
| close 経路の一覧掃除 | ui/handlers | `lua/review/ui/windows.lua` / `handlers/session.lua` (既存 close 掃除に一覧を追加) |
| 再 render の呼び出し | handlers | `lua/review/handlers/session.lua` の `commit_comment_change` / `apply_refresh` / 絞り込み適用 (`filter_sidebar`) の 3 経路から `comments_list.refresh()` を呼ぶ (一覧 handler は session を top-level require するため、session 側は発火時に `require('review.handlers.comments_list').refresh()` を遅延解決する — DESIGN「既知の制約」) |

キー追加に伴う docs 同期義務 (AGENTS.md の 6 点) を実装に含める: `config.lua`
defaults + `config_spec` のリテラル期待 2 箇所 / `ui/help.lua` SECTIONS +
`help_spec` の完全一致行 / `doc/review.txt` (KEYMAPS 既定値表・`:Review comments`
節・`:helptags` で tag 解決) / `README.md` キー表 / DESIGN.md デフォルトキーマップ
表 + 本機能設計書の操作表。

## エッジケースの決定

- コメント 0 件: «コメントはありません» 1 行 + winbar `0 comments` (空でも開ける)
- 一覧を開いたまま diff 側で `q` (close): 一覧窓も閉じる (残骸の窓・バッファを残さない)
- session 切替 / `:Review` 復元: 旧 session の一覧は close 経路で閉じる。新 session の
  一覧は `:Review comments` で開き直す (一覧の自動再オープンはしない)
- 同一行に複数コメント: 1 コメント = 1 行 (同じ path:line が複数行並ぶ。順序は作成順)
- body が複数行: 1 行目のみ表示 (全文はジャンプ先 `i`)。60 字切詰め
- 折畳・絞り込み: 折畳は反映しない (折り畳んだ dir のコメントも出す)。絞り込みは
  反映する (絞り込み外のファイルのコメントは出ない)
- 削除後のカーソル: 同じ行位置の次コメント。末尾だった場合は最終行。0 件に
  なった場合は 1 行目 («コメントはありません») へ
- ジャンプ対象のファイルが告知窓 (binary/削除): WARN
  «binary / 削除の告知表示のため移動できません»、差分外: WARN
  «このファイルは現在の差分に無いため移動できません» (文言の正本は「ジャンプ」節)
- 一覧窓をユーザーが別 tab へ移した場合: `<leader>c` はその tab へ切替えて focus。
  `<CR>` ジャンプは review tab を current にしてから `open_file` する (ジャンプ節)
- 一覧窓の drift (ユーザーが `:edit` 等で一覧窓の中身を差し替えた): 役割は内容
  (`review_meta`) から導くため、次回 `<leader>c` は新しい一覧窓を開く (壊れた窓は
  触らない)
- 一覧バッファへ `:w` しても保存先は無い (nofile。既存 scratch と同じ)
- `<leader>c` の gate 不成立 (ユーザー窓): no-op (leader 前置キーに built-in の
  意味は無い)

## テスト方針

- unit: `ui/commentlist_spec` (行整形・順序・0 件・winbar・hl span・カーソル追従)、
  `handlers/comments_list_spec` (open 冪等 focus / `<CR>` ジャンプ (実ファイル・
  縮退・outdated・告知 WARN) / `d` arming / `e` / `y` / `q` / CRUD・refresh・close 追随)
- keygate: `<leader>c` の非 expr 同期発火 + ユーザー衝突 skip (keygate_spec の既存
  pin に追記)
- docs 同期: `config_spec` (既定値リテラル 2 箇所) / `help_spec` (SECTIONS 完全一致
  行) / `doc/review.txt` (`:helptags` の全 tag 解決) / `README.md` キー表 の更新を
  同時に行う (AGENTS.md 同期義務)
- e2e: golden path 1 本 (`tests/e2e/phase6.lua` 新規 + `scripts/e2e.sh` 追加):
  コメント 2 件 (別ファイル) → `<leader>c` → 一覧行 2 件 → `<CR>` でジャンプ →
  一覧へ戻り `d` 二重押し → 行消滅 + JSON 1 件。実 PTY の leader 遅延回帰
  (非 expr 同期) は tmux 実測手順を commit メッセージに残す
