# diff-review (ブランチ差分レビューとコメント)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした。MUST 1)

## 何を作るか

2 つの git ref (base..head) の diff を Neovim 内の 2 ペイン UI (変更ファイル一覧 sidebar + unified diff バッファ) で開き、カーソル / visual-line で行指定してコメントを作成・編集・削除する。レビュー開始からコメント蓄積までの核。永続化の「書く」処理自体は store/ に委譲し、ここでは保存のトリガ (INV-4) までを保証する。

## 入出力と振る舞い

**開始** `:Review start <base> [head]`:

1. `:Review start` は base 必須 (1 引数以上)。head 省略時 (2 引数目なし) は `vim.ui.input` + `completion=customlist` (branches → tags の順) で head を選択。0 引数は usage 通知で受けつけない
2. `git diff <base> <head>` (config `diff_context` 指定時は `-U<n>`) を非同期実行 (DESIGN.md「横断規約」参照)。ref 解決不能は `E_REF` を通知して UI を開かない
3. パース結果からセッションを組み立て、UI を開き、save を呼ぶ (persistence-restore)

**diff バッファ** (`review://diff/<session>/<file>` scratch、filetype `diff`、`wrap=off`、`foldmethod=expr` で hunk とファイル冒頭を fold 可能):

| 領域 | 内容 |
| --- | --- |
| ヘッダ行 | `■ A lua/foo.lua +12 -3` (変更種別 = A/M/D/R、追加/削除行数) |
| hunk 行 | `@@ ... @@` と diff 本体。`+` 行は new 側ファイル行番号を保持し、extmark の対象になる |
| 窓装飾 (chrome) | review 窓 (diff / sidebar / list) は `config.winbar=true` (既定) で winbar に `base..head · path · +a -d · N comments` 等を出す。winbar の window-local set は global へ漏れる (実測) ため、global `winbar` には `%{get(b:,"review_winbar","")}` 式を 1 度だけ入れ、表示文字列は各レンダラが buffer-local var に持つ。ユーザーが既に winbar を設定している場合は上書きしない。`config.number=false` (既定) で review 窓の行番号を窓単位に off (global 不変。setl を `nvim_win_call` 経由で実行 — `vim.wo[w]` / `nvim_win_set_option` の local 指定も他窓経由で波及した実測あり)。**窓に buf を当てる側 (handlers の render 直後) で必ず再適用する** — 開通後も窓が差し替わる経路があり、render 時点の適用だけでは new 窓が装飾を継承しない |
| コメント表示 | コメント対象は `+` 行とコンテキスト行 (new 側に存在する行) で、diff バッファ上の対応する行に namespace `review_comment` の extmark を置く (下線 hl `ReviewCommentLine`)。**行末 virt text は件数アイコンのみ** (`💬 N`、outdated を含む group は `💬 N (⚠M)`)。本文は**行下スレッド**として extmark の virt_lines に group 単位で全文を出す (GitHub Files changed の表示順に合わせ row-push を受け入れる代わりに、virt_lines は buffer 行を占有しないので new 側行番号写像・c/e/d/o の位置契約は不変。fold 時は自動的に非表示)。1 行 = `  [c1] 本文` (outdated は `⚠ [c1] 本文` gray、continuation 行は prefix 幅ぶんインデント、group 内コメント間は空白区切り 1 行)。長文は 10 行で `… (i で全文)` に打ち切り、全文は `i` の read-only 窓が正しい経路。**行が new 側差分から消えた outdated** (= 位置無し) はファイルヘッダ行に集約し、eol を `⚠ N outdated (prompt 除外中)` + virt_lines に本文一覧。コンテキスト行上でも位置は同一規則。`-` 行 (new 側行番号なし) には付けない。thread mark は見出し extmark と同一位置に併合する (同一 anchors の複数 extmark は取得順が不定で spec 契約にできない — 実測の教訓)。extmark の highlight は syntax より前面に出るため diff の +/- 配色と競合しても下線は視認できる |

**操作** (キーバインド既定値は DESIGN.md「API 一覧」が正本。すべて buffer-local、`silent nowait`):

| 操作 | 起きること |
| --- | --- |
| `c` (normal) | 対象 range = カーソル位置の new 側行 (`-` 行 = new 側行番号が無ければ WARN で開かない)。コメント入力 float (マルチライン対応 scratch buffer、insert で開始、操作契約: Normal `<CR>` 確定 / insert `<CR>` 改行 / `q` 閉じる [本文なし=キャンセル、本文ありは閉じず続けて q で破棄] / `<C-y>` = insert 確定のエイリアス / `<Esc>` = Normal へ戻るだけで閉じない。窓 title に対象 `path:line[-end]` と確定/閉じるのヒントを常時表示。終端経路は必ず stopinsert してから窓を閉じる (残留 insert が diff バッファを傷めない — UX review F8)) を開く。確定でコメント追加 → extmark 再描画 → 即時 save |
| `c` (visual-line) | 対象 range = 選択範囲の先頭〜末尾の new 側行 (`+` 行とコンテキスト行が対象、削除専用行を除く)。選択内に new 側行が無ければ WARN で開かない |
| `e` | カーソル行のコメントを編集。複数ある場合は vim.ui.select で対象を選ぶ (既定 provider は番号入力の inputlist になる — ユーザー help に記載、UX review F11)。body を事前入力した float を開き、確定で更新 → save |
| `d` | カーソル行 (range 内) のコメントを削除。arming 二重押し: 1 回目は対象を armed + WARN にして削除しない、同じコメントへ待機窓 (2 秒) 内にもう一度 d で削除確定 → save。他行移動・e での編集確定・窓経過で arming 解除される (armed は object 参照比較 + 編集確定時の明示解除。vim 筋 `dd` でも 1 件しか消えない) |
| `y` | カーソル行 range に含まれるコメントのプロンプトをコピー (ai-prompt「出力経路」参照) |
| `q` | `:Review close` と同じ (pr-worktree「セッションとレビューの終了」参照)。コメント 0 件なら確認なしで閉じる |
| `<F1>` | キーバインドと操作概要の help float (`<Esc>`/`q` で閉じる) |
| `]d` / `[d` | 一覧順 (パス昇順) の次 / 前のファイルを右ペインに開く。端は無動作 (`[c`/`]c` の hunk 移動と同感)。処理は sidebar `<Enter>` と同一 (viewed=true + save + focus は diff 窓に留まる)。ftplugin 標準の `[c`/`]c` (hunk 移動) は `filetype=diff` なのでそのまま使える |
| `S` | focus を sidebar へ移す。一覧窓が閉じられていた場合は現 diff 窓の左に再建 (窓役割の修復は UX review F1 系と同じ内容導出) |
| `i` | カーソル行範囲のコメント全文を read-only float で閲覧 (`ui/commentview`)。id / path:line[-end] / outdated 表示。閉じるのは `q` / `<Esc>` / `<CR>` のみ (編集は `e`) |

**sidebar** (左 30 桁、scratch、filetype `review-list` — syntax は持たず buffer-local キーマップと hl group の適用先。キーは DESIGN.md「デフォルトキーマップ」参照):

| 操作 | 起きること |
| --- | --- |
| 表示 | 1 ファイル 1 行 `<status> <path> +<a> -<d>`、パス昇順。viewed のファイルは行頭に `[✓]`。`<Enter>` → 右ペインをそのファイルの diff バッファに差し替え (ファイル先頭へスクロール) + **focus を diff 窓へ移動** (直後の c/e が効く位置に立つ — UX review F12) + viewed を true にして save。右ペイン窓が側に閉じられていた場合は sidebar 隣へ vsplit 再建する (無反応にしない — UX review F1/F18)。差分はファイルごとに別バッファ (複数ファイルを 1 バッファへ連結しない — fold と行番号管理が単純になるため) |
| `x` | viewed 切替 → save |
| `/` | vim.ui.input で絞り込み語を受け取り、path 大文字小文字無視の部分一致で一覧を再描画 (空入力 = 解除、Esc = 現状維持、一致 0 件は空一覧 + winbar に解除手順)。絞り込みは view state (session JSON に載せない / 開き直し・close で解除)。`<Enter>`/`o`/`x` の行紐付けと `]d`/`[d` の file step は同じ可視集合を辿る (現在 diff が集合外なら `]d` は先頭候補を開く) |
| `o` | そのファイルの実ファイル開く (pr-worktree「実ファイル参照」参照)。削除ファイルは不可と通知 |
| `q` | diff と同じくセッション終了 |

セッション開始時、右ペインには一覧の先頭ファイルの diff を開く。

**開始と既存セッションの継承**: 保存済みセッション (open / closed を問わない) と同一 refs 組の `:Review start` / `:Review pr` は**継承**とする — 確認後に既存セッションを load (comments と viewed を引き継ぎ、anchor 検証を通す) して UI を開く。既存を消す上書き開始はできず、まっさらにしたい場合は先に `:Review delete` (persistence-restore「1 組 1 セッション」)。別の refs 組のセッションが active な状態で開始する場合は、確認後に現セッションを save → close してから新規開始する (INV-1)。別 refs 組が active でも開始対象の同一 refs 組に保存済みセッションがある場合は継承が勝つ — close と継承は 1 回の確認に統合し (閉じて継承するかどうか)、やっぱり上書き開始の択は無い。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| diff 出力のパース (ファイル/hunk/行種別/new 側行番号写像) | core | `lua/review/core/diff.lua` (+ `_spec`) |
| git diff / ref 一覧の実行 | adapters | `lua/review/git/diff.lua`, `lua/review/git/ref.lua` |
| コメントの追加・編集・削除・行検索モデル | core | `lua/review/core/comment.lua` (+ `_spec`) |
| セッション開始・切替の調整 | handlers | `lua/review/handlers/session.lua` |
| 操作フローと float 入力 | handlers | `lua/review/handlers/comments.lua` |
| diff バッファ描画・extmark・fold | ui | `lua/review/ui/diffbuffer.lua` |
| sidebar 一覧 | ui | `lua/review/ui/list.lua` |
| マルチライン float 入力 | ui | `lua/review/ui/input.lua` |
| `o` の実ファイル参照 (worktree なし = `git show` read-only。worktree 分岐は #6。sidebar / diff とも `handlers/session.open_file_current` 経由) | ui | `lua/review/ui/fileview.lua` (+ `_spec`) |
| help float | ui | `lua/review/ui/help.lua` |
| highlight 定義 | ui | `lua/review/ui/highlight.lua` |

## エッジケースの決定

- diff 対象 0 ファイル (base と head が同一ツリー等): 開始時は「変更なし」を通知してセッションを開かない。エラーではなくレビュー対象なしの正常な結果として扱う (復元時に空になった場合は persistence-restore「差分がまるごと消滅」の規則で開く)
- 削除ファイルへのコメント: new 側 `+` 行が存在しないので行選択できず構造的に不可。ファイル削除そのものへの指摘コメントは v1 対象外
- rename (`diff --git a/x b/y` に similarity index を伴う形): 変更後の新パス 1 ファイルとしてパースし、旧パスとの対応表示はしない
- binary ファイル: hunk 本体なしのヘッダのみ (「Binary files differ」行) でコメント不可として表示する
- hunk ヘッダの行数 0 (`@@ -0,0 +0,0 @@` 相当の空ファイル新規): 行数 0 の hunk を許容し、new 側行番号を持たないものとして扱う (行番号変換ロジックは 0 行数 hunk でも範囲外行番号を生成しない)
- 入力 float の離脱経路: `<Esc>` は窓を閉じず Normal へ戻るだけ (入力を失わない)。`q` は本文が空のときのみ閉じる (キャンセル)。本文ありの `q` は閉じず WARN し、同じ本文のまま discard window (2 秒) 内にもう一度 `q` で入力を破棄して閉じる (二重押しによる誤破棄の防止。本文が変われば arming は自動的にやり直し)。`:q` 等での窓離脱は従来どおりキャンセル扱い
- visual selection が削除専用行 (new 側行番号なし) だけを含む: WARN で拒否
- 右ペインのファイル切替: 描画を捨ててセッションの状態 (files と comments) から再構成する。唯一の真実は状態側にあり、バッファ側に値を持たない

## テスト方針

- 単体 (core/diff): 実 git で生成した生出力フィクスチャ (multi-hunk / rename / binary / 新規 / 削除 / 0 行数 hunk / 前後ファイルの連なり) をパースし、各 `+`/コンテキスト行の new 側行番号が完全一致で検証する (表示位置だけ照らすテストは行番号漂移を検出できない)
- 単体 (core/comment): CRUD、id 採番 (max+1)、カーソル行検索、range 正規化 (末尾 > 先頭の修正)
- 単体 (handlers): git 注入スタブでの開始フロー、active セッション排他と切替時の save 呼び出し、CRUD 直後の save トリガ
- E2E (golden path、scripts/e2e.sh 経由): fixture repo で `:Review start main feature` → diff バッファに hunk が出る → `c` でコメント作成 (キーシーケンス投入) → extmark と virt text が出る → sidebar で別ファイルへ `<Enter>` → 閉じて再度開くとコメントが残っている (persistence-restore と同一シナリオを共有)
