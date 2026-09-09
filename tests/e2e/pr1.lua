-- E2E PR phase 1 (DoD シナリオ 1+2)。cwd = fixture repo (PR クローン) で実行。
-- :Review pr 7 -> sidebar -> <Enter> で diff -> 追加行の `o` で worktree の
-- 実ファイルが開く (content = head の実物 / 編集可) -> :Review close (clean) ->
-- worktree dir 消滅 (ref は残る側は shell assert)。
-- 失敗は E2E-FAIL + cquit (raw error は headless でハングするため正規化)。

local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local function wait_for(pred, why)
  if not vim.wait(8000, pred, 20) then
    fail('timeout: ' .. why)
  end
end

local wt_root = assert(os.getenv 'REVIEW_E2E_WT', 'REVIEW_E2E_WT 未設定')

local run = function()
  vim.cmd 'Review pr 7'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/pr-7' == 1
  end, 'PR sidebar')

  -- sidebar <Enter> -> diff a.lua -> 追加行で o (DoD は diff 上の o を名指し)
  local sidebar = vim.fn.bufnr 'review://sidebar/pr-7'
  local sb_win = vim.fn.win_findbuf(sidebar)[1]
  vim.api.nvim_set_current_win(sb_win)
  vim.api.nvim_win_set_cursor(sb_win, { 1, 0 })
  local cr = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
  vim.cmd('normal ' .. cr)
  wait_for(function()
    return vim.fn.bufexists 'review://diff/pr-7/a.lua' == 1
  end, 'a.lua diff')

  local diff_buf = vim.fn.bufnr 'review://diff/pr-7/a.lua'
  local diff_win = vim.fn.win_findbuf(diff_buf)[1]
  vim.api.nvim_set_current_win(diff_win)
  local add_row
  for i, line in ipairs(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)) do
    if line:sub(1, 1) == '+' and line ~= '+++ b/a.lua' then
      add_row = i
      break
    end
  end
  if add_row == nil then
    fail 'diff に追加行が無い'
  end
  vim.api.nvim_win_set_cursor(diff_win, { add_row, 0 })
  vim.cmd 'normal o'
  wait_for(function()
    return vim.fn.bufexists(vim.fs.joinpath(wt_root, 'a.lua')) == 1
  end, 'worktree 実ファイルバッファ')

  local fname = vim.uv.fs_realpath(vim.fs.joinpath(wt_root, 'a.lua'))
  local wbuf = vim.fn.bufnr(fname)
  if wbuf == -1 then
    fail('worktree file buffer が実パスで無い: ' .. fname)
  end
  local lines = vim.api.nvim_buf_get_lines(wbuf, 0, -1, false)
  if lines[1] ~= 'PR HEAD content' or lines[2] ~= 'second' then
    fail('worktree 実ファイル内容不一致: ' .. table.concat(lines, ' / '))
  end
  if vim.bo[wbuf].readonly then
    fail 'worktree 実ファイルが read-only (編集可でなければならない)'
  end
  print('E2E-PR1 open=' .. fname)

  vim.cmd 'Review close'
  wait_for(function()
    return vim.uv.fs_stat(wt_root) == nil
  end, 'close 後の worktree dir 消滅')
  print 'E2E-PR1 closed=1'
  vim.cmd 'qa'
end

vim.defer_fn(function()
  local ok, err = pcall(run)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
