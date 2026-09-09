#!/usr/bin/env bash
# review.nvim シナリオ E2E (DESIGN.md「開発・検証コマンド」E2E /
# docs/design/features/{diff-review,persistence-restore}.md「テスト方針」)。
#
# golden path: fixture repo (main / feature, 複数ファイル・複数 hunk) で
# headless nvim を起動 -> :Review start -> c キーでコメント -> sidebar <Enter> ->
# sidebar o (fileview read-only) -> 正常終了 -> 別プロセスで VimEnter notify ->
# :Review 復元 -> 本文・行位置・viewed が元の状態と一致することを assert。
# phase3: :Review start <base> 1 引数 -> 実 vim.ui.input (customlist 補完) で
# head を選んでセッション開始する経路を pin (mock を通さない接続検証)。
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
git -C "$REPO" add -A
git -C "$REPO" commit -qm feature
# phase3 (head 省略選択) の単一補完候補。feature と同じツリーの別ref。
git -C "$REPO" branch hotfix

# --- phase 1: 起動 -> コメント -> 切替 -> 正常終了 -------------------
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
grep -q 'E2E-O1 fileview=readonly' "$OUT1" || { echo 'e2e: phase1 sidebar o で fileview が開かない' >&2; exit 1; }

# 保存されたセッション JSON が実ディスクに存在し本文を含む (MUST 2/INV-4)
SESSION_JSON=$(find "$DATA" -path '*review.nvim/sessions/*/main--feature.json' | head -1)
[ -n "$SESSION_JSON" ] || { echo 'e2e: セッション JSON が存在しない' >&2; exit 1; }
grep -q '"body":"use a map here"' "$SESSION_JSON" || { echo 'e2e: 保存 JSON に本文が無い' >&2; exit 1; }

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
grep -q 'viewed=1' "$OUT2" || { echo 'e2e: viewed 復元なし' >&2; exit 1; }

# --- phase 3: head 省略 (1 引数) -> 実 vim.ui.input で選択 -> 開始 ---------
OUT3=$(mktemp "$WORK/phase3.out.XXXXXX")
if ! run_nvim "$REPO_ROOT/tests/e2e/phase3.lua" >"$OUT3" 2>&1; then
  cat "$OUT3" >&2
  echo "e2e: phase 3 nvim 終了コード非ゼロ" >&2
  exit 1
fi
cat "$OUT3" | tee -a "$WORK/e2e-report.txt"
grep -q 'E2E-S3 head=hotfix' "$OUT3" || { echo 'e2e: head 省略選択経路が開始に到達しない' >&2; exit 1; }

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

# (1)+(2) worktree 要セッション開始 -> o 実ファイル -> close (dir 消滅・ref 残存)
D_PR1="$WORK/d-pr1"
OUTP1=$(mktemp "$WORK/pr1.out.XXXXXX")
run_pr "$REPO_ROOT/tests/e2e/pr1.lua" "$D_PR1" >"$OUTP1" 2>&1 || pr_fail "$OUTP1" "pr phase1"
grep -q 'E2E-PR1 open=' "$OUTP1" || pr_fail "$OUTP1" 'pr phase1 (o で worktree file が開かない)'
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

echo "e2e: OK — golden path line=$L1 + PR worktree (o 実ファイル / close 掃除 / crash 回復 / --force 確認 / delete dir+ref)"
