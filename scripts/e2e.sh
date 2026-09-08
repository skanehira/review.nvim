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

echo "e2e: OK — golden path (start / c comment / sidebar <Enter> / o fileview / quit / restore / head select) line=$L1"
