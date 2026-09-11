<!-- product-mode: cli -->
# review.nvim 設計書

- 種別: 設計書

## 目的とスコープ

Neovim 内で GitHub の Files changed のようにブランチ間差分をレビューし、コメントを蓄積して AI エージェント向けプロンプトとして出力するプラグイン (difit の Neovim 版相当)。

**v1 MUST (この設計が必ず満たす)**:

1. 指定したブランチ (git ref) 間の差分を開いて行にコメントを付け、蓄積できる
2. コメントは Neovim を終了してもディスクに永続化され、次回起動後に `:Review` 1 操作で復元できる
3. PR を指定した場合は head を git worktree にチェックアウトし、**worktree 内の実ファイルを参照できる**状態でレビューする。レビュー終了時に worktree をクリーンアップする
4. 蓄積したコメントを AI エージェントに渡すプロンプトとしてクリップボードに出力できる。ファイルパスは先頭トークン `@<path>` の形式を含む

**v1 やらないこと** (difit にあっても作らない): stdin 差分入力、`staged` / `working` / `.` などの特殊引数 (対象は committed な ref 間 diff のみ)、生成ファイルの自動折りたたみ、GitHub のレビューコメントスレッド取り込み・書き戻し、telescope / nui.nvim 等の外部 UI プラグイン連携。

## アーキテクチャと技術選定

- ランタイム: Neovim >= 0.10 (`vim.system` / extmark / `vim.json` が安定済み)。**ランタイム依存ゼロ** (標準 API のみ。docker.nvim と同じ規律)
- テスト: plenary.nvim の busted 互換ハーネス (`PlenaryBustedDirectory`)。開発時依存のみ

層構成と依存の向き (上位は下位を知る、下位は上位を知らない):

```
plugin/review.lua            # :Review コマンド登録 (薄い)
  └ lua/review/init.lua      # facade: setup/start/start_pr/resume/close/delete/prompt_*
      ├ handlers/            # セッションの開始/終了 lifecycle・コメント操作・prompt 組み立ての調整役
      ├ core/                # diff パース、コメントモデル、prompt ビルダー (純粋ロジック)
      ├ git/                 # git / gh / worktree アダプタ (vim.system 境界。外界 DI)
      ├ store/               # セッション JSON の永続化 (stdpath("data"))
      └ ui/                  # sidebar (変更ファイル一覧)・diff バッファ・入力 float・help
```

主要な決定 (変更コストが高いもの。根拠つき):

| 決定 | 内容 | 根拠 |
| --- | --- | --- |
| UI 形態 | 2 ペインの通常分割: 左 sidebar (変更ファイル一覧) + 右 unified diff バッファ (`review://` scratch buffer) | レビューは長時間の連続作業で float は不適切。コメントの行紐付けと range 選択は単一ペインの unified 形式が最も単純 (GitHub / difit と同じ相互作用) |
| 差分取得 | `git diff <base> <head>` の出力を Lua でパースして自前レンダリング。`:diffthis` は使わない | extmark によるコメント紐付けと new 側ファイル行番号への変換が unified 1 バッファだと自明。`diffthis` は左右どちらのバッファへのコメントか曖昧になる |
| worktree 作成条件 | 例外条件 (下記) を除き常に作成。**作らないのは mode が branch で、`git rev-parse <head>` のコミットが HEAD と一致し、かつ `git status --porcelain` が空のときのみ** (同一ブランチ名でも未コミット変更があれば作成。mode=pr は常時作成し、後述の fetch と worktree を用意する)。配置は `stdpath("data")/review.nvim/worktrees/<repo-hash>/<slug>` (リポジトリ外。slug は repo 単位にしか一意でないため repo-hash 下で分離) | MUST 3 の PR に加えブランチレビューでも `@path` が指す「実際に読めるファイル」= head のコミット内容を保証する。リポジトリのツリーにゴミを作らない。PR 用に作る機構をブランチでも再利用して 1 機構にする |
| 永続化 | JSON 1 ファイル / セッション。`stdpath("data")/review.nvim/sessions/<repo-hash>/<slug>.json`。コメント CRUD ごとに即時アトミック書込 (tmp + rename) | MUST 2。Vim の session/view 機構は diff scratch バッファと噛み合わず、独自書式のほうが復元時の検証 (後述の anchor) ができる |
| 復元検証 | コメントに new 側行番号 + anchor (対象行テキスト + 前後 1 行) を保存。再開時に差分が揺れていた場合、±20 行以内に同一テキストを検索、無ければ `outdated` フラグを付けて表示はする | 黙って捨てず、黙って誤った場所につけない。行番号だけ保存だと rebase 後に全滅する |
| 起動時復元 | VimEnter で当該 repo の open セッションを検出して notify。`:Review` (無印) が即復元 (複数あれば vim.ui.select) | 「起動後すぐに復元できる」= 1 操作。勝手にウィンドウを開く surprise は避け、検知と通知までを自動で行う |
| アクティブセッション数 | nvim インスタンスにつき同時 1 セッション。切替時は現セッションを save して閉じる | 状態管理と worktree 所有権の単一化。複数同時レビューは nvim の「1 repo = 1 checkout tree」とも相性が悪い |
| ref 選択 | base/head の入力は `vim.ui.input` + `completion=customlist` (git branch/tag 一覧) | vim.ui.select はブランチ数が多い repo で重い。カスタム float は自前維持コストが増える。中間案 |
| gh / git 実行 | アダプタは `config.git_bin` / `config.gh_bin` を注入可能 (既定 `git` / `gh`)。検証では shell のスタブを立てる | 外部 CLI 呼び出しの検証性を担保 (PR モードの E2E を gh スタブで可能にする) |

## 開発・検証コマンド

リポジトリは scaffold 前。以下のコマンドはセットアップ issue の完了後に実測で確定させる (実装者はこの節のコマンドが打てない場合、まず Makefile と scripts/ を読んで確定する)。

```bash
make test          # 単体テスト (headless nvim + plenary、lua/review/**/*_spec.lua)
make test-file FILE=lua/review/core/diff_spec.lua
make lint          # luacheck (対象: lua/ plugin/、.luacheckrc 準拠)
make format        # stylua (.stylua.toml)
make format-check
make plugin-check  # headless 起動で :Review 定義・:help review 到達・stderr 空を確認
make check         # format-check + lint + test + plugin-check
make e2e           # headless nvim シナリオ E2E (scripts/e2e.sh の golden path: start / コメント作成 / 切替 / 復元)
```

- **外部依存**: テスト実行に plenary のみ。`PLENARY_PATH` 環境変数でパスを渡す。テスト依存のセットアップ手順 (dev-impl の worktree からもそのまま使える手順): `git clone --depth 1 https://github.com/nvim-lua/plenary.nvim ~/.local/share/nvim/review-nvim-deps/plenary` → `PLENARY_PATH=... make check`。gitignored な機密ファイルは無い (`.worktreeinclude` 不要)
- **ポート制約**: サーバを持つ要素がなく固定ポートは存在しない。並列実装の競合点は一時ディレクトリになり得るため、**テスト・E2E は毎回 `mktemp -d` の一意ディレクトリに fixture git repo と worktree を作り、終了時に掃除する** 契約 (環境変数と一時ファイルで直列実行に依存しない)
- **E2E (cli モード)**: Playwright は使わず、`scripts/e2e.sh` が実 `git` で fixture repo を組み (`main` / `feature` ブランチ、複数 commit)、headless `nvim --headless` でシーケンス (diff 起動 → コメント → nvim 再起動 → 復元 assert) を実行し、失敗時 exit 1。PR モードは `gh` の shell スタブを PATH に立てて検証する

## データスキーマ

DB は持たない。状態はすべてセッション JSON ファイル (正本: store/ が読み書き、schema version 1)。

`<slug>.json` (セッションファイル):

| key | 型 | 説明 |
| --- | --- | --- |
| `version` | number | 1。読み込み時に不一致ならマイグレーションか明示的拒否 |
| `id` | string | slug。`main..feature` → `main--feature`、PR は `pr-<number>`。`[A-Za-z0-9._-]` 以外の文字は `_` に置換。稀な refs 名 (`a--b` 等) 由来で別 refs 組と衝突した場合は新規作成を拒否して既存を案内する (`:Review delete` で削除可) |
| `repo` | string | repo top-level の絶対パス (ファイルは sha1(repo) 先頭 16 桁のディレクトリに収める) |
| `mode` | `"branch" \| "pr"` | |
| `base` / `head` | string | git ref 名 (PR の場合は base のブランチ名と fetch した一時 head ref) |
| `pr` | object\|null | `{number, url}` (mode="pr" のときのみ) |
| `worktree` | object\|null | `{path, created_by_us}` (boolean)。作成可否の判断は上記決定表。削除してよいのは `created_by_us=true` のものだけ |
| `status` | `"open" \| "closed"` | close はファイル削除ではなく closed にする (再オープンのため) |
| `files` | map path → `{viewed}` (boolean) | diff に出てくる全ファイルの状態 |
| `comments` | Comment[] | 下記 |
| `created_at` / `updated_at` | number | epoch seconds |

Comment:

| key | 型 | 説明 |
| --- | --- | --- |
| `id` | string | `c<n>` (セッション内連番。新規採番は既存 max+1) |
| `file` | string | リポジトリ相対パス |
| `line` / `end_line` | number | **new (head) 側**のファイル行番号。単一行なら同値 |
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
| `:Review start <base> [head]` | ブランチレビュー開始 (`{base}` / `{head}` は cmdline `<Tab>` で branches → tags 順に補完。head 省略時の選択 UI も同候補源。`completion=customlist`) | diff-review |
| `:Review pr <number\|url>` | PR レビュー開始 (gh 連携 + worktree)。`<number>` は cmdline `<Tab>` で gh の open PR 番号を補完 | pr-worktree |
| `:Review list` | 保存済みセッションの一覧表示 | persistence-restore |
| `:Review close` | 現セッションの save + worktree クリーンアップ | pr-worktree (セッション終了節) |
| `:Review delete <id>` | 保存済みセッションの削除 (comments も失う。active なら先に close 相当の掃除をしてから削除、確認付き)。`<id>` は cmdline `<Tab>` で保存済み id を補完 | pr-worktree (セッション終了節) |
| `:Review prompt [file]` | プロンプトをクリップボードへ (省略 = 全コメント、file 指定 = そのファイル分) | ai-prompt |

**Lua API**: `require("review").setup(opts)` / `.start({base, head})` / `.start_pr({number})` / `.resume({id})` / `.close()` / `.delete({id})` / `.prompt_all(opts)` / `.prompt_for_file(path, opts)`。戻り値の結果型 `{ok, data, error, code}` は**同期的に判定できる失敗** (引数不正、active 不在、config 不正) のみを表し、git/gh を伴う操作は「ディスパッチを受け付けた」ことの `ok` として返る。実行の成否 (差分取得の結果) は非同期に UI 開閉か vim.notify でフィードバックする (UI をブロックしないため `:wait()` は使わない。例外は cmdline ref 補完のみ — 「既知の制約」参照)。**active セッションを必要とする API (close / prompt_* / レビュー操作) が active 0 件で呼ばれた場合は `E_NOT_ACTIVE` を同期で返す** (`:Review` 無印・`:Review list`・`:Review delete` は active 不要)。

**config (setup で受け付ける既定値)**: `git_bin="git"`、`gh_bin="gh"`、`diff_context=nil` (git 既定の 3)、`auto_notify_resume=true`、`keymaps={...}` (下記のデフォルト表)、`highlight={}` (グループ別 override)、`winbar=true` / `number=false` (review 窓の装飾 — diff-review「窓装飾 (chrome)」)。

**デフォルトキーマップ** (すべて buffer-local、config で変更可):

| 場所 | key | 動作 |
| --- | --- | --- |
| diff | `c` (normal / visual-line) | コメント作成 (float input。visual は範囲コメント) |
| diff | `e` / `d` | カーソル行のコメント編集 / 削除 |
| diff | `y` | カーソル行のコメントのプロンプトを yank (ai-prompt 参照) |
| diff | `o` | その行の実ファイルを開く (worktree あり = 編集可の通常バッファ / なし = `git show <head>:<path>` の read-only scratch) |
| diff | `q` | `:Review close` 相当 (コメントありなら確認プロンプト) |
| diff | `<F1>` | help float |
| diff | `]d` / `[d` | 次 / 前のファイルへ (list 昇順を辿る。端は無動作。viewed 更新と save は sidebar `<Enter>` と同一) |
| diff | `S` | sidebar (変更ファイル一覧) へ focus 移動。一覧窓が閉じられていれば左に再建 |
| diff | `i` | カーソル行範囲のコメント全文を read-only float で閲覧 (編集は `e`。`q`/`<Esc>`/`<CR>` で閉じる) |
| sidebar (変更ファイル一覧) | `<Enter>` | そのファイルの diff へ移動 |
| sidebar | `o` | そのファイルの実ファイルを開く (diff の `o` と同じ規則) |
| sidebar | `x` | viewed 切替 |
| sidebar | `/` | 一覧を絞り込む (大文字小文字無視の path 部分一致で再描画。空入力 = 解除、キャンセル = 現状維持。`<Enter>`/`o`/`x` と `]d`/`[d` は絞り込み後の集合だけを辿る。view state で session JSON には載せない) |
| sidebar | `q` | `:Review close` 相当 (diff の `q` と同じ) |
| sessionlist (`:Review list` のバッファ) | `<Enter>` | 選択セッションを開く (closed → open。worktree 要否は pr-worktree の作成判断で再開時に再作成) |
| sessionlist | `d` | 選択セッションを削除 (`:Review delete` と同一の確認フロー) |
| sessionlist | `q` | 一覧バッファを閉じる (セッション状態は変えない) |

## 横断規約

- **結果型**: 手続きは例外を投げず結果型 `{ok, data, error, code}` を返す (git 実行失敗、ref 解決不能、gh 不在など)。結果テーブルには型標識 `__class = "review.Result"` を付与する (spec の全体比較で異物混入を検出するため。消費側は 4 キー以外は読まないこと)。`pcall` は `vim.json.decode` とアダプタ境界、および `plugin/review.lua` のコマンド登録 API バージョン探测 (nvim 0.10 と 0.13 で completion 引数の仕様が異なる。根拠は「既知の制約」の対応行) のみ
- **非同期**: 単発実行は `vim.system`。コールバックはアダプタ境界で `vim.in_fast_event()` を判定して `vim.schedule` でイベントループへ回す。**UI 操作はスローイベント限定**
- **永続化**: 書き込みは即時・アトミック (同一ディレクトリの tmp に書いて `os.rename`)。読み込み失敗 (JSON 破損) は `.corrupt` に退避してから空セッション扱いとし、通知する (レビュー不能にしない)
- **エラー表示**: `vim.notify` (エラー = WARN、情報 = INFO)。レビュー操作の途中失敗は元の状態を保持したまま理由 1 行を出す
- **命名**: namespace は `review` (`lua/review/`、`plugin/review.lua`)。highlight グループは `ReviewCommentLine` (コメント range の下線)、`ReviewCommentBody` / `ReviewCommentOutdated` (行下スレッド本文 / outdated の gray)、`ReviewDiffAdd` / `ReviewDiffDelete` / `ReviewDiffHunk` (diff 種別の色づけ)、`ReviewSidebarFile` / `ReviewSidebarStatus` (`review-list` バッファ = sidebar とセッション一覧で共通。横断規約「UI」参照)。テストはソースと同ディレクトリに `*_spec.lua` (例外: `plugin/` 配下のファイルの spec は `lua/review/` 直下に置く。plugin 直下に置くと rtp 起動時に spec が自動 source されるため)
- **UI**: float は `border="rounded"`。入力に telescope 等は使わず `vim.ui.input` / 標準バッファに載せる。scratch 系バッファは filetype を意図的に集約する: 変更ファイル一覧 (sidebar) と `:Review list` のセッション一覧は共通の `review-list`、diff は `diff`。**buffer-local キーマップと extmark namespace はバッファ作成元 (buffer に持たせる `review_meta` テーブル) で判定して付ける** (FileType autocmd での分岐は使わない — filetype 集約と両立させるため)

## ドメインモデル

集約: Session (id, repo, mode, base/head, worktree?, files, comments)。値オブジェクト: Comment (file + new 側行 range + body + anchor + state)。

不変条件:

- INV-1 nvim インスタンス内でアクティブ (UI が開いている) セッションは高々 1 つ。セッション切替は必ず save → close を経る
- INV-2 コメントの `line..end_line` は追加時点でそのファイルの new 側差分範囲に収まる (outdated は漂移検証後に付く状態であり、範囲不変条件を満たさないコメントは作らない)
- INV-3 worktree の削除は `created_by_us=true` が記録された自前作成分のみ。ユーザー既存の worktree には一切触れない
- INV-4 コメント CRUD・viewed 切替の直後には必ずセッションがディスクへ永続化されている (MUST 2 の根拠。save 失敗時は例外としてメモリ保持 + WARN の上、次の状態変化時と close 時に再試行する。失敗期間のみが許された例外で、「メモリのみ」を常態としない)

## 既知の制約

- worktree 用の一時 ref を消し忘れると repo に残骸が積む。方針: worktree 作成は `git worktree add --detach` とし (branch checkout と競合しない)、fork PR の fetch でのみ `review-nvim/pr-<n>` ref を作る。close では worktree dir のみ削除 (ref は再開時の fetch 省略のために残す)、`:Review delete` とセッション不要時のみ ref も消す
- worktree 内に未コミット変更があると `git worktree remove` は失敗する (ユーザーの変更を黙って捨てられない)。close 時に検知して `--force` の可否をユーザーへ確認する
- kill 等で異常終了した経路では VimLeave の掃除が走らない。起動時に「記録上 open のセッションの worktree の実在」をスキャンし、残骸は通知の上で `git worktree prune` + ディレクトリを掃除する (MUST 2/3 の異常終了側の担保)
- fork PR の head は通常の branch ref として fetch されない。`git fetch <remote> refs/pull/<n>/head` で自前 ref を作る (ref 名に PR 番号を含めて衝突を防ぐ)
- 自前 ref の掃除には落とし穴がある (git 2.x 実測): fetch の宛先を短縮名 `review-nvim/pr-<n>` にすると **refs/heads/ 底下に保存**され、`git update-ref -d` は短縮名を "bad name" で拒否するため削除は保存フルネーム `refs/heads/review-nvim/pr-<n>` が必要 (`git show-ref --verify` も短縮名を解決しないので存在確認は `rev-parse --verify -q` を使う)。短縮名で消そうとすると動くように見えて孤児 ref が積む
- extmark の `virt_text` は `wrap` 表示と干渉する。diff バッファは `wrap=off` を強制する
- 巨大な差分 (1 ファイル 2000 行超) は描画と extmark が重い。標準の `foldexpr` で hunk / ファイルを畳めるようにするが自動折たたみはしない (v1 スコープ外。「やらないこと」参照)
- `git diff` 出力行から new 側ファイル行番号への変換は hunk ヘッダ `@@ -a,b +c,d @@` の `c` 起点の累計で決まる。**変換ロジックはパーサ (core/) の 1 箇所のみに置く** (パーサ外で行番号を独自計算して保存すると漂移バグの温床になる)
- `git diff` のファイルパス抽出は `--- ` / `+++ ` 行だけに依存できない: 空ファイルの新規・削除やモード変更のみではこれら 2 行自体が出力されず (git 2.55 実測)、空ファイル新規では hunk ヘッダ `@@` も無い。抽出順は `rename to` → `+++` 新パス → `---` 旧パス → `diff --git` 行の新側 でパーサ内のみに行う。hunk の行数が 1 のときヘッダは `,1` を省略 (`@@ -1 +1,5 @@` / `@@ -1,2 +1 @@`)、0 のときは明示 (`-0,0` / `+1,0`)。行数 1 省略を 0 と誤読すと hunk 境界と行番号がずれる
- `diff` filetype の構文強調と extmark は同じテキスト範囲で競合する可能性がある。コメントの下線等は独立 namespace と自前 highlight グループで表現する
- worktree・fetch のパス・権限挙動の実機検証は macOS / Linux に限られる (Windows は v1 の検証範囲外。パス連結は `vim.fs.joinpath` で吸収する)
- `nvim_create_user_command` の customlist 補完 API がバージョンで変わった: 0.10 系は `complete="customlist"` + `completion=fn`、0.13 系は `complete=fn` (`completion` は invalid key で呼び出し自体が失敗)。plugin/review.lua は pcall フォールバックで両対応している
- 既定の `vim.ui.input` は opts を `vim.fn.input` へそのまま渡す。したがって opts に Lua 関数を混ぜる形状 (`completion='customlist'` + `complete=fn`、または `completion='customlist'` 単体) は `input()` 側で E467 となり、既定実装は pcall でこれを吸収して `on_confirm(nil)` に変換するため**黙って何も起きないように見える** (0.13 nightly 実測)。opts へ渡せる補完は `input()` が受理する文字形式 `completion='customlist,{Vim script 関数名}'` のみ。head 選択ではグローバル関数 (`:function!`) を遅延定義し `luaeval` 経由で Lua 候補関数へ橋渡しする (`handlers/session.lua`。E2E phase3 が mock なしの実経路を pin)
- `vim.system` の spawn 失敗の取り扱いがバージョン差あり: bin 不存在はスケジュール内 error 扱いで on_exit が呼ばれず、cwd 不正は同期 error を throw する (0.13 nightly 実測)。git/cli.lua は実行前に `vim.fn.executable(bin)` で事前判定し、`system` 呼び出しを pcall で吸収して結果型に変換する (横断規約「手続きは例外を投げない」をアダプタ境界で守る)
- `git/cli` の既定の注入スタブ (`install_git` 系) は `on_exit` を**同期**で呼ぶため、spec では git 実行の「投入前 / 完了後」の順序が区別できない: worktree remove の完了を待ってから後処理 (delete の JSON+ref 削除など) をする契約は、同期スタブでは順序を実装と無関係に green になる (#6 delete-active の順序バグがこれで素抜けた)。完了順序を pin する spec は remove 等の on_exit を捕捉して手動で発火する遅延スタブを使うこと (`handlers/session_spec.lua` の `install_git_deferred_remove`)
- クリップボード provider の検出 Lua API (`clipboard.provider()`) は nvim 0.13-nightly 実機に存在しない (`require('clipboard')` / `require('vim.ui.clipboard')` ともにモジュール無し)。provider の実体は `g:clipboard` テーブルか legacy autoload `clipboard#copy` のみで、**provider 無しでも `setreg('+', ...)` / `getreg('+')` は内部選択に静かに成功する**ため、書いてから成否を判定できない (見た目は動く)。検出は書き込み前に `g:clipboard` / `exists('*clipboard#copy')` / 将来ビルド向けの `require('clipboard').provider()` の順で行い、無いは "0 のみ + WARN に退避する (`handlers/prompt.lua`)
- `setreg` の第 1 引数に List (`{'+', '*'}`) はレジスタ文字列として扱われ `Vim:E730: Using a List as a String` になる (0.13-nightly 実測)。複数レジスタへの同値書込は個別呼び出しで行う
- customlist 補完の関数には補完中の語だけでなく cmdline 全体と `cursorpos` が渡る。1 語目の候補返却に引数位置判定を混ぜると 2 語目以降で誤候補を返す (実測)。位置判定は語数 + 末尾空白で行う (`cursorpos` は語の末尾で発火する custom の性質上、末尾位置の判定には不要)。`input()` の customlist 側は Vim script 関数名文字形式のみ (上の E467 制約) で、2 系統があることを区別する
- cmdline の customlist 補完は同期 API なのでコールバックを待てない。同期実行を許可するのは cmdline 候補の出所 3 系統のみ: `:Review start` の ref 補完 (`run_sync` + TTL cache 成功 30s / 失敗 5s)、`:Review delete` の id 補完 (`rev-parse --show-toplevel` を `run_sync` → store は純 FS で同期、cache 無し = FS 读取のみ)、`:Review pr` の番号補完 (`gh pr list` を `run_sync`、PR 状態が動くので cache 無し)。いずれも `vim.system():wait(250ms)` 相当の待機上限内で、timeout は kill + 候補 0・無通知 — **それ以外の経路で `:wait()` によるブロッキングは依然禁止** (「API 一覧」の同期/非同期契約)。ref 補完候補は branches → tags (refname 昇順) で base 位置・head 位置・head 選択 UI の 3 経路同一源
- Neovim 標準 API に sha1 は無い (`vim.fn` にあるのは `sha256` のみ)。repo-hash の契約は sha1 先頭 16 桁であり、sha256 等に算法を差し換えると repo-hash ディレクトリ名が変わり既存セッションファイルが到達不能になる (見た目は動く)。sha1 は Neovim 組み込みの LuaJIT `bit` モジュールで `store/paths.lua` が実装している
- LuaJIT の `string.format('%x')` は負の int32 を 64bit 符号拡張の 16 桁で出力する (8 桁想定で書くと動くように見えてハッシュ値が壊れる)。32bit 演算結果を 16 進出力する直前は 0..2^32-1 の非負値へ正規化する (`store/paths.lua` の `u32`)
- headless テスト / E2E でのキー入力は `:normal` が唯一の安定経路: `nvim_input` / `feedkeys` の typeahead は `vim.wait` 中で消費されず (発火 observed 0 件)、`startinsert` も insert mode を維持しない (nvim 0.13 nightly 実測)。`:normal` 文字列内で error が出ると hit-enter prompt でハングするため、driver は pcall + `cquit` で正規化する
- `:normal` の視覚選択は分割投入が単位: `Vj` 移動と `c` 発火を 1 文字列にまとめると v-mapping が発火せず変更演算子が走る (選択行が消される)。正しくは `:normal Vj` → `:normal c` と分割する (実ユーザの逐次入力では発火することを実測で確認済み)。バインド済 `<CR>` も raw CR 文字で発火する
- 起動 `-c` コマンドの途中で `vim.wait` すると以降の起動シーケンスが進まず `VimEnter` が発火しない。起動後イベントに依存するスクリプト (E2E phase2 等) は `defer_fn` でイベントループ開始後へ逃がす
- Neovim に `BufWipedout` autocmd は無い (wipe でも `BufUnload` が走る)。バッファ付随の module state 掃除は `BufUnload` で受ける。`nvim_buf_set_extmark` の `end_col` に `-1` は不正 (`nvim_buf_add_highlight` 専用の記法。API は行末バイト数を明示する)

## 未解決の論点

なし (v1 スコープは「目的とスコープ」の MUST 4 点とやらないことで確定済み。MUST 2 の「起動後即復元」は notify + `:Review` 1 操作での復元と解釈して決定済み — 根拠は「アーキテクチャと技術選定」の起動時復元の行)
