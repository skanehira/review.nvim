-- luacheck 設定。対象は scripts/lint.sh (lua/ plugin/)。
std = "lua51"
max_line_length = 100

-- Neovim のグローバル (ランタイム依存ゼロの設計なので vim API のみ)。
globals = { "vim" }

-- テスト (plenary busted ハーネスのグローバル)。
files = {
  ["**/*_spec.lua"] = {
    globals = { "describe", "it", "pending", "before_each", "after_each", "assert" },
  },
}
