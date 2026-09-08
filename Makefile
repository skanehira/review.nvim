# review.nvim 開発・検証コマンド (docs/design/DESIGN.md「開発・検証コマンド」)
# e2e ターゲットは最初のシナリオとともに diff-review/persistence UI の issue で追加する
# (docs/design/features/foundation.md「非スコープ」)。

PLENARY_PATH ?=
export PLENARY_PATH

.PHONY: test test-file lint format format-check plugin-check check

test:
	scripts/run-tests.sh

test-file:
	@if [ -z "$(FILE)" ]; then echo "usage: make test-file FILE=lua/review/<...>_spec.lua" >&2; exit 2; fi
	scripts/run-tests.sh $(FILE)

lint:
	scripts/lint.sh

format:
	stylua .

format-check:
	stylua --check .

plugin-check:
	scripts/plugin-check.sh

check: format-check lint test plugin-check
