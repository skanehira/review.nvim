#!/usr/bin/env bash
# review.nvim の plenary busted テストを実行し、結果を exit code で返す。
#
#   scripts/run-tests.sh            # lua/review 配下の全 *_spec.lua (PlenaryBustedDirectory)
#   scripts/run-tests.sh <file>     # 単一 spec ファイル (make test-file FILE=...)
#
# 契約 (DESIGN.md「開発・検証コマンド」):
#   - PLENARY_PATH 必須。未設定なら tests/minimal_init.lua が exit 1 する
#   - 出力テンポラリは mktemp -d + trap で掃除し、環境変数で完結させる
#     (固定パスを使わず並列実行で競合しない)
#   - plenary は失敗時に子 / 親 nvim の cquit で非ゼロ終了するが、
#     (a) spec 内の require 失敗などファイル単位のエラーでは子 nvim が終了せずハングする
#     (b) 「1 件も実行されない green」は 0 終了してしまう
#     ため、単一ファイルモードは pcall ラッパーでエラーを exit 1 に変換し、
#     両モード共通でサマリ行を解析して実行件数と失敗件数を独立に判定する。
set -euo pipefail

: "${PLENARY_PATH:?PLENARY_PATH 環境変数を設定してください (plenary.nvim のパス)}"

cd "$(dirname "$0")/.."

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
LOG="$WORKDIR/output.txt"

run_all() {
  nvim --headless --noplugin -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory lua/review { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 10000 }" \
    >"$LOG" 2>&1
}

run_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "review.nvim tests: spec ファイルが見つかりません: $file" >&2
    return 1
  fi
  nvim --headless --noplugin -u tests/minimal_init.lua \
    -c "lua
local ok, err = pcall(require('plenary.busted').run, '$file')
if not ok then
  print('BUSTED-LOAD-ERROR: ' .. tostring(err))
  vim.cmd('1cq')
end" \
    >"$LOG" 2>&1
}

status=0
if [ "$#" -gt 0 ]; then
  run_file "$1" || status=$?
else
  run_all || status=$?
fi

cat "$LOG"

# ANSI カラーと CR を落としてサマリを行解析する。
PLAIN="$WORKDIR/plain.txt"
sed $'s/\x1b\\[[0-9;]*m//g' "$LOG" | tr -d '\r' >"$PLAIN"

fail=0

# 失敗マーカー (検出器の対照はリポジトリ外の一時 spec / 空ディレクトリで確認済み)
if grep -qE '^(Fail[[:space:]]*\|\||Tests Failed|FAILED TO LOAD FILE|BUSTED-LOAD-ERROR|We had an unexpected error)' "$PLAIN"; then
  echo "review.nvim tests: 失敗マーカーを検出" >&2
  fail=1
fi
if grep -qE '^Failed :[[:space:]]*[1-9]' "$PLAIN" || grep -qE '^Errors :[[:space:]]*[1-9]' "$PLAIN"; then
  echo "review.nvim tests: 失敗 / エラーが 1 件以上" >&2
  fail=1
fi

# 実行件数ガード: Success サマリ行 (Summary "Success: <TAB>N"。テスト行の
# "Success<TAB>||" はコロンを持たないので混入しない) の合計が 0 なら
# 「実行されていない green」。
pass_total=$(awk '{ if (index($1, "Success:") == 1) { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) sum += $i } } END { print sum + 0 }' "$PLAIN")
if [ "$pass_total" -eq 0 ]; then
  echo "review.nvim tests: 実行されたテストが 0 件です (guard: 空 green を失敗にする)" >&2
  fail=1
fi

if [ "$status" -ne 0 ] || [ "$fail" -ne 0 ]; then
  echo "review.nvim tests: FAILED (nvim exit=$status, passed=$pass_total)" >&2
  exit 1
fi

echo "review.nvim tests: OK (passed=$pass_total)"
