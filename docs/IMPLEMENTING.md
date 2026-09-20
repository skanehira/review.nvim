# review.nvim で新規機能を実装するときの知識 (2026-09 の UI 改訂で実証済み)

設計の正本は `docs/design/DESIGN.md` と `docs/design/features/*.md`、作業規律は
`AGENTS.md`。この文書は **そのどれにも載っていない「実装・検証のやり方」** を、
2026-09 の diffview 風 UI 改訂 (#14〜#19 / fix #26) で実行して確かめた事実だけで書く。
コードの現在の契約自体をここには書かない (正本を参照)。

---

## 1. 機能追加の置き場所を決める

レイヤー依存は `handlers → (git|store|core)` と `ui → handlers` の向きのみ
(AGENTS.md「レイヤー」)。UI 機能を足すときは 3 点セットに分けて考える:

| 関心事 | 置き場 | 実例 (issue 数) |
| --- | --- | --- |
| 状態の読み書き・git 実行・フロー調停 | `handlers/<feature>.lua` + 同所的 `*_spec.lua` | リフレッシュ = `session.lua` 末尾 (15) |
| 画面の組み立て (窓・buffer・hl) | `ui/<name>.lua` (新規 module として分離可) | 3 窓 = `ui/windows.lua` / 純ロジック = `ui/treelist.lua` (16/17) |
| ユーザーへ出す文言 | handlers の直 notify ではなく文言を spec に全文 pin | 縮退 INFO «head の状態はチェックアウトされていません…» (14) |

純ロジック (tree 組み立て、path 判定、行生成) は `ui/` に置いても **vim API を触らない
module に分離する** と unit test が速く安定する (`ui/treelist.lua` 276 行 → spec 14 件、
nvim を起動せずに通る)。

## 2. キーを追加するときの実務 (AGENTS.md 同期義務の裏付け)

同期義務 7 箇所のうち、実測で詰まった点を先に潰す手順:

1. `config.lua` defaults + `config_spec.lua` の**リテラル期待 2 箇所を先に赤くする**
   (defaults 全体比較と M.defaults 不変保護の両方)。ここで RED が見えないと
   後で「キー名 typo が黙って通る」
2. wiring: `ui/keygate.lua` install 集合 (実ファイル窓) と `ui/filepanel.lua`
   paint_keymaps (panel) の**両方に**登録箇所がある。片方だけだと panel で押せない
3. `ui/help.lua` SECTIONS + `help_spec` の完全一致行。**説明文が他の節と同一文中だと
   全削除しても test が緑になる** (#18 r1 low→high 相当。節間で説明文を区別できる
   文言にすること)
4. `doc/review.txt` の KEYMAPS 全体表は「既定値の表」であって操作説明ではない。
   表と該当節の両方を更新し、`:helptags` 後に関係 tag が全て解決することを実測
   (`:help <tag>` で確認、doc/tags は gitignore)
5. 旧キーの撤去は `rg -n "']d'|'\[d'|'S'"` のように **source 中の文字列リテラルの
   実形式**に合わせた pattern で、撤去前にヒット (= 検出能力の実証) → 撤去後 0 を
   commit msg に残す。pattern が実形式と食い違うと空振り green になる

## 3. 窓レイアウトを触るとき (#16 で壊しかけた契約)

- **窓の役割は id でなく内容から導く** (`ui/windows.lua` role_of: panel =
  `review://sidebar/` バッファ一致、head = `w:review_key_gate` + 表示 buf 一致、
  base = `w:review_base_gate` + 表示 buf 一致、scratch は `review_meta.scratch`
  の fallback)。id が生きていても `:buffer` で中身が
  差し替わる drift で誤作動したことがある (UX_REVIEW F1 系)
- 新しい tabpage を作るときは **専有 tab にする** (ユーザー窓と同 tab にすると
  窓 diff の相乗りで base と user file が diff し出す) + `t<tab>` で開き直せること
- 実ファイル窓を `:edit` で開く経路 (`:Review` 開始や head 窓の張替) は、**ユーザーがそのファイルを
  既に開いていても同一 buffer を再利用する**。その場合も keygate install と
  owned_bufs 登録は必須 (再利用だけ install を省むと c/e/d が全滅。#16 r1 high で実測)
- `BufWritePost` に later 載せる: 窓 diff は `:w` 単体では再計算されない (PoC 実測)。
  リフレッシュは `session.lua` が自動で行うので、窓を作るとき autocmd を増やさない。
  head 窓で `:w` すると自動で diff 再計算まで走る
- **窓再利用での set_buf 張替は古い buf が diff group に残積する** (group は全体
  8 buffer 上限で、9 個目に E96 «Cannot diff more than 8 buffers»。実運用報告で判明)。
  base/head 窓を使い回す `windows.bind` は `set_buf` 前に現窓 buf へ `:diffoff` して
  刈る (窓そのものの close/tabclose は残積しない = 張替経路限定)。窓 diff を使う
  新しい窓種族 (3 個以上の比較窓など) を足すときは同じ刈り込みを設けること
- head バッファの extmark 残骸: `ui/commentmarks` の clear_tracked /
  `ui/keygate.uninstall` は **close・tab 消滅・縮退切り替えの全経路**で必要。
  「窓を閉じれば消える」に依赖しない (レビュー窓以外の同 buffer 窓にも見える仕様)

## 4. real buffer に何か描くときの既知の API 事実

すべて PoC (FEASIBILITY) か本改訂で実測したバージョン横断の事実:

| 事実 | 影響 | 根拠 |
| --- | --- | --- |
| `nvim_win_set_keymap` / window-local keymap API は**存在しない** (keymap API は global 3 + buffer 3 の 6 個のみ) | 窓限定キーは buffer-local 張込 + 押下時点の window role gate + 張込前衝突検出の 3 点セットで実現 | PoC head-window-key-gate |
| `nvim_buf_get_keymap` の返り値は **ユーザーが `vim.keymap.set` 関数形で張ったキーには `rhs` フィールド自体が無い** (`callback` に関数)。`m.rhs` を無検証に index すると crash | 衝突検出自体が crash して鍵が全滅する。`type(m.rhs) ~= 'string'` を「衝突」として true を返す | #16 r1 high (実再現) |
| `nvim_tabpage_is_valid` は TabClosed 発火時点で **0.10.0: true / 0.13: false**。`nvim_list_tabpages()` に閉じた tab が無いのは両版共通 | tab 消滅フックの帰属判定は list 現存有無で導く (is_valid 依据は 0.10 で黙って発火しない) | #26 (probe 実測 + CI 失敗) |
| file panel の名前/アイコン着色で **synID (vim syntax) を写す方式は採用しない** (0.12.x で syntax engine 参照が review 窓状態を壊し sequential full run を落とす。50a0c08 として実装→revert 済、#28 参照)。正 = **nvim-web-devicons と treesitter のどちらが存在しても `get_icon` の 2 返り値の hl group 名 (DevIcon*) を参照するだけ** = plugin 側で `nvim_set_hl` を増やさず syntax engine を触らない (diffview `hl.get_file_icon` 実装) |
| `virt_text` / `virt_lines` の chunk は常に `{ {text, hl} }` ネスト (フラット `{text, hl}` は "expected Array, got String")。表示要素 (件数 eol + 行下スレッド) は群につき 1 extmark、範囲コメントの下線は別 mark に分ける (spec は index でなく details で mark を識別 — 同一位置 tie は残る) | AGENTS.md 再掲。新しい行内表示を作るときそのまま適用 | spec 実測 |
| `extmark opts` の follow 系は **`right_gravity` (boolean)**。`gravity = 'right'` は無効引数 | 編集時の mark 追従契約 | PoC |
| `nvim --server --remote-expr` は 0.13 で editor.lua shim 経由: **list index が 0 base**、`getbufline('<bufname>')` は `[]` (同一状態で) | remote-expr 検証は buffer 特定=index、内容=luaeval+`nvim_buf_get_lines` で書く。無音の false PASS を防ぐ | issue #18 実測 |
| expr keymap → `vim.schedule` dispatch は環境によって «次の打鍵まで反映されない» 遅延が出る (ユーザー設定で `<leader>e` が 1 打鍵遅延) | **窓切替系 (focus_panel / toggle_panel) は非 expr の同期関数 mapping** にする (textlock 外なので buffer 変更も安全)。検証は callback を直接呼び spy 通知が即時に載ることを assert (schedule drain を挟まない) | keygate_spec 同期発火テスト・2026-09 実測 |
| portable 0.10.0 バイナリでホストの `nvim/site/parser/lua.so` (0.13 用 ABI) を拾うと `:edit *.lua` で treesitter ABI mismatch / no parser error | ローカル互換検証の失敗が実バグと区別不能になる。検証は CI (クリーン runner) を ground truth にし、ローカル 0.10.0 は rtp から parser dir を除去した init で走る (`--noplugin` + `runtimepath:remove(...)`) | #26 検証時の実測 |

CI matrix は **nvim v0.10.0 と stable の両方**で走る。手元 nightly で green でも
`gh run watch` するまでは merge 完了にしない (AGENTS.md の gates)。

## 5. 検証の書き方 (#14〜#19 で機能したパターン)

- **RED は「旧実装で実際に落ちる assertion」**。常時 PASS する検出能力ゼロ test は
  書かない・削除しない (検出能力を保ったまま置換する)。テストを消す変更 (module 削除)
  は、生き残る契約を新 module の spec に移植する (#16 で unified 撤廃時に 4+3 pin を移植)
- `cli._set_system` は**応答キューの消化順 = 仕様の一部**。`table.concat` join で
  「git をどの順で叩いたか」を pin する (`git diff:<repo>` 形式のラベル)。
  worktree の remove 同期/非同期の競合系は `install_git_deferred_remove`
- 永続化は**ディスクの JSON を読んで**判定 (memory 状態のアサートは不可。INV-4)
- 自動リアクション (BufWritePost・in-flight まとめ) は**発火タイミングを inject 可能に
  `_set_now` / `_set_diffupdate` で切り、呼び出し順序を spy で検証**する。
  「保存すべきときに呼ばれる」+「会员外で呼ばれない」の陽性/陰性両 pin が必要
  (陰性側の欠落は #15/#17 で指摘済み、pending フォロー)
- UI の振る舞い test は `tabnew` 隔離 tab + `review://*` buffer の前後フック掃除
  (既存 use_env / use_bufs パターン)。操作 contract の判定は**押下時点のバッファ内容
  比較**(TextChanged 系は headless で発火しない)
- 変異検査 (old→new の置換が test を落とすか) は review-impl がスクリプト
  (`~/.claude/scripts/mutate-check.ts`) で実施済み。実装側も同じ検出自習を
  「old 実装のコード片を残す→失敗を見る→消す」で回すと速い
- e2e (`scripts/e2e.sh`) の新 scenario: `tests/e2e/<name>.lua` にマーカー
  (`E2E-XX=値`) を標準出力し、`run <name> "$TMP"` の後 **shell 側で `grep -q` する**。
  fixture は mktemp + exit trap。nvim 側に assert を置くと失敗理由が log の中で
  見づらくなるので、期待値は shell のメッセージにする
- 実 PTY でしか取れない契約 (窓限定キーの isolation / insert 残留) は
  `tmux + nvim --listen + --remote-expr` で実測し、**手順と結果を commit msg** に
  (AGENTS.md の約束。スクリプトは /tmp でよいが手順をコミットに転記する)

## 6. worktree / 直列化 (#14 で新設契約)

- worktree 登録変更 (add/remove/prune) は `session.lua` の `wt_with_lock` /
  `wt_unlock` で**同一 dir path なら直列**。ロック保持側は全終了経路 (成功・失敗・skip)
  で unlock を呼ぶ責務 — 呼ばないと待機側が死ぬ (AGENTS.md 実測教訓)
- 「add 成功後の中断」を全経路埋めること: 0 差分・diff 失敗のような
  **セッション記録が存在しない段階の中断**は掃除しないと孤児 worktree が残り、
  起動 scan (記録 open の session 基準) では回収不能 (#16 r1/r2 medium の実物)
- branch モードは worktree を作らない (作業ツリー基準のため)。**削除してよいのは
  `created_by_us=true` かつ mode が記録されたものだけ** (INV-3)

## 7. issue を複数立てて並列実装するとき (#15/#16 の失態)

- 同じ main 領域 (例 `handlers/session.lua`) を触る issue を**同一依存レベルで並列に
  流すと、後から merge する側が rebase で相手の追加差分を丸ごと取りこぼす**
  (#16 が theirs 採択でリフレッシュ実装を失い、docs 記述も消えた。移植 patch +
  docs 再掲の追加 fix が必要になった)
- 対策: 同一ファイルを触る可能性がある issue は**依存で直列にするか、issue 本文に
  「相方の契約を消したら merge 不可」を明記する**。rebase 衝突解決で
  `checkout --theirs` 全体採用をする前に、ours 側の追加差分を `git diff base..origin/main`
  で取り出し、移植が要るか検証する (検証 = make check + e2e + 旧 contract の test が
  生きていることの grep)
- reviewer にはラウンド番号 (`previous_findings_path`) を渡す。r2 で contract が
  別の箇所へ転移していないか検査される

## 8. 文書規律 (AGENTS.md の補足として実測したもの)

- doc/README/help の文言は**現行契約のみ**。「以前は X だったが変更」は書かない
- 日本語文書のローカル誤字・混入 (「会 viên」のようなIME ゾーン事故) は
  機械チェック (`LANG=C rg '[ぁ-んァ-ン]*[a-zA-Z]{3,}'`)
- help 内の参照は `:helptags` 生成後に全 tag 解決を確認 (doc/tags は commit しない)
- `docs/design/features/*.md` を変えたら DESIGN.md の決定表・キー表・既知の制約と
  食い違っていないか reviewer に照合させる (fresh context でないと見落とす)
- 保留になったレビュー指摘 (medium など merge 後に回すもの) は
  `docs/pending-review/issue-<N>.html` (チェックボックス 1 項 = 1 finding、
  data-severity/data-category 属性付き) に置き、issue 完了コメントから辿れるようにする
