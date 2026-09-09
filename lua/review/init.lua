-- review.nvim facade: setup と :Review コマンド入口 (+ Lua API)。
-- prompt は ai-prompt issue で cmd_prompt として追加される
-- (未登録 = unknown として WARN)。ハンドラは発火時の require とし、
-- 起動コストと循環を避ける。
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

-- DESIGN.md「API 一覧」のコマンド表順。Tab 補完と unknown 判定の正本。
M.subcommands = { 'start', 'pr', 'list', 'close', 'delete', 'prompt' }

local USAGE = 'usage: :Review [start <base> [head] | pr <number|url> | list | '
  .. 'close | delete <id> | prompt [file]]'

local function usage(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
  return result.err('review.nvim: ' .. msg, nil)
end

-- 不正値 (git_bin が実行不能等) は setup では弾かず初回実行時に結果型で返す
-- (foundation.md「setup は通す」)。
function M.setup(opts)
  config.setup(opts)
  -- 起動時の worktree scan + 継続通知 (persistence-restore.md「起動時」/
  -- pr-worktree.md「異常終了からの回復」)。掃除は auto_notify_resume に依らず
  -- 走るためフックは無条件。通知可否は startup_scan 側で見る。
  -- 再 setup で_augroup を立て直すので重複しない。
  local group = vim.api.nvim_create_augroup('review_nvim', { clear = true })
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    desc = 'review.nvim: worktree 残骸 scan + open セッションの継続通知 (窓は開かない)',
    callback = function()
      require('review.handlers.restore').startup_scan()
    end,
  })
end

function M.cmd_start(args)
  if args[2] == nil or args[2] == '' then
    return usage ':Review start <base> [head] の形式で指定してください'
  end
  return require('review.handlers.session').start { base = args[2], head = args[3] }
end

function M.cmd_pr(args)
  if args[2] == nil or args[2] == '' then
    return usage ':Review pr <number|url> の形式で指定してください'
  end
  return require('review.handlers.pr').start(args[2])
end

function M.cmd_resume(_args)
  require('review.handlers.restore').resume_or_select()
  return result.ok()
end

function M.cmd_list(_args)
  require('review.handlers.sessions_list').open()
  return result.ok()
end

function M.cmd_close(_args)
  local res = require('review.handlers.session').close()
  if not res.ok then
    vim.notify(res.error, vim.log.levels.WARN)
  end
  return res
end

function M.cmd_delete(args)
  if args[2] == nil or args[2] == '' then
    return usage ':Review delete <id> の形式で指定してください'
  end
  return require('review.handlers.session').delete(args[2])
end

-- Lua API (DESIGN.md「API 一覧」) — 結果型 passthrough。prompt_* は ai-prompt issue。
function M.start(opts)
  return require('review.handlers.session').start(opts)
end

--- start_pr({number}) :Review pr と同じ入口。number は 番号 or URL (string|number)。
--- 戻り値はディスパッチ受理 (gh / git 成否は非同期 notify / UI)。
function M.start_pr(opts)
  local target = type(opts) == 'table' and opts.number or opts
  return require('review.handlers.pr').start(target)
end

--- resume({id}) は該当セッションを即復元 (DESIGN.md「API 一覧」)。id 無しは
--- :Review 無印と同じ復元 / 選択 UI。:Review コマンド側に id 経路は無い (API 一覧
--- のコマンド表どおり無印 = 選択 UI のみ)。
function M.resume(opts)
  if type(opts) == 'table' and type(opts.id) == 'string' and opts.id ~= '' then
    return require('review.handlers.restore').resume_by_id(opts.id)
  end
  require('review.handlers.restore').resume_or_select()
  return result.ok()
end

function M.close()
  return require('review.handlers.session').close()
end

function M.delete(opts)
  return require('review.handlers.session').delete(type(opts) == 'table' and opts.id or opts)
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
