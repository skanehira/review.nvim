#!/usr/bin/env bash
# review.nvim シナリオ E2E (DESIGN.md「開発・検証コマンド」E2E /
# docs/design/features/{diff-review,persistence-restore}.md「テスト方針」)。
#
# golden path: fixture repo (main / feature, 複数ファイル・複数 hunk) で
# headless nvim を起動 -> :Review start -> 専有 tab 3 窓 (panel│base│head) +
# tcd==repo + head 実ファイル -> head 窓 c キーでコメント (extmark 実ファイル) ->
# panel <CR> 切替 -> head 窓実ファイル (編集可) -> 視覚選択で
# range コメント -> y で "0 に @path#L.. + 本文 ->
# :Review prompt で見出し + 全件全文一致 (issue #7) -> 正常終了 ->
# 別プロセスで VimEnter notify -> :Review 復元 -> 本文・行位置・viewed が元の
# 状態と一致 -> q (close 確認 y) -> tab 消滅 + 実ファイル extmark 残骸 0 +
# status=closed。
# phase3: :Review start <base> 1 引数 -> head 省略 = rev-parse --abbrev-ref HEAD
# による自動採用・保存 (入力 UI なし) を実 git で pin (issue #14 の開始契約)。
# phase5: head 窓での編集 :write -> BufWritePost 自動リフレッシュで ±カウント更新
# + anchor 検証 outdated 0 (行補正) + y の保存基準 prompt、未保存の二重基準、
# 手動 R (issue #15/#19 未コミット反映契約)。新規 XDG data dir で開始確認を踏ませず
# に走る。
# head 解決フロー (issue #19): 専用 fixture REPO2 で switch (y -> 実 git switch +
# 実ファイル窓) / scratch 縮退 (n -> 両窓 review:// scratch + INFO) / 縮退再開始
# (継承時も再評価) / 復元時の head 解決再評価 (scratch <-> 実窓の切り替わりを
# 跨プロセスで pin)。tabclose シナリオは :tabclose -> status=open 保存 + extmark
# 残骸 0。tabswitch シナリオは review tab を離れると global winbar 式が戻り
# (空ヘッダー行なし)、戻ると再適用されることを pin する。
# E2E は clipboard provider 無しで走る (クリップボード非依存、"0 レジスタ比較のみ)。
# phase6: 横断コメント一覧 (issue #31) — 2 ファイルにコメント -> <leader>c ->
# 一覧 2 行 -> <CR> ジャンプ -> 一覧へ戻り d 二重押し -> 行消滅 + 実ディスク JSON 1 件
# (comment-list「テスト方針」e2e golden path)。
#
# 契約: 毎回 mktemp の一意ディレクトリに fixture repo と XDG_DATA_HOME を作り、
# 終了時に掃除する (直列/並列どちらでも競合しない)。失敗は exit 1。
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REPO="$WORK/repo"
DATA="$WORK/xdg"
LOG="$WORK/notify.log"
mkdir -p "$REPO" "$DATA"
: >"$LOG"

# --- fixture git repo -----------------------------------------------
git init -q -b main "$REPO"
git -C "$REPO" config user.email e2e@example.com
git -C "$REPO" config user.name e2e

# a.lua: 60 行のファイルで距離の離れた 2 変更 (multi-hunk) を作る
python3 - "$REPO/a.lua" <<'PYEOF'
import sys
with open(sys.argv[1], 'w') as f:
    for i in range(1, 61):
        f.write(f'line{i}\n')
PYEOF
printf 'base\n' >"$REPO/b.lua"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
git -C "$REPO" checkout -qb feature
python3 - "$REPO/a.lua" <<'PYEOF'
import sys
rows = open(sys.argv[1]).read().splitlines()
assert rows[2] == 'line3' and rows[59] == 'line60'
rows[2] = 'LINE3-changed'
rows[59] = 'LINE60-changed'
open(sys.argv[1], 'w').write('\n'.join(rows) + '\n')
PYEOF
printf 'feature addition\nsecond line\n' >"$REPO/b.lua"
mkdir -p "$REPO/src/deep"
printf 'src work\n' >"$REPO/src/deep/new.lua"
git -C "$REPO" add -A
git -C "$REPO" commit -qm feature
# phase3 で自動採用 head とは別の ref (feature と同一ツリー)。補完候補にも出る。
git -C "$REPO" branch hotfix

# --- phase 1: 起動 -> コメント -> 窓移動 (<S-Tab>/]F/[F/<leader>e) -> 正常終了 -------
run_nvim() {
  local script="$1"
  ( cd "$REPO" && XDG_DATA_HOME="$DATA" REVIEW_E2E_LOG="$LOG" \
      nvim --headless --noplugin -u "$REPO_ROOT/tests/e2e_init.lua" -c "luafile $script" )
}

OUT1=$(mktemp "$WORK/phase1.out.XXXXXX")
if ! run_nvim "$REPO_ROOT/tests/e2e/phase1.lua" >"$OUT1" 2>&1; then
  cat "$OUT1" >&2
  echo "e2e: phase 1 nvim 終了コード非ゼロ" >&2
  exit 1
fi
cat "$OUT1" | tee -a "$WORK/e2e-report.txt"
S1=$(grep -oE 'E2E-S1 body=.* line=[0-9]+' "$OUT1" || true)
[ -n "$S1" ] || { echo "e2e: phase1 の E2E-S1 行が無い (assert 不合格)" >&2; exit 1; }
grep -q 'E2E-S1 body=use a map here' "$OUT1" || { echo 'e2e: phase1 本文不一致' >&2; exit 1; }
grep -q 'E2E-L1 wins=3 tcd=repo' "$OUT1" || {
  echo 'e2e: phase1 3 窓開通/tcd==repo の golden path assert が無い' >&2
  exit 1
}
grep -q 'E2E-W1 winbar=true' "$OUT1" || { echo 'e2e: phase1 winbar chrome (w: のみ) が入っていない' >&2; exit 1; }
grep -q 'E2E-T1 thread=eol+virtlines' "$OUT1" || { echo 'e2e: コメント行下スレッド (件数 eol + virt_lines 本文) が表示されない' >&2; exit 1; }
grep -q 'E2E-O1 fileview=real-editable' "$OUT1" || { echo 'e2e: phase1 head 窓が実ファイル (編集可) でない' >&2; exit 1; }
grep -q 'E2E-M1 S-Tab=prev' "$OUT1" || {
  echo 'e2e: phase1 `<S-Tab>` 前ファイル移動が効かない (最終キー表 #18)' >&2
  exit 1
}
grep -qF 'E2E-M2 ]F=last' "$OUT1" || {
  echo 'e2e: phase1 `]F` 最後のファイル移動が効かない' >&2
  exit 1
}
grep -qF 'E2E-M3 [F=first' "$OUT1" || {
  echo 'e2e: phase1 `[F` 最初のファイル移動が効かない' >&2
  exit 1
}
grep -q 'E2E-M4 Tab=next' "$OUT1" || {
  echo 'e2e: phase1 `<Tab>` 次のファイル移動が効かない' >&2
  exit 1
}
grep -q 'E2E-V1 viewwin=scratch' "$OUT1" || { echo 'e2e: phase1 <S-Tab>/]F/[F/i/<leader>e 一連 (閲覧 float が開かない等) に失敗' >&2; exit 1; }
# prompt yank (issue #7): y で "0 = @path#L.. + 本文、:Review prompt = 全文一致
grep -q 'E2E-Y1 yank=@path-range+body' "$OUT1" || {
  echo 'e2e: phase1 y で "0 に range コメントのプロンプトが入らない' >&2
  exit 1
}
grep -q 'E2E-P1 prompt=exact' "$OUT1" || {
  echo 'e2e: :Review prompt の "0 が見出し + 2 件全量 (id 昇順) と全文一致しない' >&2
  exit 1
}
# file panel ツリー表示 golden path (issue #17): ヘッダ・連結 chain dir・i トグル・折込
grep -q 'E2E-TR1 tree=header+chain' "$OUT1" || {
  echo 'e2e: panel tree ヘッダ/単一 child 連結 («Showing changes for:» と src/deep/) が壊れた' >&2
  exit 1
}
grep -q 'E2E-TR2 i=list' "$OUT1" || {
  echo 'e2e: `i` で list フラット表示に切り替わらない (または "i" が効かない)' >&2
  exit 1
}
grep -q 'E2E-TR3 i=tree' "$OUT1" || {
  echo 'e2e: `i` 再押下で tree 表示に戻らない' >&2
  exit 1
}
grep -q 'E2E-TR4 fold=toggled' "$OUT1" || {
  echo 'e2e: dir 行 <CR> の折り畳み/展開が効かない' >&2
  exit 1
}
# provider 無し退路 (ai-prompt.md): "0 コピーは成功し WARN が出ている (= 退路を観測)
grep -q 'クリップボード provider がありません' "$LOG" || {
  echo 'e2e: clipboard provider 無し退路の WARN がログに無い' >&2
  exit 1
}

# 保存されたセッション JSON が実ディスクに存在し本文を含む (MUST 2/INV-4)
SESSION_JSON=$(find "$DATA" -path '*review.nvim/sessions/*/main--feature.json' | head -1)
[ -n "$SESSION_JSON" ] || { echo 'e2e: セッション JSON が存在しない' >&2; exit 1; }
grep -q '"body":"use a map here"' "$SESSION_JSON" || { echo 'e2e: 保存 JSON に本文が無い' >&2; exit 1; }
grep -q '"body":"prefer early return"' "$SESSION_JSON" || {
  echo 'e2e: range コメント (視覚選択 -> c) が保存 JSON に無い' >&2
  exit 1
}

# --- phase 2: 新プロセスで VimEnter notify -> :Review 復元 -----------
OUT2=$(mktemp "$WORK/phase2.out.XXXXXX")
if ! run_nvim "$REPO_ROOT/tests/e2e/phase2.lua" >"$OUT2" 2>&1; then
  cat "$OUT2" >&2
  echo "e2e: phase 2 nvim 終了コード非ゼロ" >&2
  exit 1
fi
cat "$OUT2" | tee -a "$WORK/e2e-report.txt"
# 起動時 notify がログに出ていること (grep = 陽性検出)
grep -q 'review.nvim: main--feature のレビューが続けられます' "$LOG" || {
  echo 'e2e: VimEnter 継続 notify がログに無い' >&2
  exit 1
}
S2=$(grep -oE 'E2E-S2 line=[0-9]+' "$OUT2" || true)
[ -n "$S2" ] || { echo 'e2e: phase2 の E2E-S2 行が無い' >&2; exit 1; }

# 行位置の一致 (跨プロセス照合: diff は同一 = 補正も漂移もないこと)
L1=${S1##*line=}
L2=${S2##*line=}
if [ "$L1" != "$L2" ]; then
  echo "e2e: 復元後行位置不一致 phase1=$L1 phase2=$L2" >&2
  exit 1
fi
grep -q 'mark=1(a=0)' "$OUT2" || { echo 'e2e: 完了マーク復元なし (b.lua=1 / a.lua=0 の期待)' >&2; exit 1; }
grep -q 'E2E-VW x=mark' "$OUT1" || { echo 'e2e: phase1 の x マーク付与に失敗' >&2; exit 1; }
# q (close) 経路の掃除: レビュー tab 消滅 + 実ファイル extmark 残骸 0 + closed
grep -q 'E2E-Q1 cleared=1 tabclosed=1 status=closed' "$OUT2" || {
  echo 'e2e: phase2 q close で tab 消滅 / extmark clear / status=closed が確認できない' >&2
  exit 1
}

# --- phase 3: head 省略 (1 引数) -> 実 vim.ui.input で選択 -> 開始 ---------
OUT3=$(mktemp "$WORK/phase3.out.XXXXXX")
if ! run_nvim "$REPO_ROOT/tests/e2e/phase3.lua" >"$OUT3" 2>&1; then
  cat "$OUT3" >&2
  echo "e2e: phase 3 nvim 終了コード非ゼロ" >&2
  exit 1
fi
cat "$OUT3" | tee -a "$WORK/e2e-report.txt"
grep -q 'E2E-S3 head=hotfix' "$OUT3" || { echo 'e2e: head 省略自動採用経路が開始に到達しない' >&2; exit 1; }

# --- phase 4: :Review start の cmdline ref 補完 (実 git for-each-ref 同期) ---
# customlist の呼び出し側 (review.complete) を実 repo で検証。popup 描画自体は
# headless では不安定なため手動確認 (既知の制約のキー投入契約に従う)。
OUT4=$(mktemp "$WORK/phase4.out.XXXXXX")
if ! run_nvim "$REPO_ROOT/tests/e2e/phase4.lua" >"$OUT4" 2>&1; then
  cat "$OUT4" >&2
  echo "e2e: phase 4 nvim 終了コード非ゼロ" >&2
  exit 1
fi
cat "$OUT4" | tee -a "$WORK/e2e-report.txt"
grep -q 'E2E-C1 completion=feature,hotfix,main' "$OUT4" || {
  echo 'e2e: :Review start ref 補完が実 git 候補 (branches 昇順) と一致しない' >&2
  exit 1
}
grep -q 'E2E-C2 delete_ids=main--e2e-del' "$OUT4" || {
  echo 'e2e: :Review delete id 補完が store 実データと一致しない' >&2
  exit 1
}

# --- phase 5: 保存時リフレッシュ (編集 :w -> ±カウント自動更新) --------------
# 新規 XDG data dir (保存セッション 0 -> 継承確認なし) で main..feature を開始し、
# b.lua を編集保存 -> sidebar の +2 -1 が +3 -1 になるまで wait_for。E2E-R1 が
# 陽性マーカー (unit の応答キューでは観測できない「実 git + 実 BufWritePost」の
# 接線を pin する)。
D_REFRESH="$WORK/d-refresh"
mkdir -p "$D_REFRESH"
OUT5=$(mktemp "$WORK/phase5.out.XXXXXX")
if ! ( cd "$REPO" && XDG_DATA_HOME="$D_REFRESH" REVIEW_E2E_LOG="$LOG" \
    nvim --headless --noplugin -u "$REPO_ROOT/tests/e2e_init.lua" \
    -c "luafile $REPO_ROOT/tests/e2e/phase5.lua" ) >"$OUT5" 2>&1; then
  cat "$OUT5" >&2
  echo "e2e: phase 5 nvim 終了コード非ゼロ" >&2
  exit 1
fi
cat "$OUT5" | tee -a "$WORK/e2e-report.txt"
grep -q 'E2E-R1 counts=updated' "$OUT5" || {
  echo 'e2e: 保存後の自動リフレッシュで ±カウントが変わらない (E2E-R1 欠落)' >&2
  exit 1
}
# 保存時リフレッシュは anchor 検証 (直近パース結果基準) も同時走らせる:
# outdated 0 + 行補正 (E2E-U1) と、その補正位置基準の y prompt (E2E-U2)。
# U2 の期待行が U1 の行補正に依存しているため、検証が no-op (保存行據え置き)
# なら U2 の grep が落ちる構成 (相互に対照)。
grep -q 'E2E-U1 anchor=active+corrected' "$OUT5" || {
  echo 'e2e: 保存時リフレッシュの anchor 検証 (active + 行補正) が観測できない (E2E-U1 欠落)' >&2
  exit 1
}
grep -q 'E2E-U2 yank=saved-baseline' "$OUT5" || {
  echo 'e2e: y の "0 が保存 (リフレッシュ済み) 基準の prompt でない (E2E-U2 欠落)' >&2
  exit 1
}
# 手動 R キー (#18 登録): BufWritePost を通さない再取得経路が効く
grep -q 'E2E-R2 manual-refresh=ok' "$OUT5" || {
  echo 'e2e: head 窓 R での手動リフレッシュが ±カウントに反映されない (E2E-R2 欠落)' >&2
  exit 1
}

# --- phase 6: 横断コメント一覧の削除 (issue #31 comment-list golden path) ------
# 専有 XDG data dir (保存セッション 0) で 2 ファイルにコメント -> head 窓
# <leader>c -> 一覧 2 行 -> <CR> ジャンプ -> 一覧へ戻り d 二重押し -> 行消滅 +
# カーソル位置 + 実ディスク JSON 1 件 (INV-4)。E2E-CL3 が一覧追随の陽性マーカー。
D_CLIST="$WORK/d-clist"
mkdir -p "$D_CLIST"
OUT6=$(mktemp "$WORK/phase6.out.XXXXXX")
if ! ( cd "$REPO" && XDG_DATA_HOME="$D_CLIST" REVIEW_E2E_LOG="$LOG" \
    nvim --headless --noplugin -u "$REPO_ROOT/tests/e2e_init.lua" \
    -c "luafile $REPO_ROOT/tests/e2e/phase6.lua" ) >"$OUT6" 2>&1; then
  cat "$OUT6" >&2
  echo "e2e: phase 6 nvim 終了コード非ゼロ" >&2
  exit 1
fi
cat "$OUT6" | tee -a "$WORK/e2e-report.txt"
grep -q 'E2E-CL1 rows=2' "$OUT6" || {
  echo 'e2e: <leader>c の一覧が 2 行にならない (E2E-CL1 欠落)' >&2
  exit 1
}
grep -q 'E2E-CL2 jump=a.lua:3' "$OUT6" || {
  echo 'e2e: 一覧 <CR> が記録行 a.lua:3 へジャンプしない (E2E-CL2 欠落)' >&2
  exit 1
}
grep -q 'E2E-CL3 deleted rows=1 json=1 cursor=1' "$OUT6" || {
  echo 'e2e: d 二重押しの削除で行消滅 / カーソル / ディスク JSON が契約と違う (E2E-CL3 欠落)' >&2
  exit 1
}

# --- head 解決フロー: switch / scratch 縮退 / 縮退再開始 / 復元再評価 (issue #19) --
# 専用 fixture REPO2 (checkout=main、feature が a.lua 変更 + b.lua 追加で先行)。
# y 応答の switch は実 checkout を動かすので、各シナリオ driver が自分で
# checkout を正規化する (単発実行しても決定的)。データ dir / notify ログも
# シナリオごとに分離し、縮退再開始と復元再評価だけプロセス間で共有する。
REPO2="$WORK/repo2"
mkdir -p "$REPO2"
git init -q -b main "$REPO2"
git -C "$REPO2" config user.email e2e@example.com
git -C "$REPO2" config user.name e2e
printf 'one\n' >"$REPO2/a.lua"
git -C "$REPO2" add -A
git -C "$REPO2" commit -qm headres-base
git -C "$REPO2" checkout -qb feature
printf 'ONE changed\n' >"$REPO2/a.lua"
printf 'added\n' >"$REPO2/b.lua"
git -C "$REPO2" add -A
git -C "$REPO2" commit -qm headres-feature
git -C "$REPO2" checkout -q main

run_headres() { # $1=script $2=data dir $3=log $4..=env 追加
  local script="$1" data="$2" log="$3"
  shift 3
  mkdir -p "$data"
  : >"$log"
  ( cd "$REPO2" && env XDG_DATA_HOME="$data" REVIEW_E2E_LOG="$log" "$@" \
      nvim --headless --noplugin -u "$REPO_ROOT/tests/e2e_init.lua" -c "luafile $script" )
}
headres_fail() { # $1=out file, $2=label
  cat "$1" >&2
  echo "e2e: $2 失敗" >&2
  exit 1
}

# (switch) head 明示 + y -> 実 git switch 実行・通常経路 (実ファイル窓)。
OUTSW=$(mktemp "$WORK/headres-switch.out.XXXXXX")
run_headres "$REPO_ROOT/tests/e2e/switch.lua" "$WORK/d-switch" "$WORK/headres-switch.log" \
  >"$OUTSW" 2>&1 || headres_fail "$OUTSW" "head 解決 switch"
grep -q 'E2E-SW1 switch=real' "$OUTSW" || headres_fail "$OUTSW" 'switch (E2E-SW1 欠落)'
[ "$(git -C "$REPO2" rev-parse --abbrev-ref HEAD)" = "feature" ] || {
  echo 'e2e: switch シナリオ後に HEAD が feature でない (git switch が走っていない)' >&2
  exit 1
}
if grep -q '読み取り専用 scratch でレビューします' "$WORK/headres-switch.log"; then
  echo 'e2e: switch 承諾経路で scratch 縮退 INFO が出た (縮退してはいけない)' >&2
  exit 1
fi

# (縮退) 同上 n 応答 -> 両窓 review:// scratch + INFO 文言 (head 表示名は ref 名)。
OUTDG=$(mktemp "$WORK/headres-degrade.out.XXXXXX")
run_headres "$REPO_ROOT/tests/e2e/degrade.lua" "$WORK/d-degrade" "$WORK/headres-degrade.log" \
  >"$OUTDG" 2>&1 || headres_fail "$OUTDG" "head 解決 縮退"
grep -q 'E2E-DG1 scratch-pair' "$OUTDG" || headres_fail "$OUTDG" '縮退 (E2E-DG1 欠落)'
grep -q 'head の状態はチェックアウトされていません。読み取り専用 scratch でレビューします' \
  "$WORK/headres-degrade.log" || {
  echo 'e2e: 縮退 INFO 文言がログに出ない (diff-review「開始」2 の確定文言)' >&2
  exit 1
}

# (縮退再開始) main checkout のまま同一 refs 組を再開始 -> 継承 + head 解決再評価
# -> 再び両窓 scratch + INFO (セッションは 1 組 1 件・status=open)。
OUTDR1=$(mktemp "$WORK/headres-dr1.out.XXXXXX")
run_headres "$REPO_ROOT/tests/e2e/degrade_restart.lua" "$WORK/d-degrade-restart" \
  "$WORK/headres-dr1.log" REVIEW_E2E_STEP=1 >"$OUTDR1" 2>&1 \
  || headres_fail "$OUTDR1" "縮退再開始 STEP=1"
grep -q 'E2E-DR1 degraded=once' "$OUTDR1" || headres_fail "$OUTDR1" '縮退再開始 STEP=1'
OUTDR2=$(mktemp "$WORK/headres-dr2.out.XXXXXX")
run_headres "$REPO_ROOT/tests/e2e/degrade_restart.lua" "$WORK/d-degrade-restart" \
  "$WORK/headres-dr2.log" REVIEW_E2E_STEP=2 >"$OUTDR2" 2>&1 \
  || headres_fail "$OUTDR2" "縮退再開始 STEP=2"
grep -q 'E2E-DR2 restart=degraded' "$OUTDR2" || headres_fail "$OUTDR2" '縮退再開始 STEP=2'
grep -q 'head の状態はチェックアウトされていません。読み取り専用 scratch でレビューします' \
  "$WORK/headres-dr2.log" || {
  echo 'e2e: 縮退再開始 (継承) 時の INFO 文言が 2 回目ログに出ない' >&2
  exit 1
}

# (復元 re-eval) 通常開始 -> (checkout を寄せて) 復元で scratch / 実ファイルへ
# 切り替わることを跨プロセスで pin (MUST 2。位置・viewed 一致は phase1+phase2)。
OUTRR1=$(mktemp "$WORK/headres-rr1.out.XXXXXX")
run_headres "$REPO_ROOT/tests/e2e/restore_reeval.lua" "$WORK/d-restore-reeval" \
  "$WORK/headres-rr1.log" REVIEW_E2E_RMODE=real-start >"$OUTRR1" 2>&1 \
  || headres_fail "$OUTRR1" "復元再評価 real-start"
grep -q 'E2E-RR1 mode=real-start' "$OUTRR1" || headres_fail "$OUTRR1" '復元再評価 real-start'
OUTRR2=$(mktemp "$WORK/headres-rr2.out.XXXXXX")
run_headres "$REPO_ROOT/tests/e2e/restore_reeval.lua" "$WORK/d-restore-reeval" \
  "$WORK/headres-rr2.log" REVIEW_E2E_RMODE=scratch-restore >"$OUTRR2" 2>&1 \
  || headres_fail "$OUTRR2" "復元再評価 scratch-restore"
grep -q 'E2E-RR2 mode=scratch-restore' "$OUTRR2" || headres_fail "$OUTRR2" '復元再評価 scratch-restore'
grep -q 'head の状態はチェックアウトされていません。読み取り専用 scratch でレビューします' \
  "$WORK/headres-rr2.log" || {
  echo 'e2e: 復元時の scratch 縮退 INFO 文言がログに出ない (MUST 2 証跡)' >&2
  exit 1
}
OUTRR3=$(mktemp "$WORK/headres-rr3.out.XXXXXX")
run_headres "$REPO_ROOT/tests/e2e/restore_reeval.lua" "$WORK/d-restore-reeval" \
  "$WORK/headres-rr3.log" REVIEW_E2E_RMODE=real-restore >"$OUTRR3" 2>&1 \
  || headres_fail "$OUTRR3" "復元再評価 real-restore"
grep -q 'E2E-RR3 mode=real-restore' "$OUTRR3" || headres_fail "$OUTRR3" '復元再評価 real-restore'
if grep -q '読み取り専用 scratch でレビューします' "$WORK/headres-rr3.log"; then
  echo 'e2e: real-restore (checkout==head) で縮退 INFO が出た (誤縮退)' >&2
  exit 1
fi

# (tab 消滅) :tabclose -> status=open 保存 + extmark namespace 残骸 0 + INFO 文言。
# 主 fixture の main..feature/feature checkout を使う (データ dir は専有)。
OUTTB=$(mktemp "$WORK/tabclose.out.XXXXXX")
mkdir -p "$WORK/d-tabclose"
: >"$WORK/tabclose.log"
if ! ( cd "$REPO" && env XDG_DATA_HOME="$WORK/d-tabclose" REVIEW_E2E_LOG="$WORK/tabclose.log" \
    nvim --headless --noplugin -u "$REPO_ROOT/tests/e2e_init.lua" \
    -c "luafile $REPO_ROOT/tests/e2e/tabclose.lua" ) >"$OUTTB" 2>&1; then
  cat "$OUTTB" >&2
  echo "e2e: tab 消滅シナリオ失敗" >&2
  exit 1
fi
cat "$OUTTB" | tee -a "$WORK/e2e-report.txt"
grep -q 'E2E-TB1 status=open extmarks=0 winbar=restored' "$OUTTB" || {
  echo 'e2e: :tabclose 後の status=open 保存 / extmark 残骸 0 が確認できない' >&2
  exit 1
}
grep -q 'レビュー tab を閉じました (セッションは保存済み' "$WORK/tabclose.log" || {
  echo 'e2e: TabClosed の INFO 文言がログに出ない' >&2
  exit 1
}

# (tab 切替) review tab -> 無関係な user tab で global winbar 式を戻す (式が非空だと
# 空評価でも窓に 1 行確保される)。主 fixture の main..feature / feature checkout を
# 使い、データ dir は専有する。
OUTSW=$(mktemp "$WORK/tabswitch.out.XXXXXX")
mkdir -p "$WORK/d-tabswitch"
: >"$WORK/tabswitch.log"
if ! ( cd "$REPO" && env XDG_DATA_HOME="$WORK/d-tabswitch" REVIEW_E2E_LOG="$WORK/tabswitch.log" \
    nvim --headless --noplugin -u "$REPO_ROOT/tests/e2e_init.lua" \
    -c "luafile $REPO_ROOT/tests/e2e/tabswitch.lua" ) >"$OUTSW" 2>&1; then
  cat "$OUTSW" >&2
  echo "e2e: tab 切替シナリオ失敗" >&2
  exit 1
fi
cat "$OUTSW" | tee -a "$WORK/e2e-report.txt"
grep -q 'E2E-TSW1 away=cleared back=restored vars=kept' "$OUTSW" || {
  echo 'e2e: review 外 tab で winbar 式が戻らない / 戻ると再適用されない' >&2
  exit 1
}

# --- PR mode (issue #6: worktree / gh スタブ + 実 git) --------------------
# pr-worktree.md「テスト方針」E2E + DoD シナリオ 1〜5。gh は PATH スタブ、
# origin はローカル bare (refs/pull/7/head を置く = fork PR 模擬)。
PRDIR="$WORK/pr"
ORIGIN="$PRDIR/origin.git"
CLONE="$PRDIR/repo"
BIN="$WORK/bin"
mkdir -p "$PRDIR" "$BIN"

cat >"$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# gh スタブ: pr view --json のみ fixture JSON を返す (DESIGN.md「gh / git 実行」)。
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  cat "${GH_STUB_PRVIEW:?}"
  exit 0
fi
echo "gh-e2e-stub: pr view 以外未対応: $*" >&2
exit 1
GHEOF
chmod +x "$BIN/gh"

git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
git -C "$CLONE" config user.email e2e@example.com
git -C "$CLONE" config user.name e2e
printf 'base content\n' >"$CLONE/a.lua"
git -C "$CLONE" add -A
git -C "$CLONE" commit -qm base
git -C "$CLONE" push -q origin main
# PR head 相当: topic を refs/pull/7/head に置き、同一 repo branch は消す (fork 模擬)
git -C "$CLONE" checkout -qb topic
printf 'PR HEAD content\nsecond\n' >"$CLONE/a.lua"
git -C "$CLONE" add -A
git -C "$CLONE" commit -qm prhead
git -C "$CLONE" push -q origin 'topic:refs/pull/7/head'
git -C "$CLONE" checkout -q main
git -C "$CLONE" branch -D topic >/dev/null

REPO_PR=$(git -C "$CLONE" rev-parse --show-toplevel) # macOS /var symlink は実パスに正規化
SHA16() {
  python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])' "$1"
}
WT_OF() {
  echo "$1/nvim/review.nvim/worktrees/$(SHA16 "$REPO_PR")/pr-7"
}
JSON_OF() {
  echo "$1/nvim/review.nvim/sessions/$(SHA16 "$REPO_PR")/pr-7.json"
}
cat >"$PRDIR/pr.json" <<JSONEOF
{"number":7,"title":"E2E widget pr","baseRefName":"main","headRefName":"topic","headRepositoryOwner":{"login":"forkguy"},"url":"https://github.com/e2e/demo/pull/7","state":"OPEN"}
JSONEOF

run_pr() { # $1=scenario lua, $2=data dir; 各自の notify.log を置く
  local script="$1" data="$2"
  mkdir -p "$data"
  local plog="$WORK/pr-${script##*/}.log"
  : >"$plog"
  ( cd "$REPO_PR" && XDG_DATA_HOME="$data" PATH="$BIN:$PATH" GH_STUB_PRVIEW="$PRDIR/pr.json" \
      REVIEW_E2E_WT="$(WT_OF "$data")" REVIEW_E2E_JSON="$(JSON_OF "$data")" \
      REVIEW_E2E_REPO="$REPO_PR" REVIEW_E2E_LOG="$plog" \
      nvim --headless --noplugin -u "$REPO_ROOT/tests/e2e_init.lua" -c "luafile $script" )
}

pr_fail() { # $1=out file, $2=label
  cat "$1" >&2
  echo "e2e: $2 失敗" >&2
  exit 1
}

# (1)+(2) worktree 要セッション開始 -> o 実ファイル (head 窓経路 / #18 の最終キー) ->
#      close (dir 消滅・ref 残存)
D_PR1="$WORK/d-pr1"
OUTP1=$(mktemp "$WORK/pr1.out.XXXXXX")
run_pr "$REPO_ROOT/tests/e2e/pr1.lua" "$D_PR1" >"$OUTP1" 2>&1 || pr_fail "$OUTP1" "pr phase1"
grep -q 'E2E-PR1 wt-file=' "$OUTP1" || pr_fail "$OUTP1" 'pr phase1 (head が worktree 実ファイルでない)'
[ ! -d "$(WT_OF "$D_PR1")" ] || { echo 'e2e: close 後に worktree dir が残っている' >&2; exit 1; }
# show-ref --verify は短縮名を解決しないため rev-parse --verify で見る (0.13/git 実測)
git -C "$REPO_PR" rev-parse --verify -q review-nvim/pr-7 >/dev/null || {
  echo 'e2e: close 後に自前 ref review-nvim/pr-7 が消えている (残すのが設計)' >&2
  exit 1
}

# 別プロセス起動: 正常 close 後に残骸 scan 通知が出ないこと (pr-worktree.md テスト方針)
OUTP1B=$(mktemp "$WORK/pr1b.out.XXXXXX")
run_pr "$REPO_ROOT/tests/e2e/pr1b.lua" "$D_PR1" >"$OUTP1B" 2>&1 || pr_fail "$OUTP1B" "pr phase1b"
grep -q 'E2E-PR1B idle=1' "$OUTP1B" || pr_fail "$OUTP1B" 'pr phase1b'
if grep -Eq '残骸|worktree' "$WORK/pr-pr1b.lua.log"; then
  echo 'e2e: 正常 close 後に worktree scan 通知が出た (誤検出)' >&2
  exit 1
fi

# (3) close せず終了 -> 残骸 scan 回収通知 -> 復元時に worktree 再生成
D_PR2="$WORK/d-pr2"
OUTP2=$(mktemp "$WORK/pr2.out.XXXXXX")
run_pr "$REPO_ROOT/tests/e2e/pr2.lua" "$D_PR2" >"$OUTP2" 2>&1 || pr_fail "$OUTP2" "pr phase2(crash)"
grep -q 'E2E-PR2 started=1' "$OUTP2" || pr_fail "$OUTP2" 'pr phase2(crash)'
WT2=$(WT_OF "$D_PR2")
[ -d "$WT2" ] || { echo 'e2e: crash 模擬後に worktree dir が無い (前提崩れ)' >&2; exit 1; }
chmod -R u+w "$WT2" 2>/dev/null || true
rm -rf "$WT2" # 異常終了で掃除半端 -> dir 消滅状態を模擬 (scan は記録回収で応答)
OUTP3=$(mktemp "$WORK/pr3.out.XXXXXX")
run_pr "$REPO_ROOT/tests/e2e/pr3.lua" "$D_PR2" >"$OUTP3" 2>&1 || pr_fail "$OUTP3" "pr phase3(回復)"
grep -q 'E2E-PR3 recreated=1' "$OUTP3" || pr_fail "$OUTP3" 'pr phase3(回復)'
grep -q 'worktree ディレクトリが消滅しています' "$WORK/pr-pr3.lua.log" || {
  echo 'e2e: 起動 scan の残骸回収通知が無い (陽性対照)' >&2
  exit 1
}
[ -d "$WT2" ] || { echo 'e2e: 復元時に worktree が再生成されていない' >&2; exit 1; }

# (4) worktree を編集して close -> --force 確認 -> cancel 無変更 / approve dir 消滅
D_PR4="$WORK/d-pr4"
OUTP4=$(mktemp "$WORK/pr4.out.XXXXXX")
run_pr "$REPO_ROOT/tests/e2e/pr4.lua" "$D_PR4" >"$OUTP4" 2>&1 || pr_fail "$OUTP4" "pr phase4(force 確認)"
grep -q 'E2E-PR4 cancel-kept=1' "$OUTP4" || pr_fail "$OUTP4" 'pr phase4(cancel)'
grep -q 'E2E-PR4 forced-closed=1' "$OUTP4" || pr_fail "$OUTP4" 'pr phase4(approve)'
[ ! -d "$(WT_OF "$D_PR4")" ] || { echo 'e2e: --force 承認後に worktree dir が残っている' >&2; exit 1; }

# (5) closed + created_by_us dir 残骸 -> :Review delete が dir + ref + JSON を一掃
D_PR5="$WORK/d-pr5"
OUTP5=$(mktemp "$WORK/pr5.out.XXXXXX")
run_pr "$REPO_ROOT/tests/e2e/pr5.lua" "$D_PR5" >"$OUTP5" 2>&1 || pr_fail "$OUTP5" "pr phase5(delete fixture)"
grep -q 'E2E-PR5 closed=1' "$OUTP5" || pr_fail "$OUTP5" 'pr phase5(delete fixture)'
WT5=$(WT_OF "$D_PR5")
# close 掃除が失敗して残った見立て: 同じ slug path に worktree を実作成し直す
git -C "$REPO_PR" worktree add --detach "$WT5" review-nvim/pr-7 >/dev/null 2>&1 || {
  echo 'e2e: delete fixture の残骸 worktree が作れない' >&2
  exit 1
}
OUTP6=$(mktemp "$WORK/pr6.out.XXXXXX")
run_pr "$REPO_ROOT/tests/e2e/pr6.lua" "$D_PR5" >"$OUTP6" 2>&1 || pr_fail "$OUTP6" "pr phase6(delete 掃除)"
grep -q 'E2E-PR6 swept=1' "$OUTP6" || pr_fail "$OUTP6" 'pr phase6(delete 掃除)'
[ ! -d "$WT5" ] || { echo 'e2e: delete 後に孤児 worktree dir が残っている' >&2; exit 1; }
if git -C "$REPO_PR" rev-parse --verify -q review-nvim/pr-7 >/dev/null; then
  echo 'e2e: delete 後に自前 ref review-nvim/pr-7 が残っている' >&2
  exit 1
fi
[ ! -f "$(JSON_OF "$D_PR5")" ] || { echo 'e2e: delete 後にセッション JSON が残っている' >&2; exit 1; }

echo "e2e: OK — golden path line=$L1 + 未コミット反映 (E2E-R1/U1/U2/R2) + 横断コメント一覧 (E2E-CL1/CL2/CL3: 開く / ジャンプ / 削除追随) + head 解決フロー (switch / 縮退 / 縮退再開始 / 復元再評価) + tab 消滅 (open 維持・残骸 0) + PR worktree (o 実ファイル / close 掃除 / crash 回復 / --force 確認 / delete dir+ref)"
