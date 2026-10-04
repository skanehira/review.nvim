-- spec 共有: handlers 系 spec の git 応答キュー stub (cli._set_system 注入)。
-- 実行順に responses[idx] を同期で on_exit に返す。呼び出し順は仕様の一部なので
-- state.git_calls に記録し、spec 側でアサートする。
local cli = require 'review.git.cli'
local git_env = require 'helpers.git_env'

local M = {}

--- { code = 0, stdout = stdout, stderr = '' }
function M.result_ok(stdout)
  return { code = 0, stdout = stdout, stderr = '' }
end

--- 呼ぶと result_ok(stdout) を返す応答関数。
function M.respond_ok(stdout)
  return function()
    return M.result_ok(stdout)
  end
end

--- 呼ぶと { code = code, stdout = '', stderr = stderr } を返す応答関数。
function M.respond_code(code, stderr)
  return function()
    return { code = code, stdout = '', stderr = stderr or '' }
  end
end

--- gh api (PR 開始時のコメント取り込み) を空一覧で通す。処理したら true。
function M.gh_api_stub(cmd, on_exit)
  if cmd[1] == 'gh' and cmd[2] == 'api' then
    on_exit { code = 0, stdout = '[]', stderr = '' }
    return true
  end
  return false
end

--- 応答キュー stub を注入する。state.git_calls / state.git_opts に cmd と
--- vim.system opts を実行順で記録する。opts:
---   gh_api_empty  gh api を空応答で通し、記録にも応答 index にも含めない
---   defer(cmd)    真なら on_exit を state.deferred に捕捉して呼ばない
---                 (実 vim.system の非同期完了前/後の挟み込みを pin する)
---   show_stdout(cmd)  応答不足の `git show` の既定 stdout (既定 'base content\n')
--- 応答不足のそれ以外の実行は error にする。
function M.install_queue(state, responses, opts)
  opts = opts or {}
  state.git_calls = {}
  state.git_opts = {}
  if opts.defer ~= nil then
    state.deferred = nil
  end
  cli._set_system(function(cmd, sys_opts, on_exit)
    if opts.gh_api_empty and M.gh_api_stub(cmd, on_exit) then
      return
    end
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    state.git_opts[idx] = sys_opts
    if opts.defer ~= nil and opts.defer(cmd) then
      state.deferred = on_exit
      return
    end
    if responses[idx] ~= nil then
      on_exit(responses[idx](cmd, sys_opts))
      return
    end
    if cmd[2] == 'show' then
      local stdout = opts.show_stdout and opts.show_stdout(cmd) or 'base content\n'
      on_exit(M.result_ok(stdout))
      return
    end
    error('git stub: 想定外の追加実行 ' .. table.concat(cmd, ' '), 0)
  end)
  git_env.executable_ok()
end

return M
