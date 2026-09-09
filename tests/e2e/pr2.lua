-- E2E crash 模擬 (DoD シナリオ 3 前半)。Review pr 7 -> worktree 生成を確認して
-- close せず qa! (VimLeave の掃除も走らない異常終了経路の模擬)。
local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local wt_root = assert(os.getenv 'REVIEW_E2E_WT', 'REVIEW_E2E_WT 未設定')

vim.defer_fn(function()
  local ok, err = pcall(function()
    vim.cmd 'Review pr 7'
    if
      not vim.wait(8000, function()
        return vim.fn.bufexists 'review://sidebar/pr-7' == 1 and vim.uv.fs_stat(wt_root) ~= nil
      end, 20)
    then
      fail 'pr-7 worktree 生成待ち timeout'
    end
    print 'E2E-PR2 started=1'
  end)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
  vim.cmd 'qa!' -- 故意に close せず終了 (残骸を作る)
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
