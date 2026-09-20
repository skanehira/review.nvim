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
- base/head 窓オプション (窓ローカル): `diff scrollbind cursorbind foldmethod=diff foldlevel=0 foldcolumn=1 wrap=off`。行番号は `config.number` に従う。**`diffopt` は変更しない** (global option で伝播 — DESIGN「既知の制約」)。binary 注釈共有・no-changes・追加 (base = 0 行 null scratch)・削除告知の各ペアは窓 diff ペアを作らず**両窓 `diffoff`** で退避する (素の色で読める。`foldclosed()` が -1 になることで退避を検証できる)
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
| 追加ファイル | 上記経路どおり | `review://null/<session>/<path>` (0 行 scratch。base = 0 行との窓 diff は全行 DiffAdd になるため **両窓 `diffoff`**) |
| 削除ファイル | **告知 scratch** `review://deleted/<session>/<path>`。`:edit` しない (`:w` で空の新規ファイルが復活する — DESIGN「既知の制約」) | 旧内容 scratch。head = 告知 1 行 / base = 旧内容の**告知ペア**として両窓 `diffoff` |
| rename | **新パス**の実ファイル/scratch | `git show <base>:<旧パス>` (旧パス自体が新規なら `review://null/...`) |
| binary | 告知 scratch `review://binary/<session>/<path>` ×両窓共有 (`diffoff`。git パースの „Binary files differ“ を 1 行表示) | 同 buffer を共有 |

- open_file(path) = 移動系の唯一経路: head/base を上記で張り、chrome 再適用、panel 再描画、コメント extmark 再適用。open はレビュー完了マークを変えず永続状態も触らないため save しない (INV-4 の save 対象 = コメント CRUD / マーク切替 / 差分再取得)。head が実バッファのとき内容変化があれば `:diffupdate`

**コメント表示 (head バッファの extmark)**:

- 対象行 = コメントの `line`〜`end_line` の範囲 (new 側行番号 = head バッファの行番号そのもの。**行写像変換は存在しない** — head 実窓では行番号が恒等で、unified バッファ時代の変換経路 (`new_line_at`) は持たない)。namespace `review_comment` の extmark 1 個に virt_text (行末 `コメントアイコン (nf-cod-comment U+EA6B) N`、hl `ReviewPanelComment`。outdated 混在でも件数表示は変えず、outdated は行下スレッドの id 接頭辞だけ `ReviewCommentOutdated` にする) と virt_lines (行下スレッド本文 `[c1] …`、10 行で `… (i で全文)`、group 内は id 行 + continuation インデント) を併合する (同一位置に複数 extmark を作ると取得順不定で spec 契約にできない)。下線 hl `ReviewCommentLine`
- 行下スレッド本文は `ReviewCommentBody` のプレーン表示 (markdown 構文色は付けない。extmark は buffer filetype を持てず、head/base 実バッファの ft は変更しない)。outdated コメントは id 接頭辞 (`[c1]`・打ち切り行 `… (i で全文)`) のみ `ReviewCommentOutdated`、本文は `ReviewCommentBody`。全文閲覧 `i` の float buffer は filetype=markdown
- eol anchor (end_col 指定なし start col 対応) + `right_gravity=true` (boolean 指定。`gravity` 文字列は invalid) で編集時の行移動に自動追従
- **同一バッファの全窓にスレッドが見える (仕様)**。窓単位抑止 API は実測で存在しない。セッション close / delete 時に張った全バッファの ns を明示 clear し、残骸 0 を spec で pin する
- 位置を解けない outdated (= new 側に該当テキスト無し) は当該 head バッファ **1 行目の virt_lines_above** に集約: `N outdated (prompt 除外中)` (hl `ReviewCommentOutdated`) + 本文一覧。head 窓が存在しないファイル (deleted・binary 告知窓) に紐づく outdated は panel winbar の末尾要素 `⚠N` (「窓装飾 (chrome)」参照) とプロンプト除外 INFO で可視化する
- 再描画は常に session.comments から捨てて再構成 (バッファ側に真実を置かない — 現行契約)

**リフレッシュ (未コミット反映契約)**:

- head 窓で保存 (BufWritePost。同一バッファがユーザー窓から書かれたときも同じ buffer イベント) 時に自動実行: `git diff <base>` 再取得 → 再パース → **anchor 検証 (直近パース結果に対して text_map 経路 — 復元検証と同一)** → ±カウント・panel・スレッド・winbar 再適用 → `:diffupdate` → 永続化。**in-flight 中は dirty マークで 1 回まとめ** (多重 fetch しない)。失敗は WARN + 前回 parse を保持。**再取得の引数形は開始時解決と一致させる** (通常経路 = 単引数、scratch 縮退 = `<base> <head>`)。セッション close / 切替時は in-flight・dirty を無効化する (コールバックは「対象セッションがまだ active」を確認してから適用。確認できたら結果を破棄)。
- 手動 `R` = 同一経路 (drift 復旧・他プロセスでの変更取り込みにも効く)
- 未保存の buffer 編集は窓 diff にだけ映り、±カウント・prompt・anchor は保存済み内容基準 (二重基準は DESIGN 決定表「保存時再取得」の契約)
- リフレッシュ時 (branch・通常経路のみ) : `session.head` (ブランチ名解決後の ref) の commit と現在の HEAD の commit が違えば INFO «セッション開始時の head と現在のチェックアウトが違います» を 1 回だけ出す (処理は続行 — 定義上、レビュー対象は「base vs 現在のチェックアウト」)。PR/縮退は比較しない (PR は worktree を `--detach` するため HEAD 比較が恒真で誤発火する)

**操作** (既定キーの正本は DESIGN.md「デフォルトキーマップ」。buffer-local + window role gate、`silent nowait`。gate 不成立窓では 1 キーストロークが built-in になる副作用を help に明記):

- `[y/N]` 確認は `vim.ui.input` (cmdline) で行い、y / n を打って `<Enter>` で応答する。応答後に空 echo (`nvim_echo({}, false, {})`) で cmdline をクリアする (残留した打鍵が入力に混ざらない — UX review F15)。文言の正本は各呼び出し側 (prompt 文字列)

| 操作 | 起きること |
| --- | --- |
| `c` (normal / visual-line) | head 窓のカーソル / '<~'> 行番号が new 側行そのもの。削除告知・binary 注釈・base 窓では WARN (確定文言の正本は DESIGN.md キー表 «この窓にはコメントを付けられません») で開かない。コメント入力 float は契約そのまま (マルチライン scratch、Normal `<CR>` 確定 / insert `<CR>` 改行 / `q` 閉じる [本文なし=キャンセル、本文ありは続けて q で破棄 arming] / `<C-y>` 確定エイリアス / `<Esc>` は Normal 復帰のみ、stopinsert 経路、title に `path:line[-end]` 常時表示) |
| `e` / `d` / `y` / `i` | 現行契約そのまま (d は arming 二重押し、i は commentview float)。head 窓限定 |
| `<Tab>` / `<S-Tab>` / `[F` / `]F` | 次 / 前 / 最初 / 最後ファイル = open_file。端無動作、focus は head 窓に留まる |
| `<leader>e` / `<leader>b` | panel focus (閉じていれば再建) / panel 表示トグル (閉じても tab とレビュー窓は残る) |
| `R` | リフレッシュ (上記) + 窓の役割 drift の復旧 |
| `q` | `:Review close` 相当 (pr-worktree「セッションとレビューの終了」)。tab を閉じる。ユーザー窓・開いたままの実ファイルバッファ (modified を含む) は消さない |
| `<F1>` / `g?` | help float (内容は markdown。`g?` は固定の別名 = 同一呼び出し。file panel でも同じ) |
| `[c` / `]c` / fold 鍵 | マップしない — Neovim 標準 (窓 diff の hunk 移動。filetype 非依存で効く) |

**file panel** (`review://sidebar/<session>`、filetype `review-list`。キーは DESIGN 表):

- tree 表示 (既定): ヘッダ行 `Changes (N)` と `Showing changes for: <base>..<head 表示名 (作業ツリー) >`、続いてパスツリー。ディレクトリは折りたたみ可 (既定展開。collapsed は view state)、**単一 child 連鎖は連結表示** (`a/b/c/`)。**dir 行は末尾に `/` を付けファイルと同じ行フォーマット帯で識別する** (同名のファイルと dir が同時差分に出るケースの区別規則)。dir 行の status は子の集約 (全子同一記号ならそのまま、種類混在は `*` — 単独 status `M` と衝突させない)、file 行は `[✓?] <status> <コメントアイコン?> <icon?> <basename> +<a> -<d>`: コメントアイコン (nf-cod-comment U+EA6B) はコメントありファイル、`+<a>` は緑 (`ReviewPanelAdd`)・`-<d>` は赤 (`ReviewPanelRemove`)、親パス grey サフィックスは持たない (ツリー indent が文脈)。`<Tab>`/`<S-Tab>`/`[F`/`]F` はこの表示順 (ツリー上→下) を辿る。ファイルのレビュー完了マークが行頭 `[✓]`: **open/移動では決して付かず、panel の `x` でユーザーがトグルするのみ** (session の `files[path].viewed` に保存され、`p` 相当の非表示はない = 絞り込み `/` とは別系統)。**devicons は存在自動検出** (無ければアイコンなしのテキスト表示。ランタイム依存ゼロは崩さない)
- list 表示 (`i` でトグル): フルパス 1 行の現行フラット形式。filter・viewed・±・コメントアイコン は tree と同じ規約で働く (移動系はパス昇順のフラット順になる)
- 選択追従: panel のカーソル移動だけでは diff を切り替えない (diffview 動作)。`<CR>` / `o` / `l` (file 行) が open_file で、開いた後も focus とカーソルは panel に残る (diff 窓へ focus するのは移動系 `<Tab>` / `<S-Tab>` / `[F` / `]F` と標準の窓移動)。逆に open_file 時は panel カーソルを追従スクロールさせる (**選択行 hl `ReviewPanelFile`+`cursorline` 窓有効** — 相互ハイライト)
- hl group: `ReviewPanelFile` / `ReviewPanelDir` / `ReviewPanelStatus` / `ReviewPanelComment` / `ReviewPanelAdd` / `ReviewPanelRemove` (差分行の着色は窓 diff が Neovim 標準 DiffAdd/Delete を直接使う — DESIGN「命名」)
- `/` 絞り込み・`x` レビュー完了マーク切替・`R`・`q`・`<Tab>`/`<S-Tab>`/`[F`/`]F` は DESIGN 表の動作。絞り込み・collapsed・listing style は view state (session JSON に載せない)
- 表記の細部 (実装契約として固定): 同一階層は dir の subtree 先行 -> file 行、各々名前のバイト順。indent は 1 階層 2 半角 space (連結連鎖の子行のインデントは deepest 階層数に従う)。collapsed の dir 行のみ行頭に `▸` マーク (展開中はマークなし)。collapsed 集合の key は連結末尾 (= deepest) の dir path スラッシュ無し = `row_entry` の path と同一語。表示 file が 0 件のときヘッダ 2 行は出さない (従来 «0 行一覧» 契約のまま)。`Changes (N)` の N は絞り込み後の表示 file 数。devicons は `<status> <icon> <basename>` の icon と basename に色を張る: 色は検出側の返す hl group 名 (nvim-web-devicons `get_icon` の 2 返り値 = DevIcon* 群。group 定義は devicons 側の責務で、review.nvim は `nvim_set_hl` を作らず syntax engine にも一切触れない — diffview の `hl.get_file_icon` と同方式)。hl を返さない / group 未定義 / devicons 不在は無色 (ReviewPanelFile)。dir・header 行には張らない。list モードは icon 文字なしで basename 色のみ。list 表示はヘッダなし・icon なしの現行フラット形式。head 表示名 «作業ツリー» は branch/PR を問わず通常経路の既定、scratch 縮退時だけ保存 head ref 名

**セッション開始時の初期開き**: 一覧先頭ファイルの open_file (focus は head 窓)。files が空の開通 (復元時に差分がまるごと消滅) は open_file の代わりに「変更なし」プレースホルダ scratch を base/head 窓へ張り、outdated 集約もそこへ出す (persistence-restore「差分がまるごと消滅」)。

**窓装飾 (chrome)**: winbar 文字列 — head 窓 `base..<head> · path · +a -d · N comments` (追加ファイルは末尾に ` · new file`、削除は `· deleted`・binary は `· binary` に差し替え)、base 窓 `base · path (git show)` (追加ファイルは `base · path (new file)`)、panel `base..head · N files · M comments [· filter=…] [· ⚠N]` (`⚠N` = 位置を解けず集約先 (head 窓) さえない outdated — deleted/binary 告知窓のファイル — の件数、0 件なら非表示)、commentlist `base..head · N comments [· ⚠M]` (`⚠M` = 一覧に表示中の outdated 総数 — panel の `⚠N` とは別の数、0 件なら非表示)。機構: `'winbar'` は global-local option だが window-local set は global へ漏れるため (実測: `:set winbar` の初回代入が global を書き換える = 0.10/0.13 共通)、global 式 `%{get(w:,"review_winbar","")}` を使い、表示文字列は**窓変数 `w:review_winbar` のみ**に持つ (b: 変数は実ファイルバッファ経由でユーザー窓・他 tab の winbar に漏れるため使わない — 窓単位が正。ユーザーが既に winbar を設定している場合は上書きしない)。render 直後の handlers 側 `chrome.window()` 再適用 (現在 tab の窓のみ式を入れる) と `config.number` の窓単位 off は現行契約そのまま。式が非空だと空評価でも窓に 1 行の winbar 領域が確保される (実 PTY 実測: `w:review_winbar` 未設定でも `winheight` が 1 減る) ため、式は**現在の tab に `w:review_winbar` を持つ窓がある間だけ**入れる: `TabEnter` で `chrome.sync_tab` が判定し、review バーの窓が無い tab では自前式を空へ戻す (`chrome.clear_global`。窓変数は保持し、review tab へ戻ると再適用される)。これで review 外の tab に空ヘッダー行が残らない。**review セッションが閉じたとき (`q` close / review tab 消滅) は自前式が入っている場合だけ global を空へ戻す** (`chrome.restore_global`、書込/復元は scope=global の API = `:set` の window-local 波及を避ける)。`restore_global` は式と同時に各窓の `w:review_winbar` も掃除する (式の無い窓変数は無意味で、次の review で stale バーとして再表示される)。`:Review list` の一覧窓 (sessionlist) は review tab 外 (current tab の vsplit) に開くため tab 消滅経路が使えない — バッファが閉じたとき (window close / `:bw` / `:buffer` 差し替え) に review セッションが無ければ `chrome.restore_global_if_unused` (`ui/list` の BufUnload) で同じく戻し、セッション開中でも現在 tab にバーの窓が無ければ `chrome.sync_tab` で戻す。窓が一覧バッファを離れる `:buffer` 差し替えでは `BufWinLeave` でその窓の窓変数も消す (commentlist も同様)

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
| `ui/fileview.lua` | — | **削除** (`o` = 実ファイル別 tab の廃止で不要。head 窓自体が実ファイル) |

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
