<!-- product-mode: cli -->
<!-- 変更履歴 [2026-09-12]: 2 窓窓 diff + head 実ファイル + branch mode worktree 撤廃 + file panel ツリー + diffview 風キー + PoC 結果反映 -->
# review.nvim 設計書

- 種別: 設計書

## 目的とスコープ

Neovim 内で GitHub の Files changed のようにブランチ/PR 差分をレビューし、コメントを蓄積して AI エージェント向けプロンプトとして出力するプラグイン (difit の Neovim 版相当)。

**MUST (この設計が必ず満たす)**:

1. 指定した base と head 側状態の差分を開いて行にコメントを付け、蓄積できる
2. コメントは Neovim を終了してもディスクに永続化され、次回起動後に `:Review` 1 操作で復元できる
3. **head 側は実ファイルバッファとして開き、編集可・LSP が効いた状態で差分を追える** (コード追跡が「レビューしながら」できること)。base 側との比較は Neovim 標準の窓 diff で行う。レビューは専有 tabpage で開き、file panel をトグルできる
4. PR を指定した場合は head を git worktree にチェックアウトし、**worktree 内の実ファイル**を tab-local cwd (`tcd`) で開いた状態でレビューする。レビュー終了時に worktree をクリーンアップする
5. 蓄積したコメントを AI エージェントに渡すプロンプトとしてクリップボードに出力できる。ファイルパスは先頭トークン `@<path>` の形式を含む

**review 対象の定義**: branch モードは base vs **現在のチェックアウトの作業ツリー** (未コミット変更を含む。保存時は自動再取得)。PR モードは base vs **自前 worktree の状態** (チェックアウト時点 = head コミット内容。worktree 内で編集すればそれも対象)。`staged` / `working` / `.` などの特殊引数は作らない — 引数で対象を切り替えず、常に上記の定義で自動確定する。

**やらないこと**: stdin 差分入力、生成ファイルの自動折りたたみ、GitHub のレビューコメントスレッド取り込み・書き戻し、telescope / nui.nvim 等の外部 UI プラグイン連携、diffview.nvim にある hunk stage/unstage・commit log panel・merge tool・option panel (diffview 化する対象は見た目・レイアウト・キーの導線であり、git 編集機能はスコープ外)。

## アーキテクチャと技術選定

- ランタイム: Neovim >= 0.10 (`vim.system` / extmark / `vim.json` / expr keymap が安定済み)。**ランタイム依存ゼロ** (標準 API のみ。devicons 等の外部プラグインは存在時だけ自動で使い、無くても壊れない)
- テスト: plenary.nvim の busted 互換ハーネス (`PlenaryBustedDirectory`)。開発時依存のみ

層構成と依存の向き (上位は下位を知る、下位は上位を知らない):

```
plugin/review.lua            # :Review コマンド登録 + VimEnter 起動 scan (薄い)
  └ lua/review/init.lua      # facade: setup/start/start_pr/resume/close/delete/prompt_*
      ├ handlers/            # セッション lifecycle・開始時 worktree/switch 判断・レビュー操作・prompt の調整役
      ├ core/                # diff パース、コメントモデル、anchor 検証、prompt ビルダー (純粋ロジック)
      ├ git/                 # git / gh / worktree / switch アダプタ (vim.system 境界。外界 DI)
      ├ store/               # セッション JSON の永続化 (stdpath("data"))
      └ ui/                  # file panel (ツリー)・base scratch・窓 diff レイアウト・実ファイル窓・入力/閲覧/help float
```

主要な決定 (変更コストが高いもの。根拠つき):

| 決定 | 内容 | 根拠 |
| --- | --- | --- |
| UI 形態 | **専有 tabpage の 3 窓**: file panel (左・幅既定 35・トグル可) + base 窓 + head 窓。base/head の 2 窓は `git show` scratch と実ファイルの隣接ペアに窓ローカル `diff / scrollbind / cursorbind / foldmethod=diff` を適用した Neovim 標準窓 diff (diffview.nvim と同方式)。専用 tabpage を作成し、ユーザーの diff 窓と同一 tab に併存させない | コード追跡 (MUST 3) に実ファイル + LSP が不可欠。窓 diff は fold/hunk 移動 (`[c`/`]c`) が標準で効く。comment anchor は new 側行番号 = head 実バッファ行番号で 1:1 となり「どちら側へのコメントか」は head 窓のみ発火で解消。tab 分離しないと窓 pairing が混線する (FEASIBILITY scratch-real-window-diff-pair 実測) |
| 差分取得・描画 | 差分の**意味** (ファイル一覧・±行数・anchor 検証・prompt) は `git diff <base>` を Lua パース (core/diff) して得る。差分の**表示**は窓 diff (Neovim 内部計算)。head 窓は `:edit` で実ファイル、base 窓は `git show <base>:<path>` の `review://base/...` scratch。unified 1 ペイン自前描画は持たない | 表示と意味の分離。表示が live (未保存編集も映る) でも、anchor・prompt・カウントは保存済み状態基準で安定する。unified 描画は実ファイル + LSP と両立できないため撤廃 (PoC verified: FEASIBILITY.md「PoC 結果」) |
| 保存時再取得 | head 窓のファイル保存 (BufWritePost) 時に自動で再取得し、parsing → anchor 検証 → ±カウント・prompt・スレッド表示に反映。`:diffupdate` を明示発火しないと窓 diff は再計算されない。再取得の ref 引数形は開始時の head 解決に一致させる (通常 = 単引数 `git diff <base>` / scratch 縮退時 = `<base> <head>`) | 「未コミット変更もレビュー対象」の定義を実装が時限なく満たすため。nvim core は `:w` 単体で再計算しない (huge-file-window-diff-perf 実測。3s 収束せず) |
| worktree 作成条件 | **mode=pr のみ作成**。branch モードは作らない — 現在のチェックアウトを直接レビューする (作業ツリーの未コミット変更がレビュー対象になるため、コミット内容を別ツリーで見る意味がない)。`stdpath("data")/review.nvim/worktrees/<repo-hash>/<slug>` 配置は変更なし。削除してよいのは `created_by_us=true` のみ (INV-3) | MUST 3・4 と「未コミットも対象」から機械的に帰結。switch 提案フローは下記「head が現在の HEAD と違うとき」の行。リポジトリのツリーにゴミを作らないのは変わらない |
| head が現在の HEAD と違うとき (branch) | `head` が rev-parse で現在の HEAD と違うコミットを指すとき、head が**ローカルブランチ**なら [y/N] で「そのブランチへ switch するか」を確認する。承諾 → `git switch <head>` して通常の実ファイル経路へ。拒否・ローカルブランチでない・作業ツリーが dirty (switch でユーザーの未コミット変更を危険にさらす) → 両窓 `git show` scratch の読み取り専用レビューに縮退し、INFO で明示 | 未コミット対象化により「head の状態」を実ファイルで示せるのはCheckout がそのコミットのときだけ。worktree を作らない決定の帰結として、switch と scratch 縮退の 2 経路に閉じる (確認を伴うので黙って checkout を動かさない) |
| LSP 連携 | レビュー tab 作成時に `:tcd` で tab-local cwd を向く。LSP の root_dir はファイルパス起点の root marker 遡上で決まり、**tcd/cwd は root_dir 自体には効かない** (server プロセスの spawn cwd に効く)。worktree を開けば `.git` pointer file / go.mod 等のマーカーで通常は worktree root に解決できる | tab-local-cwd-lsp-root 実測 (0.10.0/0.13、lua_ls markers=`.git`・gopls markers=`go.mod` で sent root_dir=workspaceFolders=worktree、workspace/symbol 応答確認)。dir 限定マーカーのみの設定に関する制約は「既知の制約」 |
| review キーの実装 | **buffer-local + 押下時点 window role gate**: 実ファイルバッファはユーザーが自分の窓でも開くため、マップは buffer-local に張り、rhs expr gate で `w:review_key_gate == winid` 一致 + `nvim_win_is_valid` + 押下時点のバッファ内容フィンガープリント照合を通ったときだけ review 操作を、不成立時は built-in 挙動を返す。張込前に `nvim_buf_get_keymap` でユーザー既存マップを検出し衝突キーはスキップ | window-local keymap API は Neovim に存在しない (0.13 で pcall nil 実測)。gate 不成立窓ではユーザーの 1 キーストロークが built-in になる副作用がある — user doc (help) に明記 (head-window-key-gate verified) |
| file panel 表示 | フラット一覧でなくフォルダツリー (折りたたみ・`i` で list/tree 切替・単一-child 連鎖連結表示)。ヘッダに `Changes (N)` と `Showing changes for: <base>..<head 表示名>` (通常経路の head 表示名は `作業ツリー`、縮退時は ref 名 — 書式の詳細は features/diff-review)、行は `<status> <icon?> <basename> +a -d` と親パス grey、選択行と head 窓の相互追従 | 深さのあるリポジトリでフラット一覧が読めない (diffview と同じ動機)。viewed `[✓]`・絞り込み・`x` は review.nvim 独自機能として維持 |
| 永続化 | JSON 1 ファイル / セッション。`stdpath("data")/review.nvim/sessions/<repo-hash>/<slug>.json`。コメント CRUD ごとに即時アトミック書込 (tmp + rename) | MUST 2。Vim の session/view 機構は窓 diff と実ファイル open の状態と噛み合わず、独自書式のほうが復元時の検証 (下述 anchor) ができる |
| 復元検証 | コメントに new 側行番号 + anchor (対象行テキスト + 前後 1 行) を保存。再開時に**直近パーサ結果**と突き合わせ、±20 行以内に同一テキストを検索・無ければ `outdated`。検証の正本テキスト源は core/diff パーサ出力 (add/context 可視行) | 黙って捨てず、黙って誤った場所につけない。head が作業ツリー基準になっても anchor の意味 (new 側行) は不変で、スキーマは無変更 |
| 起動時復元 | VimEnter で当該 repo の open セッションを検出して notify。`:Review` (無印) が即復元 (複数あれば vim.ui.select)。復元時も head 解決フロー (switch 提案/scratch 縮退) を通す | 「起動後すぐに復元できる」= 1 操作。勝手にウィンドウを開く surprise は避け、検知と通知までを自動で行う |
| アクティブセッション数 | nvim インスタンスにつき同時 1 セッション。切替時は現セッションを save して閉じる | 状態管理と worktree/窓 所有権の単一化 |
| head 省略 | `:Review start <base>` の head 引数省略時は `rev-parse --abbrev-ref HEAD` (ブランチ名。detached のとき `HEAD`) を解決して**保存**しレビューする (入力 UI を出さない)。明示指定時はその引数 を保存し上記 switch/scratch フローへ。「レビュー = 現在の作業ブランチ vs マージ先」が主用途であり毎回選ばせるのはノイズ | 実運用の定型 (ブランチ指定レビューの主目的) に応じる。ref 補完 UI 自体は維持 |
| ref 選択 | base/head の入力は `vim.ui.input` + `completion=customlist` (git branch/tag 一覧) | vim.ui.select はブランチ数が多い repo で重い。カスタム float は自前維持コストが増える。中間案 |
| gh / git 実行 | アダプタは `config.git_bin` / `config.gh_bin` を注入可能 (既定 `git` / `gh`)。検証では shell のスタブを立てる | 外部 CLI 呼び出しの検証性を担保 (PR モードの E2E を gh スタブで可能にする) |

## 開発・検証コマンド

```bash
export PLENARY_PATH=$HOME/.local/share/nvim/review-nvim-deps/plenary   # ローカルclone位置
make test          # 単体テスト (headless nvim + plenary、lua/review/**/*_spec.lua)
make test-file FILE=lua/review/core/diff_spec.lua
make lint          # luacheck (対象: lua/ plugin/、.luacheckrc 準拠)
make format        # stylua (.stylua.toml)
make format-check
make plugin-check  # headless 起動で :Review 定義・:help review 到達・stderr 空を確認
make check         # format-check + lint + test + plugin-check。commit 前のゲート
make e2e           # 実 headless nvim + 実 git の golden path (tests/e2e/*.lua)
```

- **外部依存**: テスト実行に plenary のみ。セットアップ手順 (dev-impl の worktree からもそのまま使える): `git clone --depth 1 https://github.com/nvim-lua/plenary.nvim ~/.local/share/nvim/review-nvim-deps/plenary` → `PLENARY_PATH=... make check`。gitignored な機密ファイルは無い (`.worktreeinclude` 不要)
- **ポート制約**: サーバを持たず固定ポートは存在しない。**テスト・E2E は毎回 `mktemp -d` の一意ディレクトリに fixture git repo を作り、終了時に掃除する** 契約 (環境変数と一時ファイルで直列実行に依存しない。LSP を要する検証は headless では行わず、tab cwd・root 解決は状態アサーションまで。実 LSP 依存の挙動は手動/tmux 実測でコミットメッセージに手順を残す)
- **E2E (cli モード)**: Playwright は使わない。`make e2e` が実 `git` で fixture repo を組み、headless `nvim --headless` で起動→レビュー操作→再起動→復元 assert のシーケンスを実行し失敗時 exit 1。PR/E2E 経路は `gh` の shell スタブを PATH に立てる。専有 tab・窓 diff・実ファイル open は窗口内容とバッファパスの状態アサーションで pin し、insert-mode 残留など実 PTY 契約のみ tmux + `--remote-expr` 実測

## データスキーマ

DB は持たない。状態はすべてセッション JSON ファイル (正本: store/ が読み書き、schema version 1)。実ファイル窓の編集内容・fold・窓配置は保存しない (開いている間の状態)。

`<slug>.json` (セッションファイル):

| key | 型 | 説明 |
| --- | --- | --- |
| `version` | number | 1。読み込み時に不一致ならマイグレーションか明示的拒否 |
| `id` | string | slug。`main..feature` → `main--feature`、PR は `pr-<number>`。`[A-Za-z0-9._-]` 以外の文字は `_` に置換。稀な refs 名由来で別 refs 組と衝突した場合は新規作成を拒否して既存を案内する (`:Review delete` で削除可) |
| `repo` | string | repo top-level の絶対パス。branch モードはレビュー実施中のチェックアウト位置 (ファイルは sha1(repo) 先頭 16 桁のディレクトリに収める) |
| `mode` | `"branch" \| "pr"` | worktree は pr のみ (決定表) |
| `base` / `head` | string | git ref 名。PR の base は baseRefName、head は同一 repo ブランチなら headRefName をそのまま、fork のみ fetch した一時 ref (`review-nvim/pr-<n>`)。branch モードの head 省略開始時は `rev-parse --abbrev-ref HEAD` の結果 (detached のとき literal `HEAD`) を保存 — 復元時にブランチ名として再評価でき、裏でブランチが変わっていれば head 解決フロー (switch 提案) が走る |
| `pr` | object\|null | `{number, url}` (mode="pr" のときのみ) |
| `worktree` | object\|null | `{path, created_by_us}` (boolean)。branch モードは常に null。削除してよいのは `created_by_us=true` のものだけ |
| `status` | `"open" \| "closed"` | close はファイル削除ではなく closed にする (再オープンのため) |
| `files` | map path → `{viewed}` (boolean) | 差分に出てくる全ファイルの状態 |
| `comments` | Comment[] | 下記 |
| `created_at` / `updated_at` | number | epoch seconds |

Comment:

| key | 型 | 説明 |
| --- | --- | --- |
| `id` | string | `c<n>` (セッション内連番。新規採番は既存 max+1) |
| `file` | string | リポジトリ相対パス |
| `line` / `end_line` | number | **new (head) 側**のファイル行番号 (= head 実窓のバッファ行番号)。単一行なら同値 |
| `body` | string | マルチライン可 |
| `anchor` | `{before, line, after}` (各 string\|null) | 追加時点の new 側行テキスト + 前後 1 行 (存在しなければ null)。復元時の漂移検出用 |
| `state` | `"active" \| "outdated"` | 復元検証の結果 |
| `created_at` | number | |

## API 一覧

Lua 公開 API とキーバインドの正本はここ。各機能の挙動は docs/design/features/ が正本。

**コマンド (`:Review`、1 コマンド + サブコマンド)**:

| 書式 | 概要 | 機能設計 |
| --- | --- | --- |
| `:Review` | open セッションの復元 (複数あれば選択) | persistence-restore |
| `:Review start <base> [head]` | ブランチレビュー開始。`<base>` / `[head]` は cmdline `<Tab>` で branches → tags 順に補完。**head 省略 = `rev-parse --abbrev-ref HEAD` を自動採用・保存** (「データスキーマ」)。head 指定時は現在の HEAD と違えば switch 提案、不可なら scratch 縮退 (決定表) | diff-review |
| `:Review pr <number\|url>` | PR レビュー開始 (gh 連携 + worktree + `tcd`)。`<number>` は cmdline `<Tab>` で gh の open PR 番号を補完 | pr-worktree |
| `:Review list` | 保存済みセッションの一覧表示 | persistence-restore |
| `:Review close` | 現セッションの save + worktree クリーンアップ (pr のみ) (実ファイル窓と張った extmark の掃除もここ) | pr-worktree (セッションとレビューの終了) |
| `:Review delete <id>` | 保存済みセッションの削除 (comments も失う。active なら先に close 相当の掃除をしてから削除、確認付き)。`<id>` は cmdline `<Tab>` で保存済み id を補完 | pr-worktree (セッションの削除) |
| `:Review prompt [file]` | プロンプトをクリップボードへ (省略 = 全コメント、file 指定 = そのファイル分) | ai-prompt |

**Lua API**: `require("review").setup(opts)` / `.start({base[, head]})` / `.start_pr({number})` (URL から番号を抽出するのはコマンド層。facade は number のみ) / `.resume({id})` / `.close()` / `.delete({id})` / `.prompt_all(opts)` / `.prompt_for_file(path, opts)`。戻り値の結果型 `{ok, data, error, code}` は**同期的に判定できる失敗** (引数不正、active 不在、config 不正) のみを表し、git/gh を伴う操作は「ディスパッチを受け付けた」ことの `ok` として返る。実行の成否 (差分取得の結果) は非同期に UI 開閉か vim.notify でフィードバックする (UI をブロックしないため `:wait()` は使わない。例外は cmdline ref 補完のみ — 「既知の制約」参照)。**active セッションを必要とする API (close / prompt_* / レビュー操作) が active 0 件で呼ばれた場合は `E_NOT_ACTIVE` を同期で返す** (`:Review` 無印・`:Review list`・`:Review delete` は active 不要)。

**config (setup で受け付ける既定値)**: `git_bin="git"`、`gh_bin="gh"`、`diff_context=nil` (git 既定の 3。差分パースの文脈行数)、`auto_notify_resume=true`、`panel_width=35` (file panel 窓幅)、`keymaps={...}` (下記のデフォルト表)、`highlight={}` (グループ別 override)、`winbar=true` / `number=false` (review 窓の装飾 — diff-review「窓装飾 (chrome)」)。

**デフォルトキーマップ** (buffer-local + window role gate、config で変更可。`<leader>` はユーザーの leader を使う。<TAB>/<S-TAB> は `<Tab>` `<S-Tab>` として登録):

| 場所 | key | 動作 |
| --- | --- | --- |
| head/base 窓 | `c` (normal / visual-line) | コメント作成 (float input。visual は範囲コメント)。**head 窓のみ発火**。base 窓・告知 scratch (deleted/binary) では WARN («この窓にはコメントを付けられません») (確定文言の正本はこの表) |
| head/base 窓 | `e` / `d` / `y` / `i` | カーソル行のコメント編集 / 削除 (arming 二重押し) / プロンプト yank / 全文閲覧。同上 head 限定 |
| head/base 窓 | `[F` / `]F` | 最初 / 最後のファイル (`]c` / `[c` は **マップせず Neovim 標準の hunk 移動**に任せる) |
| head/base 窓 | `<Tab>` / `<S-Tab>` | 次 / 前のファイル (パス昇順。端は無動作。viewed 更新と save は panel `<CR>` と同一。diff ペアが切れていれば張直す) |
| head/base 窓 | `<leader>e` / `<leader>b` | file panel へ focus / file panel 表示トグル (panel を閉じても tab とレビュー窓は残る) |
| head/base 窓 | `R` | 差分再取得 (`git diff` 引数形は head 解決に一致 — 通常 `<base>` / 縮退 `<base> <head>`) → 再パース → anchor 検証 → ±カウント・スレッド・panel 更新 → :diffupdate |
| head/base 窓 | `o` | そのファイルの実ファイルをレビュー tab の外 (前行儀の tab) で開く — diff ペアを壊さず通常編集文脈へ出る経路。scratch 縮退時・base 窓でも同じ動作 |
| head/base 窓 | `q` | `:Review close` 相当 (コメントありなら確認プロンプト。tab を閉じる。実ファイルバッファとユーザー窓には触れない) |
| head/base 窓 | `<F1>` | help float |
| file panel | `<CR>` / `o` / `l` | カーソル entry を開く (ファイル = 実ファイル窓に張って focus、dir = fold トグル)。(file panel 上の `o` = 開く。diff 窓の `o` とは意味が違う) |
| file panel | `<Tab>` / `<S-Tab>` / `[F` / `]F` | 次 / 前 / 最初 / 最後のファイル (開いて focus は diff 窓と同一動作) |
| file panel | `i` | list 表示 (フルパス 1 行) と tree 表示の切替 (view state。session JSON に載せない) |
| file panel | `x` | viewed 切替 |
| file panel | `/` | 絞り込み (大文字小文字無視の path 部分一致。空入力 = 解除、キャンセル = 現状維持。`<Tab>`/`[F`/`]F` と `<CR>` は絞り込み後の集合だけを辿る) |
| file panel | `R` | 差分再取得 (レビュー窓の `R` と同一) |
| file panel | `q` | `:Review close` 相当 (diff 窓の `q` と同じ) |
| sessionlist (`:Review list` のバッファ) | `<Enter>` | 選択セッションを開く (closed → open。head 解決フロー・worktree 要否は pr-worktree の作成判断で再開時に再評価) |
| sessionlist | `d` | 選択セッションを削除 (`:Review delete` と同一の確認フロー) |
| sessionlist | `q` | 一覧バッファを閉じる (セッション状態は変えない) |

- fold 操作 (`za` / `zo` / `zc` / `zR` / `zM`) と panel の `j`/`k` 移動はマップせず標準挙動に任せる
- 移動系で「ファイルを開く」経路はすべて同一処理 `open_file(path)` (head 窓に実ファイル張付・base 窓に scratch 張付・viewed 更新・save・panel 再描画) を呼ぶ

## 横断規約

- **結果型**: 手続きは例外を投げず結果型 `{ok, data, error, code}` を返す (git 実行失敗、ref 解決不能、gh 不在など)。結果テーブルには型標識 `__class = "review.Result"` を付与する (spec の全体比較で異物混入を検出するため。消費側は 4 キー以外は読まないこと)。`pcall` は `vim.json.decode` とアダプタ境界、expr keymap gate、cmdline 補完 API 探測 (「既知の制約」参照) のみ
- **非同期**: 単発実行は `vim.system`。コールバックはアダプタ境界で `vim.in_fast_event()` を判定して `vim.schedule` でイベントループへ回す。**UI 操作はスローイベント限定**
- **永続化**: 書き込みは即時・アトミック (同一ディレクトリの tmp に書いて `os.rename`)。読み込み失敗 (JSON 破損) は `.corrupt` に退避してから空セッション扱いとし、通知する (レビュー不能にしない)。例外: 読み取り不能 (権限等) で退避自体ができない場合は退避せず WARN のみ「存在しない」扱いとする (例外の条件は persistence-restore「読込」が正本)
- **エラー表示**: `vim.notify` (エラー = WARN、情報 = INFO)。レビュー操作の途中失敗は元の状態を保持したまま理由 1 行を出す
- **命名**: namespace は `review` (`lua/review/`、`plugin/review.lua`)。highlight グループは `ReviewCommentLine` (コメント range の下線)、`ReviewCommentBody` / `ReviewCommentOutdated` (行下スレッド本文 / outdated の gray)、`ReviewPanelFile` / `ReviewPanelDir` / `ReviewPanelStatus` / `ReviewPanelMeta` (file panel の basename / dir 行 / git status 記号 / 親子パス・±数)。差分行の着色は **Neovim 標準 `DiffAdd` / `DiffDelete` / `DiffText`** を使う (窓 diff が直接適用するため自前 diff グループを持たない。`config.highlight` の override は上記 review 自前グループ + 標準 Diff* の両名を受け付ける)。テストはソースと同ディレクトリに `*_spec.lua` (例外: `plugin/` 配下のファイルの spec は `lua/review/` 直下に置く)
- **UI**: float は `border="rounded"`。入力に telescope 等は使わず `vim.ui.input` / 標準バッファに載せる。scratch 系バッファは filetype を意図的に集約する: file panel と `:Review list` のセッション一覧は共通の `review-list`、base 窓 scratch は内容に応じた file-type detect。**buffer-local キーマップ・extmark namespace ともにバッファ作成元 (`review_meta`) では判定を決めつけず、窓 role (実ファイル窓は `w:review_key_gate` + 押下時点内容照合、scratch 系は `review_meta`) から導く** (FileType autocmd 分岐は使わない)。実ファイルバッファへ張るコメント extmark は**セッション open 中はそのバッファの全窓に見える** (窓単位抑止 API が無い実測)。閉じる時に張った全バッファの namespace を明示 clear する (残骸 0 をアサーションで保証)
- **窓の所有**: レビュー用 tabpage は専有。file panel / base / head 窓の役割は id ではなく**内容と窓変数から導く** (drift recovery)。ユーザーがレビュー窓で `:edit` 等して窓の役割が壊れたときは復旧経路 (`R` / `<Tab>` / panel `<CR>` の open_file 共通処理) で張り直す。レビュー中は `diffopt` の既定値を変えない

## ドメインモデル

集約: Session (id, repo, mode, base/head, worktree?, files, comments)。値オブジェクト: Comment (file + new 側行 range + body + anchor + state)。

不変条件:

- INV-1 nvim インスタンス内でアクティブ (UI が開いている) セッションは高々 1 つ。セッション切替は必ず save → close を経る
- INV-2 コメントの `line`〜`end_line` (`line <= end_line`) は追加時点でそのファイルの new 側状態に存在する行範囲のときだけ作る (new 側に無い場所 = 削除専用行のみの range / 告知 scratch 窓には作らない)。anchor 検証は直近のパーサ結果に対して行う。「行番号の写像はパーサ (core/) 起点 1 系統 + head 実窓の行 = new 側行番号の 1:1 写像」の 2 経路に閉じ、第 3 の行番号計算を作らない (「既知の制約」)
- INV-3 作業ツリー・チェックアウト・ref へ**確認なしに触る操作を作らない**: worktree の作成/削除は `created_by_us=true` と mode=pr の記録があるもののみ。`git switch` は必ず [y/N] 確認を通過したときだけ実行し、dirty な作業ツリーでは提案もしない
- INV-4 コメント CRUD・viewed 切替・差分再取得の直後には必ずセッションがディスクへ永続化されている (MUST 2 の根拠。save 失敗時は例外としてメモリ保持 + WARN の上、次の状態変化時と close 時に再試行する)。review 操作の範囲でユーザー実ファイルの内容を変えるのは**ユーザーの明示的な編集 (head 窓での :w) のみ**

## 既知の制約

実装が必ず従う、検証済みのプラットフォーム上限・ライブラリの性質 (根拠 = FEASIBILITY.md「PoC 結果」と実測コミット):

- **キー**: window-local keymap API は Neovim に存在しない (`nvim_win_set_keymap` は nil。keymap API は global 3 + buffer 3 のみ、0.10/0.13 実測)。実ファイル窓の review キーは buffer-local + window role gate で実装する。副作用として gate 不成立窓ではユーザーの同キー既存マップが再現されず 1 キーストロークが built-in になる (help に明記)。ユーザー buffer-local の同キーマップは張込みで恒久失効するため張込前検出し衝突キーはスキップする
- **窓 diff**: `:w` 単体では Neovim は窓 diff を**再計算しない** (BufWritePost で `:diffupdate` を明示発火するまで fold が古い。実測 3s 収束せず)。binary 注釈窓・削除告知 scratch など窓 diff から外す窓は必ず `diffoff` (退避は `foldclosed()` が -1 になることで検証可)。`:diffoff` は `foldmethod` を元へ戻さない
- **窓 diff 性能** (Apple M3 Ultra / nvim 0.13-nightly / -u NONE / 3 回中位数): 初回計算 50k 行×hunk50 = 24ms、50k×1 = 19.6ms、20k = 11ms、2k = 1.7ms。保存 1 行後の `:diffupdate` 再計算 ≤ 24.2ms、scrollbind 連打 ≤ 0.03ms/key。UI 実負荷・CI マシンは未計測だが 60 倍の余裕がある
- **diff ペアの併存**: review 窓とユーザーの窓 diff ペアを同一 tabpage に併存させると pairing が混線する (実測) — レビューは専有 tab に開く。`diffopt` は global option で伝播するためレビュー側から値を変えない (変える変更は終了時復元 + 波及遅延の注記を要する)
- **LSP root**: root_dir は開いたファイルパス起点の root marker 遡上で決まり、cwd/tcd は root_dir 決定に関与しない (server プロセスの spawn cwd にのみ効く)。worktree には `.git` が **ファイル** (gitdir: pointer) で置かれるため、ユーザーの root_markers が dir 限定形式 `.git/` のみだと worktree 実ファイルに LSP がアタッチしない (tcd で救われない。README/この節で注意喚起。worktree にコミット済みマーカー (go.mod 等) があれば解決)
- **extmark**: 実バッファの virt_text/virt_lines はそのバッファの**全窓に**表示される (窓単位抑止 API 無し、0.13 実測)。コメントスレッドはユーザー編集窓にも見える (仕様として許容)。編集追従は eol anchor (start col -1) で自動追従 (+1)し、境界挙動の制御は `right_gravity` (boolean — `'gravity'` 文字列は invalid key 実測)。clear は ns_id を明示した `nvim_buf_get_extmarks(buf, ns, 0, -1, {})` で残骸 0 を検証
- **virt_text と wrap**: extmark の virt_text は `wrap` と干渉する。head・base・panel 窓は `wrap=off` (窓ローカル。実ファイルバッファのユーザー窓設定は変えない)
- **削除ファイル**: head 側で存在しないファイルの head 窓に実パス (`<repo>/<path>` 等) を `:edit` すると空の新規バッファになり `:w` でファイルが復活する — 削除告知 scratch (`review://deleted/...`、`diffoff`) に置換える
- **未追跡ファイル**: `git diff <base>` は untracked を出力しないため、branch モードでも未追跡ファイルはレビュー対象にならない (`git add` 前の新ファイルは対象外。復元検証・カウント・prompt に現れない)
- **extmark と syntax**: 同範囲の syntax 装飾と extmark は競合しうる。コメントの下線・スレッドは独立 namespace と自前 highlight で表現する (窓 diff の Diff* は Neovim 内部適用なので競合対象にしない)
- worktree・fetch のパス・権限挙動の実機検証は macOS / Linux に限られる (Windows は検証範囲外。パス連結は `vim.fs.joinpath` で吸収)
- worktree 内に未コミット変更があると `git worktree remove` は失敗する (ユーザーの変更を黙って捨てられない)。close 時に検知して `--force` の可否をユーザーへ確認する (決定表の正本: pr-worktree「セッションとレビューの終了」)
- kill 等で異常終了した経路では VimLeave の掃除が走らない。起動時に「記録上 open のセッションの worktree の実在」をスキャンし、残骸は通知の上で `git worktree prune` + ディレクトリを掃除する (MUST 4 の異常終了側の担保。正本: persistence-restore / pr-worktree)
- PR 用の一時 ref を消し忘れると repo に残骸が積む。方針: worktree 作成は `git worktree add --detach` とし、fork PR の fetch でのみ `review-nvim/pr-<n>` ref を作る。close では worktree dir のみ削除 (ref は再開時の fetch 省略のために残す)、`:Review delete` とセッション不要時のみ ref も消す。fetch の宛先を短縮名にすると refs/heads/ 底下に保存され、`git update-ref -d` は短縮名を "bad name" で拒否する (git 2.x 実測)。削除は保存フルネームで行い、存在確認は `rev-parse --verify -q`
- `git diff` のファイルパス抽出は `--- ` / `+++ ` 行だけに依存できない (空ファイルの新規・削除・モード変更では 2 行自体が出ず、空ファイル新規では `@@` も無い。git 2.55 実測)。抽出順は `rename to` → `+++` 新パス → `---` 旧パス → `diff --git` 行の新側でパーサ内のみ。hunk 行数 1 のときヘッダは `,1` を省略 (`@@ -1 +1,5 @@`)、0 は明示 (`+1,0`)。1 省略を 0 と誤読すると行番号がずれる
- リネームファイル: 差分のパスは新旧 2 つ。head 実窓 = **新パス**の実ファイル、base scratch = `git show <base>:<旧パス>`。抽出は上の `rename to` 経路に一本化する
- `nvim_create_user_command` の customlist 補完 API がバージョンで変わった: 0.10 系は `complete="customlist"` + `completion=fn`、0.13 系は `complete=fn` (`completion` は invalid key)。plugin/review.lua は pcall フォールバックで両対応
- 既定の `vim.ui.input` は opts を `vim.fn.input` へそのまま渡す。 opts に Lua 関数を混ぜる形状は E467 となり既定実装が黙って `on_confirm(nil)` に変換する (既知)。cmdline に渡せる補完は文字形式 `completion='customlist,{Vim script 関数名}'` のみ
- cmdline の customlist 補完は同期 API なのでコールバックを待てない。同期実行を許可するのは **外部実行 (vim.system) を伴う** cmdline 候補の出所 3 系統のみ (ref 補完 run_sync + TTL cache 成功 30s/失敗 5s、`:Review delete` id 補完 (`rev-parse --show-toplevel`、cache 無し = FS 読取のみ)、`:Review pr` 番号補完 run_sync)。メモリ/状態読取のみで完結する候補源 (`:Review prompt` の file 引数 = active セッションのファイル一覧) は外部実行を伴わないのでこの制約の外。待機上限 250ms、timeout は kill + 候補 0・無通知。それ以外の `:wait()` ブロッキングは禁止。補完関数には補完中の語でなく cmdline 全体と `cursorpos` が渡る。位置判定は語数 + 末尾空白で行う
- `vim.system` の spawn 失敗の取り扱いがバージョン差あり: bin 不存在はスケジュール内 error 扱い、cwd 不正は同期 throw。git/cli.lua は `vim.fn.executable(bin)` 事前判定 + pcall で結果型へ変換
- `git/cli` の既定の注入スタブは `on_exit` を**同期**で呼ぶため、完了順序を contract に待つ処理の spec は同期スタブでは作れない。順序を pin する spec は遅延発火スタブを使う
- クリップボード provider 検出 Lua API (`clipboard.provider()`) は 0.13-nightly に存在しない。provider 無しでも `setreg('+', ...)` は内部選択に成功するため書込前に `g:clipboard` / `exists('*clipboard#copy')` / `require('clipboard').provider()` の順で検出し、無いは register 0 のみ + WARN
- `setreg` の第 1 引数 List は E730 になる。複数レジスタ書込は個別呼び出し
- 標準 API に sha1 は無い。repo-hash は sha1 先頭 16 桁の独自実装 (`store/paths.lua`)。算法を差し換えると既存セッションが到達不能になる
- LuaJIT `string.format('%x')` は負の int32 を 16 桁符号拡張で出す。32bit 演算結果は出力直前 0..2^32-1 へ正規化 (`u32`)
- headless のキー投入は `:normal` が唯一の安定経路 (`nvim_input` / `feedkeys` は `vim.wait` で消費されない)。`:normal` 内で error が出ると hit-enter でハングするため driver は pcall + `cquit`。視覚選択は `Vj` 移動と `c` を分割投入
- `vim.wait` を起動 `-c` 内で使うと `VimEnter` が発火しない。起動後イベント依存のスクリプトは `defer_fn` で逃がす
- Neovim に `BufWipedout` autocmd は無い (wipe でも `BufUnload`)。バッファ付随 module state の掃除は `BufUnload` で受ける。`nvim_buf_set_extmark` の `end_col` に `-1` は不正 (行末バイト数を明示)

## 未解決の論点

なし
