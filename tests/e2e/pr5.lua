-- E2E delete fixture (DoD シナリオ 5 前半)。pr-7 を開始して clean close する。
-- close 後の dir 消滅まで待ってから終了 (shell 側が残骸を再作成する)。
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
      fail 'pr-7 開始 timeout'
    end
    vim.cmd 'Review close'
    if not vim.wait(8000, function()
      return vim.uv.fs_stat(wt_root) == nil
    end, 20) then
      fail 'close 後 dir 消滅 timeout'
    end
    print 'E2E-PR5 closed=1'
    vim.cmd 'qa'
  end)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
