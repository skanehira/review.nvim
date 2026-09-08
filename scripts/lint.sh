#!/usr/bin/env bash
# luacheck: warning 0 をゲートにする (DoD「make lint が warning 0」)。
set -euo pipefail
cd "$(dirname "$0")/.."
exec luacheck --no-color --codes lua plugin
