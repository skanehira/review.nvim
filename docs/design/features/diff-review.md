# diff-review (ブランチ差分レビューとコメント)

- 種別: 機能設計書
- 対象 UC: なし (タスク説明から起こした。MUST 1・3)

## 何を作るか

base と head 側状態 (branch = 現在のチェックアウトの作業ツリー / PR = 自前 worktree) の diff を、Neovim 内の**専有 tabpage に file panel + base 窓 + head 窓の 3 ペイン**で開き、head 窓でカーソル / visual-line によるコメントの作成・編集・削除をする。head 窓は**実ファイルバッファ (:edit)** であり、編集可・LSP が効いたまま差分を追える。差分の表示は Neovim 標準の窓 diff、コメント表示は head バッファへの extmark。レビュー開始からコメント蓄積までの核。永続化の「書く」処理は store/ に委譲し、保存のトリガ (INV-4) までを保証する。

## 入出力と振る舞い

**開始** `:Review start <base> [head]`:

1. **`:Review start` は base 必須 (1 引数以上)**。**head 省略時は `rev-parse --abbrev-ref HEAD` (ブランチ名、detached は literal `HEAD`) を自動解決・保存** (入力 UI を出さない)。head 明示時は ref 補完 (branches → tags)。0 引数は usage 通知で受けつけない
2. **head 解決フロー** (branch のみ。DESIGN.md 決定表): `git rev-parse <head>` と `git rev-parse HEAD` が一致 → 通常経路。不一致かつ head がローカルブランチ (`show-ref --verify refs/heads/`) かつ `git status --porcelain` 空 → [y/N] で switch 提案 (承諾 → `git switch <head>`、失敗は WARN で scratch 縮退)。それ以外 (不一致+dirty / 不一致+非ローカルブランチ / 拒否) → **scratch 縮退**を INFO 明示 («head の状態はチェックアウトされていません。読み取り専用 scratch でレビューします»)
3. 差分取得: 通常経路は `git diff <base>` (**作業ツリー基準の単引数形**、cwd は branch=repo / PR=worktree)。scratch 縮退は `git diff <base> <head>`。config `diff_context` 指定時は `-U<n>`。非同期実行で、ref 解決不能は `E_REF` 通知・UI を開かない
4. パース結果からセッションを組み立て、UI を開き、save を呼ぶ (persistence-restore)
5. diff 対象 0 ファイル: «変更なし» INFO で開かない (復元時に空になった場合は persistence-restore「差分がまるごと消滅」)

**レイアウト (専有 tabpage 3 窓)**:

- `tabnew` でレビュー専有 tab を作る (ユーザーの窓・tab は触らない)。構成: **file panel (左) │ base 窓 │ head 窓** の横 3 分割。panel は `wincmd H` 寄せ・幅 `config.panel_width` (既定 35)・`winfixwidth`。**開通順序は vsplit 前に buffer を張らない現行契約の流れを踏襲**し role 導出を内容基準で行う (AGENTS/DESIGN「窓の所有」)
- **開通時 focus は head 窓** (直後の c/e が効く位置から開始する — diffview は panel focus だが、review はコメント主経路を即座に使えることを選ぶ)
- base/head 窓オプション (窓ローカル): `diff scrollbind cursorbind foldmethod=diff foldlevel=0 foldcolumn=1 wrap=off`。行番号は `config.number` に従う。**`diffopt` は変更しない** (global option で伝播 — DESIGN「既知の制約」)。binary 注釈窓・deleted 告知窓など窓 diff に参加しない窓は `diffoff` で退避 (`foldclosed()` が -1 になることで退避を検証できる)
- tab 作成時に `:tcd <repo または worktree>` (tab-local cwd)。効果の対象は LSP server プロセスの spawn cwd と相対パス解決ツール。root_dir 自体はバッファパス起点の遡上で決まる (DESIGN 決定表「LSP 連携」)
- 窓 role は id ではなく内容 + 窓変数から導く: panel = `review://sidebar/...` バッファ、base = `review://base/...`、head = `w:review_key_gate == winid` かつ表示バッファの file がセッションの期待パスと一致 (フィンガープリント照合)
- **レビュー tab の消滅経路は 2 種類**: (a) `q` / `:Review close` = セッション close (コメント 0 件でなければ確認プロンプト付きの終了手順 — pr-worktree「セッションとレビューの終了」)。 (b) ユーザーが `:tabclose` / `:tabonly` 等で直接閉じる = TabClosed フックが検知し **save (status=open 維持) + extmark clear + active 解除 + in-flight refresh 破棄**を行い、INFO «レビュー tab を閉じました (セッションは保存済み・`:Review` で開き直し可)» を出す。tab 消滅そのものを close と解釈しない (黙ってレビュー状態を変えない)。契約化された「閉じる」操作は `q` / `:Review close` のみ
- drift 復旧: head 窓でユーザーが `:edit` 等して役割が壊れてもレビュー操作は gate 不成立で WARN し誤発火しない。**`R` / `<Tab>` / `<S-Tab>` / `[F` / `]F` / panel `<CR>` (=open_file 共通処理) で diff ペアと gate を張り直す** (「実ファイル窓が壊れた」を事故ではなく正当操作として扱う)。panel 窓が閉じられたら `<leader>e` で左に再建し render

**head / base 窓の中身** (ファイル種別別の解決):

| 場合 | head 窓 | base 窓 |
| --- | --- | --- |
| 通常経路 (head == チェックアウト) | `<repo>/<path>` を `:edit` (編集可・filetype detect・LSP attach。既にユーザーが開いていれば同一バッファを再利用) | `review://base/<session>/<path>` scratch (`git show <base>:<path>`、`bufhidden=hide`、modifiable=false、filetype detect) |
| PR | `<worktree>/<path>` を `:edit` (tab は worktree に tcd 済み) | 同上 |
| scratch 縮退 | `review://head/<session>/<path>` scratch (`git show <head>:<path>`、read-only) + INFO | 同上 |
| 追加ファイル | 上記経路どおり | `review://null/<session>/<path>` (0 行 scratch、diff ペアには参加) |
| 削除ファイル | **告知 scratch** `review://deleted/<session>/<path>` + `diffoff`。`:edit` しない (`:w` で空の新規ファイルが復活する — DESIGN「既知の制約」) | 旧内容 scratch |
| rename | **新パス**の実ファイル/scratch | `git show <base>:<旧パス>` (旧パス自体が新規なら `review://null/...`) |
| binary | 告知 scratch `review://binary/<session>/<path>` ×両窓共有 (`diffoff`。git パースの „Binary files differ“ を 1 行表示) | 同 buffer を共有 |

- open_file(path) = 移動系の唯一経路: head/base を上記で張り、chrome 再適用、viewed=true、save、panel 再描画、コメント extmark 再適用。head が実バッファのとき内容変化があれば `:diffupdate`

**コメント表示 (head バッファの extmark)**:

- 対象行 = コメントの `line`〜`end_line` の範囲 (new 側行番号 = head バッファの行番号そのもの。**行写像変換は存在しない** — head 実窓では行番号が恒等で、unified バッファ時代の変換経路 (`new_line_at`) は持たない)。namespace `review_comment` の extmark 1 個に virt_text (行末 `💬 N`、outdated 混在は `💬 N (⚠M)`) と virt_lines (行下スレッド本文 `[c1] …`、10 行で `… (i で全文)`、group 内は id 行 + continuation インデント) を併合する (同一位置に複数 extmark を作ると取得順不定で spec 契約にできない)。下線 hl `ReviewCommentLine`
- eol anchor (end_col 指定なし start col 対応) + `right_gravity=true` (boolean 指定。`gravity` 文字列は invalid) で編集時の行移動に自動追従
- **同一バッファの全窓にスレッドが見える (仕様)**。窓単位抑止 API は実測で存在しない。セッション close / delete 時に張った全バッファの ns を明示 clear し、残骸 0 を spec で pin する
- 位置を解けない outdated (= new 側に該当テキスト無し) は当該 head バッファ **1 行目の virt_lines_above** に集約: `⚠ N outdated (prompt 除外中)` + 本文一覧。head 窓が存在しないファイル (deleted・binary 告知窓) に紐づく outdated は panel winbar の末尾要素 `⚠N` (「窓装飾 (chrome)」参照) とプロンプト除外 INFO で可視化する
- 再描画は常に session.comments から捨てて再構成 (バッファ側に真実を置かない — 現行契約)

**リフレッシュ (未コミット反映契約)**:

- head 窓で保存 (BufWritePost。同一バッファがユーザー窓から書かれたときも同じ buffer イベント) 時に自動実行: `git diff <base>` 再取得 → 再パース → **anchor 検証 (直近パース結果に対して text_map 経路 — 復元検証と同一)** → ±カウント・panel・スレッド・winbar 再適用 → `:diffupdate` → 永続化。**in-flight 中は dirty マークで 1 回まとめ** (多重 fetch しない)。失敗は WARN + 前回 parse を保持。**再取得の引数形は開始時解決と一致させる** (通常経路 = 単引数、scratch 縮退 = `<base> <head>`)。セッション close / 切替時は in-flight・dirty を無効化する (コールバックは「対象セッションがまだ active」を確認してから適用。確認できたら結果を破棄)。
- 手動 `R` = 同一経路 (drift 復旧・他プロセスでの変更取り込みにも効く)
- 未保存の buffer 編集は窓 diff にだけ映り、±カウント・prompt・anchor は保存済み内容基準 (二重基準は DESIGN 決定表「保存時再取得」の契約)
- リフレッシュ時 (branch・通常経路のみ) : `session.head` (ブランチ名解決後の ref) の commit と現在の HEAD の commit が違えば INFO «セッション開始時の head と現在のチェックアウトが違います» を 1 回だけ出す (処理は続行 — 定義上、レビュー対象は「base vs 現在のチェックアウト」)。PR/縮退は比較しない (PR は worktree を `--detach` するため HEAD 比較が恒真で誤発火する)

**操作** (既定キーの正本は DESIGN.md「デフォルトキーマップ」。buffer-local + window role gate、`silent nowait`。gate 不成立窓では 1 キーストロークが built-in になる副作用を help に明記):

| 操作 | 起きること |
| --- | --- |
| `c` (normal / visual-line) | head 窓のカーソル / '<~'> 行番号が new 側行そのもの。削除告知・binary 注釈・base 窓では WARN (確定文言の正本は DESIGN.md キー表 «この窓にはコメントを付けられません») で開かない。コメント入力 float は契約そのまま (マルチライン scratch、Normal `<CR>` 確定 / insert `<CR>` 改行 / `q` 閉じる [本文なし=キャンセル、本文ありは続けて q で破棄 arming] / `<C-y>` 確定エイリアス / `<Esc>` は Normal 復帰のみ、stopinsert 経路、title に `path:line[-end]` 常時表示) |
| `e` / `d` / `y` / `i` | 現行契約そのまま (d は arming 二重押し、i は commentview float)。head 窓限定 |
| `<Tab>` / `<S-Tab>` / `[F` / `]F` | 次 / 前 / 最初 / 最後ファイル = open_file。端無動作、focus は head 窓に留まる |
| `<leader>e` / `<leader>b` | panel focus (閉じていれば再建) / panel 表示トグル (閉じても tab とレビュー窓は残る) |
| `R` | リフレッシュ (上記) + 窓の役割 drift の復旧 |
| `o` | そのファイルの実ファイルを**レビュー tab の外** (前行儀の tab) で開く — diff ペアを壊さず通常編集文脈へ出る。scratch 縮退時は「現在のチェックアウトの実ファイル」である旨を INFO 添えて開く (存在しなければ git show read-only scratch fallback)。削除ファイルは WARN |
| `q` | `:Review close` 相当 (pr-worktree「セッションとレビューの終了」)。tab を閉じる。ユーザー窓・開いたままの実ファイルバッファ (modified を含む) は消さない |
| `<F1>` | help float (現行のまま) |
| `[c` / `]c` / fold 鍵 | マップしない — Neovim 標準 (窓 diff の hunk 移動。filetype 非依存で効く) |

**file panel** (`review://sidebar/<session>`、filetype `review-list`。キーは DESIGN 表):

- tree 表示 (既定): ヘッダ行 `Changes (N)` と `Showing changes for: <base>..<head 表示名 (作業ツリー) >`、続いてパスツリー。ディレクトリは折りたたみ可 (既定展開。collapsed は view state)、**単一 child 連鎖は連結表示** (`a/b/c/`)。**dir 行は末尾に `/` を付けファイルと同じ行フォーマット帯で識別する** (同名のファイルと dir が同時差分に出るケースの区別規則)。dir 行の status は子の集約 (全子同一記号ならそのまま、種類混在は `*` — 単独 status `M` と衝突させない)、file 行は `<status> <icon?> <basename> +<a> -<d>` + 親パス grey サフィックス。viewed  ファイルは行頭 `[✓]`。**devicons は存在自動検出** (無ければアイコンなしのテキスト表示。ランタイム依存ゼロは崩さない)
- list 表示 (`i` でトグル): フルパス 1 行の現行フラット形式。filter・viewed は tree と同じ集合で働く
- 選択追従: panel のカーソル移動だけでは diff を切り替えない (diffview 動作)。`<CR>` / `o` / `l` が open_file。逆に open_file 時は panel カーソルを追従スクロールさせる (**選択行 hl `ReviewPanelFile`+`cursorline` 窓有効** — 相互ハイライト)
- hl group: `ReviewPanelFile` / `ReviewPanelDir` / `ReviewPanelStatus` / `ReviewPanelMeta` (差分行の着色は窓 diff が Neovim 標準 Diff* を直接使う — DESIGN「命名」)
- `/` 絞り込み・`x` viewed・`R`・`q`・`<Tab>`/`<S-Tab>`/`[F`/`]F` は DESIGN 表の動作。絞り込み・collapsed・listing style は view state (session JSON に載せない)

**セッション開始時の初期開き**: 一覧先頭ファイルの open_file (focus は head 窓)。files が空の開通 (復元時に差分がまるごと消滅) は open_file の代わりに「変更なし」プレースホルダ scratch を base/head 窓へ張り、outdated 集約もそこへ出す (persistence-restore「差分がまるごと消滅」)。

**窓装飾 (chrome)**: winbar 文字列 — head 窓 `base..<head> · path · +a -d · N comments`、base 窓 `base · path (git show)`、panel `base..head · N files · M comments [· filter=…] [· ⚠N]` (`⚠N` = 位置を解けず集約先 (head 窓) さえない outdated — deleted/binary 告知窓のファイル — の件数、0 件なら非表示)。機構: `'winbar'` は global-only option なので global 式 `%{get(w:,"review_winbar","")}` を 1 度だけ入れ、表示文字列は**窓変数 `w:review_winbar` のみ**に持つ (b: 変数は実ファイルバッファ経由でユーザー窓・他 tab の winbar に漏れるため使わない — 窓単位が正。ユーザーが既に winbar を設定している場合は上書きしない)。render 直後の handlers 側 `chrome.window()` 再適用と `config.number` の窓単位 off は現行契約そのまま

**開始と既存セッションの継承**: 現行契約そのまま (同一 refs 組は継承 / 別 refs 組は save→close / 上書き開始なし — INV-1)。復元・開き直しも head 解決フローを毎回再評価する (session JSON の mode/base/head は変わらない)。

## 実装の配置

| 処理 | 層 | 実装先ファイル |
| --- | --- | --- |
| diff 出力パース (ファイル一覧・±数・new 側行番号・anchor 検証の text_map 源) | core | `lua/review/core/diff.lua` (+ `_spec`) — 単引数形でも動く (既存パーサ踏襲) |
| git diff 実行 (単引数 + cwd) | adapters | `lua/review/git/diff.lua` (引数組み立て改訂) |
| rev-parse / show-ref / switch | adapters | `lua/review/git/ref.lua` (拡張)、`lua/review/git/repo.lua` (switch、新規 + `_spec`) |
| 開始・head 解決 (switch 提案/scratch 縮退)・レイアウト・open_file・リフレッシュ調停・close | handlers | `lua/review/handlers/session.lua` |
| 操作フローと float 入力 | handlers | `lua/review/handlers/comments.lua` (行取得が恒等になっても API 形は維持 — scratch 縮退窓と共通) |
| 3 窓レイアウト・role 導出・drift 復旧・tcd・tab 開閉 | ui | `lua/review/ui/windows.lua` (新規 + `_spec`) |
| window role gate + buffer-local キー install/uninstall (衝突検出スキップ含む) | ui | `lua/review/ui/keygate.lua` (新規 + `_spec`) |
| base / head / null / deleted / binary 窓の中身 (git show 充填・filetype detect) | ui | `lua/review/ui/scratchwin.lua` (新規) |
| コメント extmark 再適用・ns クリーンアップ収集 | ui | `lua/review/ui/commentmarks.lua` (新規 — 現行 diffbuffer のスレッド部を移す) |
| file panel 描画・相互追従 | ui | `lua/review/ui/filepanel.lua` (新規 + `_spec`) |
| ツリーモデル (純ロジック: path→node、連結、集約、fold 集合) | ui (純) | `lua/review/ui/treelist.lua` (新規 + `_spec`) |
| 現行 `ui/diffbuffer.lua` | — | **削除** (unified 描画の撤廃。fold/virt_text 経験は commentmarks へ) |
| セッション一覧 (変更なし) | ui | `lua/review/ui/list.lua` (sidebar 分を filepanel へ移し sessionlist のみ) |
| 現行 `ui/fileview.lua` | — | 縮小 (`o` の前行儀 tab open + 削除ファイル git show fallback) |

## エッジケースの決定

- 未追跡ファイル: `git diff` 出力に出ないためレビュー対象にならない (`git add` 前の新ファイルは不可。DESIGN「既知の制約」)
- 削除ファイル・binary: head 窓が告知 scratch のファイルにはコメント不可 (WARN)。削除そのものへの指摘コメントは v1 対象外 (現行決定)
- rename: 新パス 1 ファイルとして扱い、旧パスとの対応表示はしない。base 窓だけ旧パスの中身 (`git show` で解決不能 = 旧パス自体が新規の場合は `review://null/<session>/<path>`)
- hunk 行数 0 (`@@ -0,0 +0,0 @@` 相当): パース側契約そのまま (新側行番号を持たない)。窓 diff 表示には影響しない
- scratch 縮退 + 別プロセス checkout 変更: LSP が attach しない・diff が開いた時点固定 — INFO 済みなので仕様
- ユーザーがレビュー中に裏で switch/checkout: 次のリフレッシュ時に現在チェックアウト内容がレビュー対象になる (定義)。head 解決の commit 比較で不一致を検出し INFO 1 回 (定義は「リフレッシュ」節が正本)
- 0 行数 hunk・差分消滅・入力 float 離脱経路・visual 選択が new 側行なし・arming 解除条件: 現行契約の趣旨そのまま (行写像が恒等になっても「new 側に存在しない行への c は不可 — WARN」は成立。存在行範囲のみ作成可)
- 開通順序競合 (vsplit 継承 drift) と空窓回収: 専有 tab のためユーザー窓誤回収の心配は消えるが、tab 内に作らなかったはずの窓 (float 破片・error 窓) が残ったら閉じる回収は続ける

## テスト方針

- 単体 (core/diff):生出力フィクスチャパースは現行維持。単引数 `git diff <base>` 出力形状での回帰を追加
- 単体 (git リポジトリ実 FS): `git/repo.lua` switch 成功/失敗、`git/diff.lua` cwd 指定 (worktree) の引数組み立て (`_set_system` 応答キューで呼び出し順 pin)
- 単体 (handlers/session): head 解決フローの全分岐 (一致 / 不一致+clean+branch+承諾 / 拒否 / dirty / 非ブランチ — `ui.input` スタブ + rev-parse キュー)、open_file の種別別張り分け (実バッファ / scratch / null / deleted)、リフレッシュ in-flight まとめ・失敗保持・save 契約 (INV-4)、drift 復旧経路 (window role 再導出)、close の tab 消滅 + extmark 残骸 0 (`tabpage が消え、張った buf の get_extmarks が空`)
- 単体 (ui): windows.lua (panel│base│head 配置・tcd・winfixwidth)、keygate (衝突検出スキップ・install/uninstall 残骸・gate 発火/不発火マトリクス)、treelist (連結・集約・fold 集合・list/tree 切替の純関数)、filepanel (viewed/表示行・選択追従 scroll)
- E2E (golden path): temp repo `main`/`feature` で `:Review start main` → 専有 tab 3 窓・head 窓 buf 実パス==repo 内・窓 opts・**tcd==repo** → head 窓 `c` でコメント (打鍵は `:normal`) → 実ファイルの extmark・panel 行・winbar 件数 assert → 編集 `:w` → ±カウント増(panel) とリフレッシュ assert → `<Tab>` 次ファイル → 閉じて (q) tab 消滅・ns 残骸 0 → 再起動 `:Review` 復元→コメント位置同一。縮退シナリオ (`:Review start main other` + n スタブ) は両窓 scratch assert。switch シナリオ (y) は switch 後 repo の content==head であること。PR シナリオは worktree + tcd==worktree + `o` が worktree 基準パス
- 実 PTY 契約 (tmux + `--remote-expr`、手順を commit message): 同一ファイルの 2 窓 (review 窓 + ユーザー窓) でキーが review 窓のみ発火・ユーザー窓 built-in、insert-mode 残留 (F8)、fold 時のスレッド非表示の画面確認
