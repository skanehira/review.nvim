-- review.nvim E2E 初期化 (scripts/e2e.sh が -u で使用する単一 init)。
-- 契約:
--   - REVIEW_E2E_DATA: 親 shell が export した XDG_DATA_HOME を通す (本物の
--     stdpath を汚さない / 1 シナリオ = 1 mktemp)。未設定なら error で終了。
--   - REVIEW_E2E_LOG: vim.notify の追記先ファイル (シナリオ assert 用)。
--   - runtimepath はカレントディレクトリ (リポジトリ) を追加し plugin/review.lua
--     経由で :Review を有効化、setup を呼ぶ (VimEnter 継続通知フック含む)。
local data_home = os.getenv 'XDG_DATA_HOME'
if data_home == nil or data_home == '' then
  io.stderr:write 'review.nvim e2e: XDG_DATA_HOME が未設定です (scripts/e2e.sh を使用してください)\n'
  os.exit(1)
end

-- e2e は fixture repo を cwd に起動するため getcwd ではプラグイン本体に届かない。
-- この init 自身の場所 (tests/ の親) からリポジトリルートを解決する。
local this_file = debug.getinfo(1, 'S').source:sub(2)
local repo_root = vim.fs.dirname(vim.fs.dirname(this_file))
vim.opt.runtimepath:append(repo_root)
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'

local log_path = os.getenv 'REVIEW_E2E_LOG'
if log_path ~= nil and log_path ~= '' then
  vim.notify = function(msg)
    local f = io.open(log_path, 'a')
    if f ~= nil then
      f:write(msg .. '\n')
      f:close()
    end
  end
end

-- --noplugin で起動するため :Review 登録を明示的に行う (plugin/ はガード付きで
-- 二重 source 安全)。
vim.cmd 'runtime! plugin/review.lua'

local review = require 'review'
review.setup {}
