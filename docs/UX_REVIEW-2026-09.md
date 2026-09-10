# review.nvim 実運用 UX レビュー (2026-09-10)

評価者: Neovim 重度ユーザー / 初回インストール視点
対象: `skanehira/review.nvim` @ 88a8189 (main)
情報源: README.md と `doc/review.txt` のみ (docs/design/ は未読)。トラブル調査のためにやむを得ず `lua/review/handlers/restore.lua`, `config.lua`, `ui/diffbuffer.lua`, `ui/help.lua`, `git/gh.lua`, `init.lua`, `plugin/review.lua` を参照した箇所は該当 finding に注記。
環境: NVIM v0.13.0-nightly+5209695 / git 2.55.0 / gh 2.97.0 (auth 済み) / macOS
起動: `nvim --clean --cmd "set rtp+=$REPO"` (+ 項目により `-c 'lua require("review").setup({...})'`)、TUI は tmux + `--listen` ソケット経由の `nvim_input()` で打鍵、状態は extmark / JSON / window 層から実測。途中 tmux send-keys の打ち込み事故 (確認プロンプトへのキー混入等) が複数回あり、誤読した所見は本文で訂正済み (削除 line 追跡・c2 消失疑い・e プリフィル欠如はいずれか評価作業側の誤読で、 plugin 上の不具合ではなかった)。

## 項目別結論一覧

| #  | 項目                   | 結論               |
| -- | ---------------------- | ------------------ |
| 1  | 認知負荷               | pass-with-findings |
| 2  | レビューフロー UI/UX   | pass-with-findings |
| 3  | キーバインド           | pass-with-findings |
| 4  | ヘルプ網羅性           | fail               |
| 5  | ゼロ設定スタート       | pass-with-findings |
| 6  | 失敗時のエラー         | pass-with-findings |
| 7  | 安全・可逆性           | pass-with-findings |
| 8  | 本体・他プラグイン共存 | pass-with-findings |
| 9  | 体感レスポンス         | pass               |
| 10 | 状態の見通し・復旧     | pass-with-findings |

**総合所感**: 核となるフロー (start → diff 閲覧 → c でコメント蓄積 → `:Review prompt` で AI へ) はゼロ設定で素直に回り、非同期・性能・保存・終了確認の作りは実直で高品質。一方で `:Review list` からの再開が静かに失敗することがあり (唯一の closed セッション入口として深刻)、リカバリ導線の端境目と、ヘルプの到達不能 (fresh clone で `:h` が E149) + ヘルプの外部文書参照が初回オンボーディングの足を引っ張る。「README だけ読むと騙される記述」(setup 省略可・worktree は PR のみ) が数点あるのが実態に近い。

---

## 1. 認知負荷 — pass-with-findings

**根拠 (実測)**
- 2 ペイン = 左 unified diff / 右ファイル一覧。README の「2 ペイン表示」どおり。side-by-side ではなく unified。
- `ft=diff` + 自前 highlight 併用 (`:filetype` 実測 `ft=diff`, extmark hl=ReviewDiffAdd/ReviewDiffDelete/ReviewDiffHunk) → 標準 diff syntax と extmark が二層で効き、削除/追加行の視認性は良い。
- コメント表示は行末 virt_text (` 💬 2` = 件数、単一時は本文プレビュー)。virt_lines は使われず本文は押しやられない。`nvim_buf_get_extmarks` で実測: `pos=6 virt={{ " 💬 2", "Comment" }}`。
- ファイル一覧は `[✓]` (viewed) + `M/A/D/R` + `+N -M` 付きで一目瞭然。rename は `R docs/release-notes.md +0 -0` と出るが旧名は不可視 (小さい)。
- 大きい新規ファイルは `+--2502 lines: +def big_module():…` の**折りたたみ 1 行**になった。この形式は docs 記載なし・展開方法なし。内容は `o` で実ファイルを開けば読める (代替路は発見可能だが導線がない)。

**findings**
- [L] sidebar が右・diff が左。GitHub Files changed (一覧左) に慣れた身には視線移動が逆。
- [M] 大量行ファイルの `+--N lines` 折りたたみ表示が help/README 皆無で、「これは何か」「どう開くか」が分からない (6)。
- [L] rename の旧パスが一覧から読めない。

## 2. レビューフロー — pass-with-findings

**根拠 (実測)**
- `c` → float (insert 即開き、title に `<CR> 確定 q 閉じる`) → 入力 → Esc → `<CR>` 確定までキーを減らせて回る。visual-line `Vj` + `c` で範囲コメント可 (line 4-5 / end_line 5 が JSON に正しい変換で保存)。
- sidebar で `j…<CR>` → 左 diff 切替 + 自動 viewed、`x` で viewed 手動トグル。編集→確認→追加のサイクルは概ね 3〜4 keystroke。
- 実測の不満点が 2 つ効く: **(a)** sidebar `<CR>` は「diff へ移動」の語感に反しフォーカスが sidebar に残る (直後に `c` を打つと無反応:E21 にもならず沈黙)。**(b)** 同一行に複数コメントがあると `e` (編集) が inputlist になる — `Type number and <Enter>: 1: [c1] ... 2: [c2] ...`。**この選択 UI は help/README 記載なし** (仕様として inputlist は vim 的だが、知らないユーザーは「e が謎のプロンプトを始めた」と感じる)。編集 float は本文を正しくプリフィルし、確定は全文置換で安全だった (旧本文保持/消滅なしの実証)。
- `y` (行コメントのプロンプト yank) / `d` (即削除) / `o` (実ファイル) すべて/help 記載どおり動作。`:Review prompt` → クリップボード (実測で prompt 全文が pbpaste に入った。clip provider 消失後は「"0 レジスタにのみ」とフォールバック通知 → 良)。
- AI 連携プロンプトの `@path#L4-L5` + 本文の書式は README 例と一致。

**findings**
- [M] sidebar `<CR>` 後フォーカスが移動しない (docs も「移動」と読める記述)。
- [M] 複数 comments 行での `e` が inputlist 選択になる挙動が無記載。
- [L] コメント本文は virt_text につき `/検索` 不能 (コメント内容を grep する vim 的運用ができない)。
- [L] `<C-w>o` や `:q` で diff ペインを畳むと単窓になり、そこからのレイアウト回復がその場になされない (`:Review` は「既に開いています」、sidebar `<CR>` は無反応。`q`→`:Review` が唯一の回復で、この導線が無記載)。

## 3. キーバインド — pass-with-findings

**根拠 (実測)**
- `c e d y o q <F1>` / sidebar `<CR> o x q` / list `<CR> q` — 覚えやすく、バッファで同じキーの意味が衝突しないことを `nvim_buf_get_keymap` と `:verbose nmap c` で確認 (全て buffer-local、nnoremap)。`<F1>` の help float は excellent (全バッファ + 入力 float の操作一覧)。
- override 実測: `setup({ keymaps = { diff = { add_comment = "gc" } } })` → diff buffer の keymap に `gc` があり `c` が消えていることを確認、`<F1>` 表示も `gc` に追従。**機能としては完璧**。
- ただし**その設定キー名 (`keymaps.diff.add_comment` 等) は help にも README にも存在しない**。`:h review-keymaps` は「config キーは docs/design/DESIGN.md を参照」と外部開発文書へ誘導するだけで、ユーザーが `:h` 内で完結できない (私は config.lua を読むまで正しい形を確定できなかった。結果的に合っていた = 実装が素直な証拠ではある)。

**findings**
- [M] keymaps override の書式 (構造・キー名) が help/README から到達不能。DESIGN.md 参照はユーザー経路として不発。

## 4. ヘルプ網羅性 — fail

**根拠 (実測)**
- **fresh clone では helptags が gitignore されているため `:h review` 系が全滅**: `E149: No help for review-keymaps / review-comment-input / review-api / review-setup / review-usage` (fresh clone を rtp に足した `nvim --clean` でそのまま再現。Neovim は plain `--cmd rtp+=` では自動生成しなかった。`:helptags ALL` を手で走らせて初めて全 tag が解決)。README の lazy スニペットだけではこの問題を踏む/踏まないが決まり、help を「README 経由で開く」導線が標準状態で壊れている。lazy.nvim の自動 helptags build は本評価の最小環境 (rtp+=) では検証できていない点に注記する。
- working copy の help 本文自体は質が高い (tag 構造・CONTENTS・入力 float の操作仕様まで網羅、F1 float と相互参照)。
- しかし help の要所が**ユーザーが読めます: 「同期/非同期契約の正本は DESIGN」、config キー一覧の参照先も DESIGN に置いたため、help から API・カスタマイズの最終情報に辿り着けない。README にも同じ契約の代替記載がない。
- help/README に載っていない挙動を実機で複数踏んだ:
  1. 同一 refs 组の `:Review start` での**既存セッション継承 confirm** `[y/N]` (README の start 説明には「差分を開く」としかなく、この confirm は flow の分岐点なのに無記載)
  2. head 省略時の `main.. (review head):` プロンプト (README は「補完」の説明で、この入力 UI の形に触れない)
  3. 大量行の `+--N lines` 折りたたみ表示
  4. 複数コメント行での `e` の inputlist
  5. worktree 生成の実際 (→6)
  6. `:Review` は open 専用の復元で、closed は list からしか辿れない (:Review list と q/close の状態遷移図がない — 「q で閉じた後、次に開く正しい操作は何か」が README/help から一意に決まらない)

**findings**
- [M] fresh clone で helptags なし → `:h review` が構造的に到達不能 (README 手順に `:helptags` が存在しない)
- [M] help の複数箇所が docs/design/DESIGN.md 参照で完結しない
- [M] start 時 confirm・head 省略 prompt・fold 表示・e の inputlist 等の主要 UI が無記載

## 5. ゼロ設定で始められるか — pass-with-findings

**根拠 (実測)**
- `nvim --clean` + rtp のみで `:Review start main feature` が即成功 (エラーなし、レイアウト・非同期取得ともに成立)。**「設定なしで動く」は実測で成立** ✓。
- README のコマンド一覧 (`start`/`pr`/`list`/`close`/`delete`/`prompt`) はすべて README のとおりに入力で動作。start の base/head <Tab> 補完も動作 (cmdline popup でブランチ候補)。
- 唯一の「つまずき」は help 側 (項目4) と、後述の setup 省略時の起動通知 (→6, ただし「動き始める」こと自体は成功)。

**findings**
- [M] README に「setup() は省略可能 (既定値で動作)」とあるが、**setup を呼ばないと起動時の継続セッション通知 (auto_notify_resume) が一切走らない** (実測: `--clean` + rtp だけ、status=open のセッションがある kill -9 相当終了後の起動でも `:messages` は完全に空。`require("review").setup({})` を加えると `review.nvim: main--feature のレビューが続けられます (:Review で復元)` が表示され、help/restore ロジックは setup 経由 VimEnter autocmd 登録が起点であることを確認 [ソース確認注記])。README の説明は省略不可項目を「省略可」と述べており、永続化という看板機能の一部が音もなく落ちる。
- [低] lazy スニペットに build/helptags 指定がない (項目4 と共通)。スニペットを打った新規ユーザーが `:h review` できるかはプラグインマネージャ任せの実態。

## 6. 失敗時のエラー — pass-with-findings

**根拠 (実際に壊して実測)**

| 入力 (わざと壊す)                                  | 実際の出力                                                                                                                                                  |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `:Review start nosuchbranch feature`               | `review.nvim: 'git <command> [<revision>...] -- [<file>...]'` (git usage 原文)                                                                              |
| `:Review start main nosuchtag`                     | 同上 (git usage 原文)                                                                                                                                       |
| `:Review start feature feature`                    | `review.nvim: 変更なし (feature..feature): レビュー対象がありません` ✓                                                                                      |
| `:Review start main samecontent` (内容同一 branch) | 変更なし系メッセージ ✓                                                                                                                                      |
| `:Review prompt` (active なし)                     | `review.nvim: レビュー進行中セッションがありません` ✓                                                                                                       |
| `:Review delete nope`                              | `review.nvim: セッション nope が見つかりません` ✓                                                                                                           |
| `:Review` (復元なし)                               | `復元できるセッションがありません。:Review start で開始してください` ✓                                                                                      |
| worktree 残骸時の start                            | `worktree を作成できません: <path>。同名の作業ツリーが残っている場合は git worktree remove で掃除してから再試行してください (fatal: ... already exists)` ✓✓ |
| 削除行にコメント不可                               | `その行にはコメントを付けられません` (理由 «deleted file» を言わず結果のみ)                                                                                 |
| 範囲選択に new 側行なし                            | `選択に new 側行がありません` ✓ 良                                                                                                                          |

`c` を無効行 (@@ 行 / 削除ファイル / 範囲外視選択) で叩くと notification は出るが、**msgpack 上の notify は数 keystroke で消える & 「なぜ」を言わない**ケースがある。gh 未ログイン文言は auth 済み環境のため実機不可 → ソースで確認: `gh 未ログインです。`gh auth login` を実行してください` — 原因 + 対処コマンド明示で良 (code-read 注記)。

**findings**
- [M] 存在しない ref (誤字) のエラーが git usage 原文の丸出しで、原因 (ブランチが存在しない) も対処 (`:Review start <Tab>` 補完/use 可能な ref 一覧の示唆) もゼロ。**最も頻出するユーザー誤入力の失敗応答が最悪** 。
- [L] 削除行不可メッセージに理由がない (「削除行のため」「変更後の行ではないため」等)。
- [L] `:Review pr 999999` (remote なしリポジトリ) = `review.nvim: no git remotes found` — 日本語 UI の中で英語一文、対処 (origin を足す/ GitHub repo で使う) を示さない。

## 7. 安全・可逆性 — pass-with-findings

**根拠 (実測)**
- コメント 0 件の `q` = 無確認で即終了 (help 記載どおり; 仕様として妥当 — 捨てるものがないので往復コストが低く、re-open は `:Review` 1 keystroke で済む)。
- 入力 float: 本文ありで `q` 1 回 = 閉じず (浮存確認)、続けて `q` = 破棄して閉じる — help の「2 秒以内」規定どおり。**`<Esc>` 連打では浮も本文も失わない** (Insert → Normal のみ) ことを float buffer の中身追跡で確認。
- `:Review close` = コメントあり時 `セッション main--feature を閉じますか？ [y/N]` + y で保存→窓を閉じる→**worktree 掃除** (git worktree list から plugin worktree が消えることを確認) → list で `closed` 表示。q と close の状態差分 (open 保存 vs closed 保存) も list から判別可能。
- `:Review delete` = 確認あり + comments/worktree 完全掃除 ✓。
- 衝突リスク: diff buffer で `d` は「即削除 (確認なし)」で help に仕様としてあるが、**vim 筋の `dd` (行削除) が「コメント 2 件連続消し」に化ける**。今回実際、コメントなし行で dd を叩き `その行のコメントはありません` ×2 が打鍵誤爆の形を物語った (コメントがあれば 2 件が消える)。q 二重押し破棄は「仕様として docs に明記・2 回必要・操作感として許容範囲」。
- 編集 float の空確定は元本文を保持 (消滅せず)。

**findings**
- [M] `dd` 誤爆でコメントが確認なしに即削除される経路 (docs には `d` = 即削除とあるが「行削除 dd と衝突」までは言及なし)。
- [M] 起動確認類が VimEnter/`input()` 待ち pending 中にキーが入力プロンプトへそのまま吸収される (標準 input() 仕様だが、`:Review start` 連続実行で「打鍵が消える」体験として現れる)。[L] と寄り度合いだが、prompt 中に他のコマンドを繋げて打つ操作感の案内がない。
- [L] 破壊はすべて元通り (コメント削除も anchor は残ったままだが復元 UI はない) = 「うっかり元に戻す」路自体は存在しない (コメント d → 元本文の復元の術がない。undo なし)。仕様として宣言済みだが comment 内容単位の loss-free な戻り口がなく、可逆性という一点では低〜中。

## 8. Neovim 本体・他プラグイン共存 — pass-with-findings

**根拠 (実測)**
- 起動痕跡 (別リポジトリの何もしない `nvim --clean` + rtp + setup): autocmd は名前付きグループ `review_nvim` の VimEnter のみ + scheme 用 Buf(?/ BufReadCmd 系 2 本が `*` wild 配下 [autocmd リストで確認])。`:autocmd User` は空 (余所事 User イベントを発火しない)。namespace は起動時に `review_comment/review_diff/review_list_grey` が作られるだけで害なし。custom User イベント (ReviewSessionOpened 等) は**存在せず** (rg で全 lua 確認 [ソース確認注記]) = 他の自動化フック点がないこと自体は共存上むしろ良品。
- `ft=diff` 同居: review buffer も `filetype=diff` で syntax と extmark highlight が二層共存、コメント extmark に syntax 起因の崩れなし。標準 `:checktime` は無音で成功、`<C-w>o` / `:q` は素直に効く (副作用としてレイアウト崩れ → 項目2 の finding)。
- 他プラグイン衝突 (`c` 等): plugin のマップは buffer-local + `nvim --clean` でグローバルな `c` は生成せず (`maparg("c","n")` = "" を、`maparg("c","n")` を別 buffer で確認)。「diff filetype で既存 `c` が」は本家の ftplugin が `c` をマップしないので --clean 環境で実測衝突なし (ただしプラグイン側は user autocmd に「自分のキーを後から上書きされない」順序契約を持たない = 一般の plugin (diffview 等) と同 condition の追加検証なし)。
- 標準操作の素直さ: `:q` できる、`<C-w>` 全部効く、挿入モードで困るものはない。

**findings**
- [L] `setup()` なしだと autocmd 自体が登録されない (起動通知が沈黙) = 項目5 と同一根。
- [L] 「plugin のキー設定 vs ユーザー/他 plugin の FileType autocmd」の優先順位付けは plain keymap なので、`ftplugin` で後負けすることがあるが、衝突時の案内がない (標準仕様どおりではある)。

## 9. 体感レスポンス/非同期性 — pass

**根拠 (実測)**
- 2502 行新規追加 (bigfeature) を `:Review start main bigfeature` → **open = 71ms** (hrtime 実測、headless でなく実 TUI の luafile 計測)。
- ファイル切替 (sidebar <CR> → async diff 取り込み) を 10 回 feedkeys ループ = 合計 5.03s = **1 回あたり実効 ≤0.5s** (意図的な sleep を含むので上は余裕を見た実測。打鍵ブロック・UI フリーズは観測されず)。
- git/gh 呼び出しはすべて非同期 (UI 開閉・notify で返る) — `:Review start` 実行直後も nvim は入力を吸収し続ける (`nvim_input` の返しが即時 = event loop が止まらないことの旁証)。
- `:checktime` 影響なし。spawn 失敗 (worktree already exists = 手元で意図的に作る) でも UI は死なず WARN 通知のみで生存を確認 [ソース確認注記: job フックは result 型で理由文字列を WARN する設計]。

**findings** なし (軽微: 超大きいファイルでも開かない以上 fold 表示あり = 項目1)。

## 10. 状態の見通し・復旧容易性 — pass-with-findings

**根拠 (実測)**
- kill -9 相当 (pane 直 kill) → 同 repo で `nvim --clean` + setup 起動 → **`review.nvim: main--feature のレビューが続けられます (:Review で復元)` 通知** ✓。2 件 open があるときは `2 件のレビューが続けられます (例: main--bigfeature)。` と複数形案内も正しい。そこから `:Review` 1 発で 2 ペイン・viewed・コメント (編集結果込み) が全復元 (JSON を disk 実測で照合)。
- `:Review list` の見せ方は良い: `main--feature  open  branch  main..feature  2 comments  2026-09-10 04:56` — id・状態・refs・件数・時刻が 1 行。
- **ただし** `:Review list` での `<CR>` 再開が flaky: **2 回、UI が開かずに [empty 窓] + sessions が残ったまま無音で停止** (別経路の `:Review`(open 状態) や `start` からの inherit[y] は同じ fetch_and_resume で毎回成功 = list 経由だけが失敗を観測)。3 回目の再現では UI は開いたが余剰の空窓が残った。winnr と bufname を全再現で実測記録済み。
- outdated 判定は機能する (anchor.line 削除 drift で c1/c2 → `state=outdated` を JSON 実測。`:Review prompt` は outdated を除外し「有効なコメントがありません」と明示)。軽微な drift (前後行の入れ替) では anchor が lenient に再特定 survive ✓。
- 難点: **outdated は UI から一切見えない**。diff 上の 💬 マークは active と同一で、sidebar にも印がなく、「なぜ outdated か」を表示する場所がない (README/help の outdated 言及は prompt 除外の一文のみ)。時刻表示も `04:56` (UTC) がそのまま — JST ユーザーには 9 時間ずれて見え、tz 表記もない。
- 状態遷移の全体像 (q→open / close→closed → `:Review` vs list の正しい入口) は help に図示がなく、実機で掴むまで「次に打つ正しい keys」の答えが分からない (q 後の `:Review` は ok、close 後の `:Review` は「復元できるセッションがありません。:Review start …」= **closed が :Review では復元できない仕様が未記載**)。

**findings**
- [H] `:Review list` → `<CR>` 再開が数回に一回、UI を開かず、sessions+空窓が残ったまま無音に停止する (別経路の同一セッション復元は全成功との対比で再現性を確認。closed セッション唯一の入口が壊れる = フロー阻塞)。
- [M] outdated の状態が UI から一切見えない (コメント位置は active と同じ 💬 マーク・理由表示なし)。
- [M] list 再開成功時にも余剰の空 [No Name] 窓が残ることがある (レイアウトが 2 窓に戻らず迷う。無害そうだが flaky  symptom の一態)。
- [L] list の時刻が tz 表記なし UTC で JST ユーザーには誤読 (ローカル時刻 or 明示表記にする)。
- [L] `:Review` は open のみ再開し closed は list 限定、という状態機械が docs にない (復元経路の「何を打てばいいか」の指針がない)。

---

## findings 集約表 (severity 順)

| ID  | 項目   | 内容 (期待 vs 実際)                                                                                                                                                          | 再現手順 (最小)                                                                                                                                                                                                    | 改善案                                                                                                                                                                  |
| --- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1  | H / 10 | list <CR> 再開が沈黙し空窓が残ることがある (期待: どの入口でも同じ復元)                                                                                                      | `:Review start <a> <b>` → `:Review close` (y) → `:Review list → <CR>` を 1 ユーザーセッションで繰り返し (3 回に 1〜2 回失敗 observed、`winnr("$")`=1 or [No Name] 残存 & msgs 増えず) → 3 窓目に空 Name を引きずる | list→fetch_and_resume のエラー/非進行を必ず通知。`vim.wait`/schedule デッドロックを resume_session で追跡。成功時は空窓を回収                                           |
| F2  | M / 4  | fresh clone で `:h review*` が E149 (help を呼べる前提の README が成立しない)                                                                                                | 空ディレクトリで `git clone`; `nvim --clean --cmd 'set rtp+=<clone>'` ; `:h review-keymaps` → E149。`:helptags ALL` で解消                                                                                         | README に `build = ":helptags TOPATH"` を足す (lazy)/doc/tags を co commits or helptags 自動生成手順を help usage に明記                                                |
| F3  | M / 5  | `setup()` を呼ばないと起動通知 (auto_notify_resume) が完全に黙る (期待: README の「setup 省略可」)                                                                           | `nvim --clean --cmd set rtp+=<repo>` (setup せず) で open セッションのある repo を kill -9 → 起動 → msgs なし。`-c 'lua require("review").setup({})'` を足すと通知でる                                             | plugin/ で setup なり default 起動 scan を登録する or README を「setup 推奨 / 永続化通知には setup 必須」に改述                                                         |
| F4  | M / 6  | 未存在 ref で git usage 原文の丸投げ (期待: 「この base/head はありません。Tab で補完可」)                                                                                   | `:Review start nosuchbranch feature<CR>` → `git <command> ...` 通知                                                                                                                                                | stderr の "not a valid object name" を翻訳し候補一覧 or 補完導線を促す文言に                                                                                            |
| F5  | M / 1  | `+--N lines` 折りたたみ (large insert file) が docs 皆無で開き方も不明 (期待: 差分を読める/折りたたみ意味の表示)                                                             | 2500 行新規追加 commit へ `:Review start main big` → diff pane `+--2502 lines: ...` の 1 行のみ; 展開キーなし                                                                                                      | help/README に「折りたたみ時は `o` で実ファイルを読むのが正」を明記 (or zfold/expansion を実装)                                                                         |
| F6  | M / 3  | keymaps override の設定名が help から到達不能 (DESIGN.md 送り)                                                                                                               | `:h review-setup` / `:h review-keymaps` → 実キー名 (add_comment 等) 記載なし → config.lua を読むまで書けない (gc へ rename は動作実証済み)                                                                         | defaults (config.lua の keymaps デフォルト表) を help に転記 (diff/sidebar/sessionlist + 各 action key)                                                                 |
| F7  | M / 10 | outdated が UI から一切見えない/理由不明 + prompt から黙って除外される (active と同一表示) (期待: 位置が揺れたなら位置・理由が見える)                                        | コメント後に drifted commit (`banner` 行を消す) へ resume → 💬 マークは同じ/「なぜ」ゼロ表示 (JSON で state=outdated) + `:Review prompt` は「有効なコメントがありません」                                          | 💬 マークに outdated の色/文字を付与 (`💬⚠ outdated`)、`e` で理由 anchor 表示、list/diff legend を help に                                                              |
| F8  | M / 2  | `<C-y>` insert 確定後、diff バッファが insert モード残留する (期待: Esc→<CR> と同じ normal)                                                                                  | diff で `c` → 本文 → insert のまま `<C-y>` 確定 → `mode()` = `i` が diff buf 上                                                                                                                                    | 確定経路で `stopinsert` を忘れたもの。Esc→<CR> 経路は clean                                                                                                             |
| F9  | M / 7  | `d`(即削除・確認なし) と vim 筋 `dd` が衝突し、comment が連続削除されうる                                                                                                    | コメントなし行で `dd` → 「その行のコメントはありません」×2 = d 命令 2 回発火を実測 (コメントがあれば 2 件消える挙動)。無音                                                                                         | `d` 単体は即削除の docs はあるが「行削除 dd を潰す」と help/README に警告 or dd/2 秒以内 double delete は undo-able バケツを持つ                                        |
| F10 | M      | worktree が branch review でも作られる (README は「PR を指定した場合は…」) + `o` は worktree 内**実編集可**で、branch review でユーザーは repo 実作業 files を見ていると思う | 通常 `:Review start <a> <b>` 後、`worktree.path` が session JSON に付き、`o` で worktree 内 `<file>` が mod=1 で開きプロンプトのパスも worktree 絶対パス                                                           | docs を実装に合わせて「branch でも worktree を作り、`o` と prompt は worktree 指向と読む」に更新 or branch モードで prompt の `@` を repo 相対パスに変える設定/既定変更 |
| F11 | M      | `e` の複数 comments 選択が inputlist で docs にない (期待: help に e 操作フロー)                                                                                             | 同一行に c を 2 回 → `e` → `Type number and <Enter>: 1: [c1]…`                                                                                                                                                     | help の review-keymaps-diff「e」項に列挙選択の説明を 1 行                                                                                                               |
| F12 | M      | sidebar `<CR>` = 「diff へ移動」のはらが focus が sidebar に残る + その窓では c/d/e/q が別物 (期待と実態が 1 打ずれる)                                                       | start → `5j<CR>` → (そのまま) `c` → 反応なし                                                                                                                                                                       | <CR> で focus を diff に送る or docs に「sidebar にとどまる」を明記                                                                                                     |
| F13 | M      | `:Review start` の same refs confirm [y/N] の存在と「pending 中に他キーを混ぜると cmd に混入」が docs にない                                                                 | `:Review start <a> <b>` 既存 open 状態 → confirm + `y<CR>` が必要 (y だけだと Enter 待ち standard input)。docs の「head 省略時は補完」記述の `:Review` の項が start の項に「差分を開く」しかない                   | README の USAGE 列挙 + review-usage に confirm を 1 行記載                                                                                                              |
| F14 | L      | コメント text が virt_text なので `/検索` 不能 (期待: 打ったキーワードが jump できる)                                                                                        | 本文 `magic` → `/magic<CR>` → E486                                                                                                                                                                                 | search 不能を docs に注記 (or search 透過拡張)                                                                                                                          |
| F15 | L      | 終了系プロンプト `[y/N]:` は y だけ押しても反応せず、後コマンドが入力側に混入する                                                                                            | 確認 prompt 中に `y` だけ remote で打つ → cmd 残存 / 次のコマンドが混入                                                                                                                                            | 標準 input 仕様と了解しつつ、「y/Enter で続行/取り消し」UI に寄せるか、混入しにくい `vim.ui.select` へ移行                                                              |
| F16 | L      | float title にターゲット行なし (期待: 「どの行へのコメントか」の表示)                                                                                                        | c で float → title ` Comment  <CR> 確定  q 閉じる` のみ                                                                                                                                                            | title に `L4-L5 /src/app.py` 相当を足す (低コスト)                                                                                                                      |
| F17 | L      | list のタイムスタンプが tz 表記なし UTC (2026-09-10 04:56 @ JST)                                                                                                             | list → `04:56` (実際の更新 13:56 JST)                                                                                                                                                                              | local time or `UTC` 明示                                                                                                                                                |
| F18 | L      | 単窓レイアウト (<C-w>o/:q 後) で sidebar `<CR>` が無反応 (window が開かなくなる)                                                                                             | <C-w>o → `5j<CR>` → 無反応 & 無音                                                                                                                                                                                  | 無窓時は split で diff を復元する                                                                                                                                       |
| F19 | L      | pr remote-less の文言英語一文 `no git remotes found`                                                                                                                         | test repo で `:Review pr 42`                                                                                                                                                                                       | 日本語化+対処                                                                                                                                                           |
| F20 | L      | 削除対象行にコメント時の理由 (deleted file) を messages だけ示す・msgpack notify のみで視認困難                                                                              | deleted file の `@` 行で c → 数秒後に「その行にはコメントを付けられません」                                                                                                                                        | 「この行は差分 head 側に存在しません」等 + echo に回す                                                                                                                  |

集計: **high 1 / medium 12 / low 7** (F1–F20。F15 は仕様妥当だが操作案内不在。F20 は理由記載まで)。

## クリーンアップ報告

- 評価用リポジトリ `/tmp/review-ux-LdfqUD` (mktemp) ・`/tmp/review-nvim-eval/fresh-clone` は削除済み。tmux サーバ/評価 nvim プロセスは終了済み。
- プラグインが data dir に作ったもの (`~/.local/share/nvim/review.nvim/sessions/7d9ac0097490439f`, `worktrees/7d9ac0097490439f`, `worktrees/74359e4914b92e60` (空), git worktree 登録 main--bigfeature) は削除済み (セッションデータ本体は plugin の `:Review delete` / `git worktree remove` で消しながら進めた)。ユーザーの実クリップボードは評価前に保存し復元した。
- **`$REPO` は `git status --porcelain` 为空・working tree clean (このレポートの docs/UX_REVIEW-2026-09.md のみ untracked として追加。add/commit しない)** — 追跡ファイルへの変更・git checkout/stash なし。
