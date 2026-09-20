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
    local fname = vim.uv.fs_realpath(vim.fs.joinpath(wt_root, 'a.lua'))
    vim.cmd 'Review close'
    if not vim.wait(8000, function()
      return vim.uv.fs_stat(wt_root) == nil
    end, 20) then
      fail 'close 後 dir 消滅 timeout'
    end
    -- E211 は dir 消滅直後の非同期イベントなので少し待ってから見る (issue #40)。
    vim.wait(500, function()
      return false
    end)
    if vim.fn.bufexists(fname) == 1 then
      fail 'close 後も worktree 内の実ファイルバッファが残っている (E211 の源)'
    end
    if vim.fn.execute('messages'):find('E211', 1, true) ~= nil then
      fail 'close 中に E211 (File no longer available) が出た'
    end
    print 'E2E-PR5 closed=1 bufs-wiped=1'
    vim.cmd 'qa'
  end)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
