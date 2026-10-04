-- spec 共有: git/* 単体 spec の実行アダプタ注入と実 repo の後始末。
-- 注入 system スタブ (cmd / opts / on_exit の捕捉) と、実 git 経路用の temp repo
-- 作成・after_each 掃除を提供する。
local cli = require 'review.git.cli'
local config = require 'review.config'

local M = {}

local tracked = {}

--- after_each で削除する dir を登録して返す。
function M.track(dir)
  tracked[#tracked + 1] = dir
  return dir
end

--- after_each を登録する: cli 注入の解除・config.reset・track した dir の削除。
--- plenary busted は describe 外のフックを持たないため describe 内で呼ぶ。
function M.restore_after_each()
  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
    config.reset()
    for _, dir in ipairs(tracked) do
      vim.fn.delete(dir, 'rf')
    end
    tracked = {}
  end)
end

--- 注入用の疑似 system: 呼ばれたら (cmd, opts, on_exit) を captured に捕捉し、
--- テストが明示的に on_exit を呼ぶまでコールバックを発火しない。
function M.capture_system(captured)
  return function(cmd, opts, on_exit)
    captured.cmd = cmd
    captured.opts = opts
    captured.on_exit = on_exit
    captured.calls = (captured.calls or 0) + 1
  end
end

--- 実行ファイル検出を常に成功させる。
function M.executable_ok()
  cli._set_executable(function()
    return 1
  end)
end

--- 非同期 API を呼んで結果 (cb の引数) を待って返す。
function M.await_result(call, timeout, interval)
  local received
  call(function(res)
    received = res
  end)
  vim.wait(timeout or 6000, function()
    return received ~= nil
  end, interval)
  return received
end

--- 実 git repo (main ブランチ・user 設定済み・コミット無し) を temp dir に作る。
--- dir は track 済み。戻り値の git(args) は cwd=dir で実行し、失敗で error。
function M.init_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  M.track(dir)
  local function git(args)
    local out = vim.system(vim.list_extend({ 'git' }, args), { cwd = dir, text = true }):wait(10000)
    if out.code ~= 0 then
      error('git ' .. table.concat(args, ' ') .. ' 失敗: ' .. out.stderr, 0)
    end
    return out.stdout
  end
  git { 'init', '-q', '-b', 'main' }
  git { 'config', 'user.email', 'spec@example.com' }
  git { 'config', 'user.name', 'spec' }
  return dir, git
end

return M
