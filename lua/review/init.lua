-- review.nvim facade: setup と :Review コマンド入口 (+ Lua API)。
-- ハンドラは発火時の require とし、起動コストと循環を避ける。
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

--- `:Review prompt [file]` (ai-prompt.md「出力経路」)。file 指定はスコープ解決を
--- handlers.prompt.for_file に委譲する。
function M.cmd_prompt(args)
  local file = args[2]
  if file ~= nil and file ~= '' then
    return M.prompt_for_file(file)
  end
  return M.prompt_all()
end

-- Lua API (DESIGN.md「API 一覧」) — 結果型 passthrough。
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

-- prompt_* は opts.copy=false でコピーを抑えられる (ai-prompt.md Lua API の
-- テストフック)。戻り値は同期失敗 (E_NOT_ACTIVE) のみ結果型で表す。
function M.prompt_all(opts)
  return require('review.handlers.prompt').all(opts)
end

function M.prompt_for_file(path, opts)
  return require('review.handlers.prompt').for_file(path, opts)
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

--- cmd_<サブコマンド> のファイル引数 (現状 prompt [file])。ai-prompt.md
--- エッジケース「曖昧パスの補完 = 対象ファイル一覧」。active 不在は空。
local function file_candidates(lead)
  local session = require('review.handlers.session').active()
  if session == nil or session.files == nil then
    return {}
  end
  local out = {}
  for path in pairs(session.files) do
    if path:sub(1, #lead) == lead then
      out[#out + 1] = path
    end
  end
  table.sort(out)
  return out
end

-- :Review start の base/head 補完。head 選択 UI と同じ候補源 (branches -> tags、
-- diff-review.md「開始」手順 1) を cmdline customlist から返す。customlist は
-- 同期関数なので取得は同期 (git/ref.refs_sync の待機上限 + ここでの TTL cache が
-- 暴走防止の 2 段構え — DESIGN.md「既知の制約」補完例外行)。
-- 失敗時は候補 0・無通知 (補完中の vim.notify は UI を汚す)。失敗 TTL だけ短くし、
-- 次の Tab 以降で回復できる (永久不活に固定しない)。
local REFS_TTL_S, REFS_FAIL_TTL_S = 30.0, 5.0
local refs_cache = {
  key = nil,
  list = {},
  expires = 0,
}

local function default_now()
  return ((vim.uv or vim.loop).hrtime()) / 1e9
end

local now_fn = default_now

--- テストフック: 時刻針の注入 (nil で本物へ戻す)。
function M._set_now(fn)
  now_fn = fn or default_now
end

--- テストフック: refs cache の強制無効化。
function M._reset_ref_completion_cache()
  refs_cache = {
    key = nil,
    list = {},
    expires = 0,
  }
end

local function start_ref_candidates(lead)
  local cwd = vim.uv and vim.uv.cwd() or vim.fn.getcwd()
  if refs_cache.key ~= cwd or now_fn() >= refs_cache.expires then
    local refs = require('review.git.ref').refs_sync { cwd = cwd }
    refs_cache = {
      key = cwd,
      list = refs.ok and refs.data or {},
      expires = now_fn() + (refs.ok and REFS_TTL_S or REFS_FAIL_TTL_S),
    }
  end
  local out = {}
  for _, name in ipairs(refs_cache.list) do
    if #lead == 0 or name:sub(1, #lead) == lead then
      out[#out + 1] = name
    end
  end
  return out
end

--- complete=customlist 用。2 引目はサブコマンド、`start` の 3 引目以降は
--- branches->tags の ref 一覧、`prompt` の 3 引目は diff のファイル一覧を
--- prefix 一致で返す (ai-prompt.md「file 引数解決」)。
--- custom 補完は入力語の末尾で発火するため cursorpos は見ない。
function M.complete(arglead, cmdline, _cursorpos)
  local lead = arglead or ''
  local words = vim.split((cmdline or ''):gsub('^:', ''), '%s+', { trimempty = true })
  -- 末尾が空白なら新しい語を補完中 = 語数 +1、そうでないなら最後の語が arglead。
  local pos = (cmdline or ''):sub(-1) == ' ' and #words + 1 or math.max(#words, 2)
  if words[1] == 'Review' and pos >= 3 and words[2] == 'start' then
    return start_ref_candidates(lead)
  end
  if pos >= 3 and words[2] == 'prompt' and words[1] == 'Review' then
    return file_candidates(lead)
  end
  local candidates = {}
  for _, name in ipairs(M.subcommands) do
    if name:sub(1, #lead) == lead then
      table.insert(candidates, name)
    end
  end
  return candidates
end

return M
