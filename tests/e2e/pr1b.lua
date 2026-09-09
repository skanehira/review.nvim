-- E2E PR 追加 assert (pr-worktree.md テスト方針: close 後の別プロセス起動で
-- 残骸 scan 通知が出ないこと)。scan / VimEnter が走った上で無通知のまま進む。
local run = function()
  local json = assert(os.getenv 'REVIEW_E2E_JSON', 'REVIEW_E2E_JSON 未設定')
  if vim.uv.fs_stat(json) == nil then
    print('E2E-FAIL: セッション JSON が消えている: ' .. json)
    vim.cmd 'cquit!'
  end
  local wt = assert(os.getenv 'REVIEW_E2E_WT', 'REVIEW_E2E_WT 未設定')
  if vim.uv.fs_stat(wt) ~= nil then
    print('E2E-FAIL: close 済み worktree dir が残っている: ' .. wt)
    vim.cmd 'cquit!'
  end
  print 'E2E-PR1B idle=1'
  vim.cmd 'qa'
end

vim.defer_fn(function()
  local ok, err = pcall(run)
  if not ok then
    print('E2E-FAIL: driver error: ' .. tostring(err))
    vim.cmd 'cquit!'
  end
end, 1500)

vim.defer_fn(function()
  print 'E2E-FAIL: watchdog timeout'
  vim.cmd 'cquit!'
end, 60000)
