-- E2E crash 回復 (DoD シナリオ 3 後半)。dir を外から消された open セッションを
-- 新プロセスが scan で回収 -> :Review 復元時に worktree が再生成される。
local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local wt_root = assert(os.getenv 'REVIEW_E2E_WT', 'REVIEW_E2E_WT 未設定')

vim.defer_fn(function()
  local ok, err = pcall(function()
    -- scan (sweep) の記録回収を待ってから復元する
    vim.wait(2000, function()
      return false
    end, 20)
    vim.cmd 'Review'
    if
      not vim.wait(8000, function()
        return vim.fn.bufexists 'review://sidebar/pr-7' == 1 and vim.uv.fs_stat(wt_root) ~= nil
      end, 20)
    then
      fail '復元時の worktree 再生成待ち timeout'
    end
    print 'E2E-PR3 recreated=1'
    vim.cmd 'qa'
  end)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
