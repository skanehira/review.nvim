# FEASIBILITY — diffview.nvim 風 UI 改訂の技術検証

- 種別: 実現可能性検証 / PoC 計画
- 対象: レビュー画面の 2 窓 diff 化 + 実ファイル head 窓 + file panel ツリー化 + キー置換
  (features/diff-review.md / pr-worktree.md 改訂の前提技術要素)
- 検証方法: 全件 `tech-investigation` subagent による最小 PoC 実行 (headless nvim、実 git、
  実 LSP)。自己申告不可。環境実測 (2026-09-12): ローカル nvim 0.13.0-nightly+5209695、
  lua-language-server / gopls 在、CI matrix 下限 nvim v0.10.0

## 技術リスク一覧と評価

| # | 不確実性 | 分類 | 影響度 | blocker |
| --- | --- | --- | --- | --- |
| P1 | window-local keymap API が (実測で) 存在しない中、buffer-local + rhs 窓 role gate が head 実ファイル窓で漏れなく分離しユーザーマップを壊さずに成立するか | 技術的実現性 | 重大 (キー設計の生命線、0 窓漏れ + ユーザー実バッファへの副作用範囲が UX 契約) | true |
| P2 | scratch バッファ + 実ファイルの異種ペアで窓 diff が成立するか | 技術的実現性 | 致命的 (2 窓化そのもの) | true |
| P3 | LSP attach 済み実バッファの virt_lines コメントスレッド共存 | 統合 | 重大 (コメント可視の主経路) | true |
| P4 | tab-local `tcd` で LSP root_dir が worktree を向くか | 統合 | 重大 (本改訂の主要目的「LSP が効く」) | true |
| P5 | 巨大ファイル × `foldmethod=diff` の計算性能 | パフォーマンス | 中程度 (fallback 余地あり) | false |

> **P1 の前提実測 (2026-09-12、nvim 0.13.0-nightly+5209695)**: `vim.api` の keymap 系関数は
> `nvim_set_keymap` / `nvim_get_keymap` / `nvim_del_keymap` / `nvim_buf_set_keymap` /
> `nvim_buf_get_keymap` / `nvim_buf_del_keymap` の 6 本のみで `nvim_win_set_keymap` は
> **不在** (`runtime/doc/api.txt`・`deprecated.txt` にも当該 API の記録なし)。API 面は
> 版を重ねても増える側なので v0.10.0 でも不在 (PoC 側で v0.10.0 バイナリの関数一覧で再確認)。
> よって P1 は「API 実在」の検証ではなく、**代替機構 (buffer-local + 窓 role gate) が
> primary 案に昇格したものの信頼性** を検証する計画として再構成した。

## PoC 外で解消する設計帰結 (features 改訂に反映する決定事項)

- **branch モードの head 意味論**: head 実ファイル窓 = 作業ツリー (現在のチェックアウト。
  worktree を作らず未コミット変更もレビュー対象に含める) なので、窓 diff の head 側は
  実バッファの現在内容と自動的に一致し、anchor の new 側行番号と実バッファ行の対応は
  自明になる。ただし file panel の `+a -d` 統計・hunk 集合・prompt の `file:line` が従来通り
  `git diff <base> <head>` (commit 間) から出ると、未コミット編集のある実バッファと
  ズレる。レビュー対象を **base vs 作業ツリー** (`git diff <base>`) に確定すること
  (git 2.x 実測: 出力 shape は `diff --git` 行・`index <ref blob>..<wt blob>` 行・`@@`
  ヘッダとも commit 間 diff と同型で、既存 core パーサの抽出規則で扱える。未追跡ファイルは
  `git diff <ref> --` に出ないので新規ファイルの扱いを features 改訂で決定)。
  design 側の判断事項であり、本 docs 上で未決として保持しないもの)
- **extmark / virt_lines はバッファ全体装飾** (窓単位の抑止 API なし)。ユーザーが自分の
  窓で同一実ファイルを開くとコメントスレッドが**そこにも表示される**。P3 で可視性を
  実測記録し、「表示を許容」か「行頭マーカーのみ縮退 (P3 の失敗分岐)」かを features
  改訂で決める
- **`diffopt` は global option** (`'diff'` 自体は window-local。0.13 options.txt 実測:
  `'diffopt'` に global 表記、新窓へ伝播する)。レビュー側の diff 計算調整で `diffopt` を
  変えるとユーザーの diff 窓に波及する。「既定値のまま触らない / 終了時復元」の設計判断の
  ため、P2 で伝播と差分結果への影響を実測に加える

## PoC: head 実ファイル窓のキー (buffer-local + 窓 role gate)

**id**: head-window-key-gate
**目的**: window-local keymap の API が存在しない (上の実測) 前提で、機構代替 **buffer-local
keymap + rhs 内 window role gate** が head 実ファイル (ユーザーの通常バッファ) 窓の
キーマップ契約を満たすか: (i) レビュー窓のみで発火し、同一バッファの他窓では不発火
(ii) gate 不成立時のユーザー既存マップの挙動 (保存 or 呑み込み) が把握できること
(iii) 窓差し替え drift (押下時点の内容照合) で誤発火しないこと (iv) close 時の buffer-local
マップ解除が完全で残骸 0。v0.10.0 バイナリでも同手順を再実行し API 挙動差が無いこと
**risk**: high
**blocker**: true

**スコープ**:
- 含む: mode (`n`/`v`/`i`) ごとの gate 分離、判定因子 (`w:` local var + win_id 妥当性 +
  **押下時点のバッファ内容照合** — `:buffer` で id が生きたままで中身が差し替わる
  drift があるため、現行の「窓の役割は内容から導く」規律と同一)、ユーザー buffer-local
  マップが同キーに存在する場合の衝突マトリクス、ユーザー global マップの gate 不成立側
  挙動 (expr 返値 / feedkeys のどちらでマップ階層の下層へ返せるか。**expr マップは自己再発火しない**
  ため buffer-local ゲートマップの返値がユーザー global マップへ到達するかは実測で確定する)、
  `nvim_buf_del_keymap` による完全解除、v0.10.0 バイナリでの関数一覧と全手順の再実行
- 含まない: review.nvim 本体 wiring、Neovim 本体のマップ実装品質

**実装内容**:
1. GitHub release から nvim v0.10.0 macOS arm64 tarball を /tmp に展開。v0.10.0 と現行
   ローカル nvim の両方で `--clean` 起動し、keymap 系 API 関数一覧を書き出す
   (`nvim_win_set_keymap` 不在の再確認を pcall 失敗ログで記録)
2. temp repo の実ファイルを `:edit` し、`c` にユーザー global マップ (マーカー関数 G を
   記録) を用意した状態から開始 (ユーザー buffer-local マップの衝突系はステップ 6 で扱う)
3. 同一バッファを 3 窓 (`vsplit`) 表示: A / B をレビュー窓役 (`w:review_key_gate = winid`
   を設定 — レビュー窓が複数開く契約はないが、2 窓目での挙動も記録する)、C をユーザー窓役
   (var なし)。`nvim_buf_set_keymap` でこのバッファに buffer-local の expr ゲートマップ
   `c` を設定 (ゲート = `w:` var 当該窓 + `win_id2tabwin` で生存確認 + 押下時点のバッファ
   内容照合 → 成立でマーカー M 発火 / 不成立で expr 返値による下層返しの挙動を記録)
4. `nvim_win_call` + `:normal c` で A / B / C 各窓から `c` を押下。A/B で M 発火、C で
   **M 不発火** かつユーザー global の G が再現するか (または 1 keystroke 消費で終わる
   かを記録)。`v`/`i` でも同じ照合を行う (v では選択が壊れないこと)
5. drift 保護: A 窓で `:bnext` (中身が違うバッファへ差し替え) → マーカー不発火
6. 衝突マトリクス: ユーザーの buffer-local `c` / 同 `c` なしの両パターンで 3-5 を再実行
7. review 窓役を閉じた後 `nvim_buf_del_keymap` → `nvim_buf_get_keymap(0,'n')` にゲート
   マップの残骸 0、ユーザーの `c` (global/buffer-local) が元通りに発火

**必要なリソース**: nvim v0.10.0 tarball (GitHub release)、git (temp repo)、ローカル nvim

**成功基準**:
- 定量: 両バージョンで、全ステップのアサーション (A/B のみ M 発火 / C は M 0 件 / drift 時
  0 件 / 解除後残骸 0 / ユーザーマップ復旧) が 0 誤差。API pcall エラー 0
- 定性: gate 不成立 (C 窓) 時にユーザーの `c` が再現したか否かの**両方の結果が保存**
  (再現しない場合は「review 窓外で押すとユーザーの `c` が 1 回無効化される」旨が help と
  config 既定で説明可能な仕様になるかの判断材料)

**判断**:
- 成功 → head 実ファイル窓のキーは buffer-local + 窓 role gate で実装。衝突マトリクスは
  DESIGN.md「既知の制約」と doc/review.txt へ記載
- 失敗 → 失敗した因子 (分離 / drift / 解除残骸) を明示し、head 実ファイル窓には review
  キーを置かない設計へ縮小 (操作面は file panel と comment 入力 float に集約し、head 窓は
  移動・編集専用の素の窓にする)。「gate 不成立時のユーザーマップ呑み込み」だけの問題なら
  設計で許容可否を判断 (キーをユーザーとかぶらない `<Leader>` 併用等へ変更)

**POC_NEEDED マーカー**:
```
<!-- POC_NEEDED: id=head-window-key-gate, scope=window-local keymap API 不在の実測を前提に、buffer-local + 窓 role gate がユーザー実ファイル窓で漏れ・drift・残骸なく成立するか, risk=high, blocker=true -->
```

<!-- POC_STATUS: id=head-window-key-gate, blocker=true, status=verified, confidence=0.85 -->

## PoC: scratch + real buffer の窓 diff ペア

**id**: scratch-real-window-diff-pair
**目的**: `buftype=nofile` scratch (base 側、`git show` 内容) と `:edit` 実ファイル (head 側) の隣接 2 窓で、`diff` / `scrollbind` / `foldmethod=diff` の窓 diff が成立し、null・同一内容・binary の端ケースで安全に振る舞うか
**risk**: high
**blocker**: true

**スコープ**:
- 含む: 異種ペア (nofile+real) の窓 diff 計算・fold・`[c`/`]c` 移動・scrollbind 同期、片側 0 行 null バッファ、内容完全一致ペア、base 側だけ存在 (削除ファイル相当)、binary 内容 (base scratch = `git show` 生出力 × head 実 binary ファイル)、foldmethod=diff と既にバッファへ付いた extmark (gitsigns 系の sign/virt_column を模擬)・syntax highlight の非干渉、global `diffopt` 変更時の窓 diff 結果と他窓 (ユーザー窓) への伝播の実測記録
- 含まない: review.nvim の UI 描画、LSP (P3 が担う)、性能 (P5 が担う)

**実装内容**:
1. temp git repo を用意 (`git init` → base commit → 変更 commit)、`main` 作業ツリーを head 内容に
2. 左窓: scratch nofile buffer へ `git show main~1:file` 内容を set、右窓: 実ファイルを `:edit`
3. 両窓に `set diff` + `set scrollbind` + `foldmethod=diff` + `foldlevel=0` + `foldcolumn=1`
4. 検証: (a) 変更行が diff ハイライトされ同一領域が fold される (b) 編集操作 (`:diffget`/`dp`) は行わず移動のみ: `[c`/`]c` で hunk 間ジャンプ (c) 片側スクロールで対側が追従 — `getwininfo()` の topline 差分で測定
5. 端ケース: (d) 左 0 行 (追加ファイル相当) (e) 双方同一内容 (差分 0) (f) base 側だけ存在 (削除ファイル相当 — 実経路で存在しないパスを `:edit` すると「空の新規バッファ」になり `:w` でファイル復活の危険があるため、右は告知用の空 scratch とする設計前提で検証する) (g) binary (生出力の scratch と実 binary のペアでエラー・ハングしないこと。設計上 binary は注釈窓表示にすることも前提、その代替表示でも窓 diff に参加させない場合の `diffoff` 挙動を併記)
6. `diffopt` 伝播: ユーザー自身が開始した diff を模擬した diff 窓ペア (同一ファイル構成) を
   別 tab に用意し、レビュー窓側で `diffopt` を既定から変更 (例 `iwhite`) したとき伝播先で
   diff 結果が変わることを実測、設計判断 (既定のまま / 終了時復元) の材料として results に記録
7. 全ケース headless で `foldclosed()` / `foldclosedend()` (fold 範囲) と `diff_hlID()` (色成否 — extmark ではなく) でアサーションし、ケース別の期待値表 (fold 数 / hlID 出所行 / topline 同期差) を results ファイルへ書き出す

**必要なリソース**: git、ローカル nvim + v0.10.0 tarball (P1 と共用)、temp dir

**成功基準**:
- 定量: ケース a-g (diffopt 伝播の期待値は「変更が他窓に伝播する/しない」の実測どおり) を含め、アサーションが results 期待値表と全一致。nvim のエラー出力 0
- 定性: scratch と実バッファの異種構成で nvim がエラーを出さず窓 diff を計算する

**判断**:
- 成功 → 窓 diff モードで実装 (diffview と同方式)
- 失敗 → 代替: head 実バッファ側へ自前 extmark 色分け + hunk マーカー (同期は scrollbind のみ残す)。fold は `foldmethod=expr` 自作にフォールバック

**POC_NEEDED マーカー**:
```
<!-- POC_NEEDED: id=scratch-real-window-diff-pair, scope=scratch+実ファイル隣接窓の Neovim 窓 diff が端ケース (null/同一/削除/binary/diffopt 伝播) 含め成立するか, risk=high, blocker=true -->
```

<!-- POC_STATUS: id=scratch-real-window-diff-pair, blocker=true, status=verified, confidence=0.85 -->

## PoC: LSP バッファへの virt_lines コメントスレッド

**id**: lsp-buf-virt-lines-threads
**目的**: lua-language-server が attach した実ファイルバッファへ、コメントスレッド (extmark 1 個に virt_text + virt_lines 併合) を張っても LSP の virtual text / diagnostics / syntax と衝突せず、fold 時に非表示になり、編集で anchor 行が移動しても追従するか
**risk**: high
**blocker**: true

**スコープ**:
- 含む: lua-language-server 起動 (diagnostics 出るところ)、同一行への LSP virtual text と eol virt_text の共存、コメント行が fold された時 virt_lines ごと消えること、extmark の gravity 設定で編集時 anchor が行頭/行末どちらへ寄るか、`nvim_buf_del_extmark` / namespace clear での完全残骸なし、**同一実バッファを第 2 窓 (ユーザー窓の模擬) で開いたときにコメントスレッドがそちらにも表示されるか** (extmark に窓単位の抑止はない前提で、可視性の実測記録を設計判断材料として残す)
- 含まない: review.nvim のコメント CRUD、窓 diff との同時表示 (P2 後実装での確認)

**実装内容**:
1. lua-language-server がある temp repo で `vim.lsp.start` を最小設定、診断が出る .lua ファイルを `:edit` (attach 確認)
2. 特定行へ namespace 分離した extmark: virt_text (マーカー)+ virt_lines (本文 2 行) を併合設定
3. 検証: (a) LSP 診断 virtual text と同じ行で両方が表示される (`nvim_buf_get_extmarks` で両 namespace を取得) (b) その行を fold すると本文 virt_lines が画面に出ない — `nvim_buf_get_lines` では virt_lines は取得不能なため、fold 範囲 (`foldclosed()` / `foldclosedend()`。`getfoldpos` という関数は存在しない — 0.13 実測 exists()=0) と extmark 行番号の突合、または tmux 実 PTY での画面ダンプで測定する (c) 1 行挿入 → 後続コメント anchor の行番号移動を観測 (gravity 設定の示唆を得る) (d) namespace clear 後に extmark 残骸 0 (e) fold されていない行の mark を第 2 窓 (同一バッファ `:split`) で見たとき virt_lines が描画されるか — win 内容 dump と tmux ダンプの両方で記録
4. 結果 JSON と画面テキスト (win 内容 dump) を保存

**必要なリソース**: lua-language-server (在)、nvim、temp repo

**成功基準**:
- 定量: 基準 a-d すべて合格。特に (d) clear 後 `nvim_buf_get_extmarks(<buf>, <ns_id>, 0, -1, {})` が空 (引数順は buffer, ns, start, end, opts。ns=-1 は全 namespace 取得になるため ns_id を明示する位置に置くこと。元の記載 `(0, -1, -1, ns_id, {})` は引数順誤り)。e は PASS/FAIL ではなく観測記録
- 定性: LSP 機能 (diagnostic 表示・hover 動作) とコメント表示の相互破壊が見えない

**判断**:
- 成功 → 実バッファへ extmark スレッド現行方式を移植。第 2 窓での可視結果 (e) を「ユーザーの編集窓にもスレッドが見える帰結」として features 改訂に反映 (許容 or 縮退の決定)
- 失敗 → 行頭マーカー (virt_text のみ) に縮退し、本文一覧は panel 行 or `i` float に集約 (設計変更を features に反映)

**POC_NEEDED マーカー**:
```
<!-- POC_NEEDED: id=lsp-buf-virt-lines-threads, scope=LSP attach 済み実バッファでの virt_lines スレッド共存と fold 非表示・編集追従・第 2 窓可視性, risk=high, blocker=true -->
```

<!-- POC_STATUS: id=lsp-buf-virt-lines-threads, blocker=true, status=verified, confidence=0.90 -->

## PoC: tab-local tcd による LSP root_dir

**id**: tab-local-cwd-lsp-root
**目的**: review tab で `:tcd <worktree>` した状態から worktree 内ファイルを `:edit` したとき、LSP (lua_ls / gopls) の root_dir・workspace folder が **worktree** を向き、本体 repo でも $HOME でもないこと
**risk**: high
**blocker**: true

**スコープ**:
- 含む: root_dir 解決の**由来の特定** — バッファのファイルパスから親へ遡って root marker を探す解決 (vim.fs.root / root_pattern 系の既定挙動) と、起動時 cwd (tcd の効く場所) を参照する解決のどちらか/tcd が決定的な変数か。明示 `cmd` + init logs で server に渡された workspace folder を観測、tcd なし統制との比較、**worktree の `.git` はディレクトリではなく gitdir: pointers ファイル**であるため root marker 判定がこの file(.git) を踏むか (lua_ls は .gitignore / gopls は go.mod で足りる前提、marker が `.git` みの設定の挙動も 1 パターン記録)、プラグインサポート下限 v0.10.0 相当の解決経路 (`vim.lsp.config` は 0.11+ なので v0.10.0 tarball では `vim.lsp.start` + `root_dir = function(path)` の markers 遡上コールバックで再現確認)
- 含まない: LSP サーバー側の機能品質、全 LSP クライアント設定

**実装内容**:
1. temp repo + `git worktree add <tmp-wt> -b feat` (worktree 側にも root marker — lua を含むため `.gitignore` を commit しておく。`ls -a` で worktree の `.git` が file であることを確認し results に記録) を作成
2. メイン repo 窓から別 tab で `:cd 本体 repo` を保ったまま、レビュー用 tab を開き `:tcd <tmp-wt>` → tab 内で worktree の .lua ファイルを `:edit`
3. `vim.lsp.config` / `vim.lsp.enable` (ローカル 0.13) で lua_ls 起動、`vim.lsp.get_clients()` の workspace_folders / root_dir をファイルへ書く
4. 同手順を gopls (go.mod marker) でも繰り返し、比較表として results に記録
5. 制御: tcd を忘れた場合 (ファイルパス起点の marker 遡上だけ) の結果も記録 (fallback 発動時の挙動予測データ)
6. v0.10.0 tarball (P1 と共用) でステップ 2-5 を `vim.lsp.start({ ..., root_dir = function(fname) <markers 遡上> end })` 形式で再実行し、0.13 と root 解決結果が一致するか比較

**必要なリソース**: lua-language-server、gopls (ともに在)、git worktree、temp dir、nvim v0.10.0 tarball (P1 と共用)

**成功基準**:
- 定量: lua_ls / gopls とも、tcd 時・tcd なし・v0.10.0 手動 start の 3 パターンすべてで root_dir / workspace_folders を構成する各 folder path が **worktree 完全一致** (本体 repo でも $HOME でもない)
- 定性: 解決の由来が説明できる (パス起点遡上で足りる / tcd が決定的 / サーバー側の git 検出依存)。tcd の設計上の必須性が結論づけられていること

**判断**:
- 成功 → tab 作成時に `:tcd` する設計で確定
- 失敗 → fallback: review tab で開く実ファイルの LSP を明示 start (cwd=worktree 強制 / workspaceFolders 注入)。tcd は UX 補助として維持

**POC_NEEDED マーカー**:
```
<!-- POC_NEEDED: id=tab-local-cwd-lsp-root, scope=tab-local tcd worktree で lua_ls/gopls の root_dir が worktree に解決されるか, risk=high, blocker=true -->
```

<!-- POC_STATUS: id=tab-local-cwd-lsp-root, blocker=true, status=verified, confidence=0.85 -->

## PoC: 巨大ファイル × 窓 diff の性能

**id**: huge-file-window-diff-perf
**目的**: 5 万行級ファイル 2 バッファの窓 diff (`foldmethod=diff`) で、初回計算と BufWritePost 保存時再計算が実用域か。超える場合 fallback (`diffopt` 軽量化 / `:diffupdate` の間引きスロットリング / hunk 窓への限定) の目算
**risk**: medium
**blocker**: false

**スコープ**:
- 含む: 2,000 / 20,000 / 50,000 行 × 変更 hunk 数 1 / 50 合成、初回 diff 計算完了時間 (オプション適用 〜 fold 反映)、保存 (:w) 〜再計算、scrollbind 同期の追従遅延 (キー連打での応答計測)
- 含まない: git 操作性能 (`git diff` 自体は計測済みと想定、repo 全体 diff は対象外)、他 OS

**実装内容**:
1. temp repo に合成ファイルでコミットを構築 (サイズ×hunk 数の 6 パターン)
2. scratch+実ファイル窓 diff (上記 P2 構成) を開く。計測定義を固定する: 両窓 `set diff` + `:diffupdate` 強制発動から `foldclosed()` の返り値が期待値に収束するまで (`vim.wait` で 5ms 間隔 poll) を `vim.fn.reltime()` で計り、3 回中位数。窓 diff の内部計算は非同期完了のため、poll 検出を確定的な終了条件とする
3. head 側へ 1 行編集 → 保存 (`:w`) → `foldclosed()` の結果が編集後の期待値へ収束するまでを同手順で計測 (3 回中位数)
4. 数値表を results に保存。閾値超過パターンでは `diffopt` 変更・`diff=off` + `foldmethod=manual`、`:diffupdate` 間引き案の比較計測 (実装 agent 判断でよいが候補数値を必ず記録)

**必要なリソース**: temp repo、nvim、ローカルマシン (M-series 想定。CI 実機とはズレるため測定マシン名を results に併記)

**成功基準**:
- 定量: 50k 行・hunk 50 で初回 ≤1.5s、保存再計算 ≤500ms (中位数)。通常レビュー規模 ≤5k 行で初回 ≤100ms。超過パターンは fallback 候補案の計測値が閾値内であることまで
- 定性: 通常規模で scrollbind 連打追従にカクつきがない (キー応答遅延の実測値を記録)

**判断**:
- 成功 → 設計そのまま。実測値を DESIGN「既知の制約」に数値として記載
- 失敗 → fallback を採用 (`fallback_adopted`) として設計に反映

**POC_NEEDED マーカー**:
```
<!-- POC_NEEDED: id=huge-file-window-diff-perf, scope=50k 行級 2 窓 diff の初回・保存時再計算時間, risk=medium, blocker=false -->
```

<!-- POC_STATUS: id=huge-file-window-diff-perf, blocker=false, status=verified, confidence=0.80 -->

## PoC 結果

### head-window-key-gate — verified (confidence 0.85)
- 検証日: 2026-09-12
- 観測した事実: nvim v0.10.0 tarball と 0.13.0-nightly の両バイナリで buffer-local + 窓 role gate (`w:review_key_gate` winid 一致 + `nvim_win_is_valid` + 押下時点 buffer content フィンガープリント照合) の 3 窓構成アサーション 33/33×2 成立、マーカーログ 2029 件が両版完全一致。review 窓のみ発火・ユーザー窓不発火・drift 誤発火なし・`nvim_buf_del_keymap` 残骸ゼロ
- 結論: gate 方式で成立。設計帰結 2 点 — (1) gate 不成立窓ではユーザーの既存マップを再現できず 1 keystroke が built-in になる (expr 返値・feedkeys どちらも階層を返せず、remap feedkeys は E223) → help/config 明記または衝突しにくいキー選択 (2) ユーザー buffer-local の同キーマップは張込みで恒久失効 → install 前に `nvim_buf_get_keymap` で衝突検出し当該キーをスキップ
- fallback: 不要 (縮小分岐「head 窓に review キーを置かない」は未採用のまま記録保留)

### scratch-real-window-diff-pair — verified (confidence 0.85)
- 検証日: 2026-09-12
- 観測した事実: scratch(buftype=nofile, git show 内容) × `:edit` 実ファイルの異種隣接ペアで窓 diff・fold・`[c`/`]c`・scrollbind が v0.10.0 / 0.13 双方で同一結果・エラーなし。端ケース null(0 行)/同一内容/削除/binary 注釈窓の diffoff 退避 (`foldclosed()=-1` 確認)/diffopt 伝播まで results 期待値表と一致
- 結論: 窓 diff モード (diffview 同方式) で実装可。設計条件として adopting — diffopt は既定値のまま触らない (変更時は終了時復元+ユーザー窓への波及遅延の注記)、binary/削除告知窓は diffoff で退避、review 窓とユーザーの diff ペアは tab 分離必須 (同一 tab 併存で pairing 混線実測)、同期判定 primitives は topline=`line("w0")`、hl クラスは `hlID`+Diff* prefix
- fallback: 不要 (自前 extmark 色分け案は却下)

### lsp-buf-virt-lines-threads — verified (confidence 0.90)
- 検証日: 2026-09-12
- 観測した事実: lua_ls attach 済み実バッファで 1 extmark (virt_text+virt_lines 併合) が diagnostic virtual text・semantic tokens と ns 分離で同居。fold 範囲包含と tmux 画面実測で fold 時 virt_lines ごと非表示確認。編集追従は eol anchor (start col -1) で行挿入時に自動 +1 追従。`right_gravity` (boolean) が正 ('gravity' 文字列は 0.13 で invalid key 実測)。ns_id 明示 clear で残骸 0
- 結論: 実バッファ extmark スレッド現行方式を維持して進行。設計帰結 — 同一バッファの**全窓にスレッドが表示される (抑止 API なし)** ため「ユーザー編集窓にも見える」を仕様として許容
- fallback: 不要

### tab-local-cwd-lsp-root — verified (confidence 0.85)
- 検証日: 2026-09-12
- 観測した事実: root 解決の由来が**開いたファイルパス起点の上方遡上のみ**と確定 (tcd/cwd は root_dir の決定に関与せず、陰性対照 `root_markers=".git/"`+tcd=worktree で root=nil・未起動を 0.10.0/0.13 で実証)。markers `.git` (ファイル許容) で lua_ls・`go.mod` で gopls は sent root_dir = workspaceFolders = worktree、initialize 成功、workspace/symbol が worktree のシンボルを返す (両版)。LSP サーバプロセスの spawn cwd は tab cwd に追従した
- 結論: tab-local tcd は維持 (サーバ spawn cwd・相対パス解決ツールに効く) が、root_dir の主因は root marker の worktree 遡上。worktree の `.git` は gitdir pointer ファイルなのでファイル許容マーカーなら停止
- fallback: 不要。残存リスク設計記載 — ユーザーの root_markers が dir 限定 `.git/` のみだと worktree で LSP がアタッチしない (README/既知の制約へ)

### huge-file-window-diff-perf — verified (confidence 0.80)
- 検証日: 2026-09-12 (Apple M3 Ultra / nvim 0.13.0-nightly / diffopt 既定 / -u NONE / headless / 3 回中位数)
- 観測した事実: 初回窓 diff 計算 50k 行×hunk50=24.0ms、50k×1=19.6ms、20k=11ms、2k=1.4-1.7ms (閾値 1.5s の約 60 倍の余裕)。保存 1 行後の再計算全パターン ≤24.2ms (閾値 500ms)。scrollbind 連打 0-0.03ms/key
- 結論: 設計そのまま。ただし nvim core は `:w` 単体では diff を再計算しない (-u NONE/--clean 双方 3s 収束せず実測) → **保存後は BufWritePost autocommand で明示 `:diffupdate`** が実装必須 (汚れていない再実行は忽略コスト)
- fallback: 不要 (diffopt 軽量化案は計測済みだが未採用)
