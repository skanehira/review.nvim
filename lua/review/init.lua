-- review.nvim facade: setup と :Review コマンド入口。
-- サブコマンドの実装 (start / pr / list / close / delete / prompt / resume) は
-- 以降の issue で cmd_<name> として本モジュールに追加される
-- (docs/design/features/ 参照)。本基盤段階では未登録 = unknown として WARN になる。
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

-- DESIGN.md「API 一覧」のコマンド表順。Tab 補完と unknown 判定の正本。
M.subcommands = { 'start', 'pr', 'list', 'close', 'delete', 'prompt' }

local USAGE = 'usage: :Review [start <base> [head] | pr <number|url> | list | '
  .. 'close | delete <id> | prompt [file]]'

-- 不正値 (git_bin が実行不能等) は setup では弾かず初回実行時に結果型で返す
-- (foundation.md「setup は通す」)。
function M.setup(opts)
  config.setup(opts)
end

--- :Review の引数列を受け取り、cmd_<サブコマンド> へ委譲する。
--- 引数個数の検証は各ハンドラの責務。戻り値はハンドラの結果型をそのまま返す。
function M.command(args)
  local sub = args[1]
  local target = sub or 'resume'
  local handler = M['cmd_' .. target]
  if handler == nil then
    local msg = 'review.nvim: unknown subcommand: ' .. target
    vim.notify(msg .. '. ' .. USAGE, vim.log.levels.WARN)
    return result.err(msg)
  end
  return handler(args)
end

--- complete=customlist 用。サブコマンド候補を prefix 一致で返す。
function M.complete(arglead, _cmdline, _cursorpos)
  local lead = arglead or ''
  local candidates = {}
  for _, name in ipairs(M.subcommands) do
    if name:sub(1, #lead) == lead then
      table.insert(candidates, name)
    end
  end
  return candidates
end

return M
