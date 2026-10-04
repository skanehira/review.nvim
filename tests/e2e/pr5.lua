-- E2E delete fixture (DoD シナリオ 5 前半)。pr-7 を開始して clean close する。
-- close は worktree を残す設計 (keep) なので、dir 実在 + status=closed を assert して
-- 終了する (dir + ref + JSON の一掃は後続 pr6 の :Review delete が担う)。
local e2e = require 'helpers.e2e'
local fail = e2e.fail

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
    if
      not vim.wait(8000, function()
        local json = assert(os.getenv 'REVIEW_E2E_JSON', 'REVIEW_E2E_JSON 未設定')
        local okd, d = pcall(vim.json.decode, table.concat(vim.fn.readfile(json), '\n'))
        return okd and d.status == 'closed'
      end, 20)
    then
      fail 'close 後の status=closed timeout'
    end
    if vim.uv.fs_stat(wt_root) == nil then
      fail 'close で worktree dir が消えた (keep が契約)'
    end
    -- 削除していないので E211 は起きない (dir が残る)
    if vim.fn.execute('messages'):find('E211', 1, true) ~= nil then
      fail 'close 中に E211 (File no longer available) が出た'
    end
    print 'E2E-PR5 closed=1 kept=1'
    vim.cmd 'qa'
  end)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
