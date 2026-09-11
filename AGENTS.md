# AGENTS.md — review.nvim で作業するエージェント向け指針

## プロジェクト概要

Neovim で GitHub Files changed 風にブランチ/PR 差分をレビューし、コメントを蓄積して
AI エージェント向けプロンプトとして出力するプラグイン。

- **runtime 依存ゼロ** (Neovim 標準 API のみ、>= 0.10)。テストに plenary.nvim のみ必要
- セッションは `stdpath("data")/review.nvim/` 配下に JSON 永続化し、異常終了後も復元
- 設計の**正本は `docs/design/DESIGN.md`**(横断規約・API 一覧・決定・既知の制約)と
  `docs/design/features/*.md`(機能別詳細)。実装挙動に迷ったら先にここを引く
- ユーザー向け情報は `README.md` と `doc/review.txt`。両者の同期義務は下の節

### レイヤー (依存はこの向きのみ)

```
plugin/review.lua  :Review コマンド + VimEnter 起動 scan のみ (薄い entry)
core/   純ロジック (diff parse / anchor / comment / result 型)。UI・FS 副作用なし
git/    git / gh / worktree 実行アダプタ (外界 DI: _set_system / _set_executable)
store/  永続化・path 契約 (repo hash、session JSON、corrupt 退避)
handlers/  フロー調停 (session / comments / restore / pr / sessions_list / prompt /
         health / usermsg=エラー文言翻訳)
ui/     描画・窓・float (diffbuffer / list / input / commentview / help / layout)
```

ui は git/store を直接叩かず handlers を経由する。

## 検証ゲート (commit 前に必ず緑)

```bash
export PLENARY_PATH=$HOME/.local/share/nvim/review-nvim-deps/plenary   # ローカル Clone 位置
make check        # test + lint(luacheck) + format(stylua) + plugin-check。これがゲート
make test-file FILE=lua/review/handlers/session_spec.lua   # 1 ファイル
make e2e          # 実 headless nvim + 実 git の golden path (tests/e2e/phase1.lua ほか)
```

- CI (GitHub Actions) = nvim **v0.10.0 / stable** の matrix + e2e + luacheck + stylua。
  push 後は `gh run watch` で green を確認する
- **lint warning 0・test green を確認してから commit** (過去に warning 混入 push の事故あり)
- 実 PTY でしか検証できない契約 (insert-mode 残留など) は unit test に置かず、
  tmux + `nvim --listen` の `--remote-expr` で実測し commit message に手順を残す

## テスト規律 (TDD)

- RED → GREEN → REFACTOR。**RED とは「旧実装で実際に落ちる assertion」のこと**。
  何があっても PASS する検出能力ゼロの test は書かない・削除する
  - 例: headless の `:normal` は insert が継続せず `mode()` を返さない =
    「insert 残留しない」系の assert を unit に置くと無効
- git/gh 系は `cli._set_system` の**応答キュー**で駆動する。呼び出し順が仕様の一部
  (アサート対象)。`worktree remove` の同期/非同期の区別 (競合テスト) は
  `install_git_deferred_remove` を使う
- 永続化の検証はメモリ状態ではなく**ディスクの JSON を読んで**判定する (INV-4)
- UI 系 spec は `tabnew` で隔離 tab に状態.tab を保ち、`review://*` バッファを
  前後フックで掃除する既存パターン (use_env) に従う
- spec はソースと同ディレクトリの `*_spec.lua`。例外: `plugin/review.lua` の spec は
  `lua/review/plugin_spec.lua` (plugin/ 直下に置くと rtp 起動時に自動 source される)

## UI/窓の契約 (歴代の壊れ方と対策。詳細は docs/design/features/diff-review.md)

- **レイアウトは sidebar 左 30 列 + diff 右**。`vsplit` の新窓位置は splitright に
 依存するので `wincmd L` / `wincmd H` で寄せる。sidebar へ `set_buf` した**後**に
vsplit すると新窓が sidebar buf を継承して drift 誤検出 → **先に vsplit**
- **窓の役割は id ではなく内容から導く**(`diff_win_ok` / `sidebar_display_win`)。
  id が生きていても `:buffer` 等で見ている中身が差し替わる drift がある
  (UX review F1 の真因)
- sidebar buf は `bufhidden=wipe` = 表示窓が閉じると消える。参照側は invalid 時に
  render し直す (focus_sidebar のガード参照)
- 操作系 contract の判定は**押下時点のバッファ内容比較**で行う (TextChanged 系は
  updatetime 遅延で headless で発火しない = 使わない)
- 入力 float: insert `<CR>`=改行 / Normal `<CR>`=確定 / `q` (本文なし=閉じる・
  本文あり=arming 2 回で破棄) / `<C-y>`=insert 確定エイリアス / `<Esc>`=Normal 復帰だけ。
  終端経路は必ず stopinsert してから閉じる
- コメント本文の表示は行下スレッド (extmark の virt_lines = buffer 行を占有
  しない = 行番号写像不変)。見出し eol と同一 anchors にmark を二つ作ると
  取得順が不定になるので **1 extmark に virt_text と virt_lines を併合**する。
  virt_text/virt_lines の chunk は常に `{ {text, hl} }` のネスト構造 ({text,hl}
  フラットは "expected Array, got String" になる — 実測の教訓)
- コメント削除 `d`・破棄 `q` は arming 二重押し (同じ対象・同じ行・2 秒内)。
  `dd` で複数消えないことが契約
- headless テストでは `cmdheight` の関係で notify が hit-enter を起こし、後続キーが
  呑まれる。打鍵検証では `<CR>` を挟んで開放する

## worktree / 永続化の契約 (docs/design/features/pr-worktree.md)

- worktree dir = `stdpath(data)/review.nvim/worktrees/<repo-hash>/<slug>`。
  削除対象は `created_by_us=true` の自前分のみ (INV-3)
- **同一 dir path の worktree 登録変更 (add / remove / prune) は
  `session.lua` の `wt_with_lock` / `wt_unlock` で直列化する**。ロック保持側は
  全終了経路 (成功・失敗・skip) で unlock を呼ぶ責務。呼ばないと待機側が死ぬ。
  根拠: q close の remove 最中に start が add すると git が管理dir を二重登録し
  (`main--x` + `main--x1`)、以後 remove が "does not point back" で固定破壊する
- close の remove 失敗 = WARN + 二段目自己修復 (`prune` + 自前 dir 再帰削除)。
  delete 側は dir まで消せなければ**中止**して JSON を残す (起動 scan が回収できる状態を保つ)
- `:Review` は open のみ復元、closed は `:Review list` からのみ。起動スキャンと
  継続通知は plugin/review.lua が登録する (setup 省略でも走る — README の約束)

## API / キー変更時の docs 同期義務

キー・API を変えたら**次を全部**そろえる (どれか 1 箇所欠けると「help に無いから
押せない」UX 破綻になる。実測レビューで何度も指摘された点):

1. `lua/review/config.lua` defaults + `config_spec.lua` の**リテラル期待 2 箇所**
2. キーマップ wiring (ui/diffbuffer.lua / ui/list.lua) — rhs は未実装関数を
   弾く dangling 検出テストがある
3. `<F1>` help float (`ui/help.lua` SECTIONS + `help_spec` の完全一致行)
4. `doc/review.txt`: 既定値の全体表 (KEYMAPS) / 該当節 / CONTENTS の tag
   (新規 tag は `:helptags` で生成確認。doc/tags は committed しない = gitignored)
5. `README.md` (コマンド解説・キー表・操作 paragraph)
6. 設計正本: `docs/design/DESIGN.md`「デフォルトキーマップ」+ 該当 features/*.md の
   操作表・エッジケース表

doc 文体: **現行契約のみ**を書く (「以前は X だったが変更」等の過程記録を入れない)。
日本語文書の漢字混入 (廃/废、後/后 など) と誤字は機械チェックする。help 内の参照は
`:helptags` 後に全 tag が解決できることも確認する。

## 既知の制約 (DESIGN.md「既知の制約」の抜粋 + 本会話での追加教訓)

- `vim.wait` を起動 `-c` 内で使うと VimEnter が発火しない (E2E は defer_fn で逃がす)
- キー投入は `:normal` のみ安定 (`nvim_input` / `feedkeys` は headless で不安定)。
  `<CR>` は `:normal` 目的なら `nvim_replace_termcodes(.., true, true, true)`、
  `nvim_win_call` 内なら `cr=false`
- `vim.ui.input` の opts に Lua 関数を混ぜると既定 provider で失敗する
  (cmdline 補完は customlist + 文字形式の関数名)
- 実 git の stderr は `fatal:` 主行 + usage 続き。**主メッセージ行を取る**
  (末尾 1 行採取は usage を出してしまう。cli.lua の stderr_main_line)
- 文字列 hash は sha1 先頭 16 桁の独自実装 (API にない)。`string.format('%x')` の
  負数 64bit 符号拡張に注意
- luacheck ゲートあり: モジュールレベルの `anchor` 等と同名 local を関数内で作ると
  shadowing warning (`anchor_win` / `sb_anchor` のように避ける)

## ブランチ / commit / push

- main 直 push 流 (PR 運用ではない)。commit は Conventional Commit、本文に変更理由・
  リスク・検証根拠 (実行したコマンドと結果) を書く
- 構造的変更 (リネーム・移動) と挙動変更は別に切る
- push 後は `gh run list/watch` で CI green を確認して完了とする

## 参照

- `docs/UX_REVIEW-2026-09.md`: 実運用 UX レビュー (F1-F20 と再現手順)。UI 操作系を
  触る前に該当項目を確認し、新たな体験上の発見は同じ形式 (再現手順 + 実測 + severity)
  で追記してよい
- `docs/design/DESIGN.md`「リポジトリの形・開発コマンド」も参照
