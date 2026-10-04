-- review.nvim の headless テスト init。
-- plenary busted ハーネス (PlenaryBustedDirectory / 直接 busted.run) は
-- すべてこのファイルを -u で起動する。
-- 契約 (DESIGN.md「開発・検証コマンド」): PLENARY_PATH 未設定なら exit 1。

local plenary = os.getenv 'PLENARY_PATH'
if plenary == nil or plenary == '' then
  io.stderr:write(
    'review.nvim tests: PLENARY_PATH 環境変数が未設定です '
      .. '(例: git clone --depth 1 https://github.com/nvim-lua/plenary.nvim '
      .. '~/.local/share/nvim/review-nvim-deps/plenary && '
      .. 'PLENARY_PATH=~/.local/share/nvim/review-nvim-deps/plenary make test)\n'
  )
  io.stderr:flush()
  os.exit(1)
end

-- 変更範囲の require ("review" 自身) と plenary を runtimepath に足す。
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(plenary)

-- 複数 spec で共有するヘルパー (tests/helpers/*.lua) を require 'helpers.<name>' で
-- 読めるようにする。rtp ローダは <rtp>/lua/ しか見ないので package.path に足す。
-- -u は相対パスで渡される (run-tests.sh / plenary の子 nvim) ため :p で絶対化する。
local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
package.path = tests_dir .. '/?.lua;' .. package.path

-- headless テストで swap / shada によるファイル汚染を作らない。
vim.opt.swapfile = false
vim.cmd 'set shada&'
vim.opt.shadafile = 'NONE'

-- PlenaryBustedDirectory / PlenaryBustedFile コマンドを有効にする。
vim.cmd 'runtime plugin/plenary.vim'
