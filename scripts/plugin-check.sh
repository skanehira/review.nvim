#!/usr/bin/env bash
# headless nvim で :Review 定義と :help review 到達を確認する (make plugin-check)。
# DoD 契約: 成功条件は (1) 終了コード 0 (2) stderr 空。
set -euo pipefail
: "${PLENARY_PATH:=}" # plugin-check は plenary 不要だが make 側の export と競合させないため宣言のみ

cd "$(dirname "$0")/.."

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

status=0
nvim --headless --clean -l scripts/plugin_check.lua \
  >"$WORKDIR/stdout" 2>"$WORKDIR/stderr" || status=$?

cat "$WORKDIR/stdout"
if [ -s "$WORKDIR/stderr" ]; then
  echo "plugin-check: stderr が空ではない:" >&2
  cat "$WORKDIR/stderr" >&2
  exit 1
fi
if [ "$status" -ne 0 ]; then
  echo "plugin-check: 終了コード $status" >&2
  exit 1
fi
if ! grep -q '^plugin-check OK$' "$WORKDIR/stdout"; then
  echo "plugin-check: 完了マーカー 'plugin-check OK' が stdout に無い" >&2
  exit 1
fi
