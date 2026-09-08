# review.nvim 開発・検証コマンド (docs/design/DESIGN.md「開発・検証コマンド」)

PLENARY_PATH ?=
export PLENARY_PATH

.PHONY: test test-file lint format format-check plugin-check check e2e

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

e2e:
	scripts/e2e.sh
