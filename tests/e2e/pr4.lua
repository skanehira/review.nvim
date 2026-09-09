-- E2E worktree 編集 close (DoD シナリオ 4)。worktree 内実ファイルを `o` で開いて
-- 編集保存 -> :Review close で --force 確認 -> キャンセルは無変更 / 承認で dir 消滅。
-- 確認プロンプトは vim.ui.input 経由 (headless では入力者が居ないため応答を注入し、
-- プロンプト文そのものは log に印字して shell 側で assert する)。
local inputs = {}
local answers = { 'n', 'y' }
vim.ui.input = function(opts, cb)
  inputs[#inputs + 1] = opts.prompt or ''
  cb(answers[#inputs] or 'y')
end

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

vim.defer_fn(function()
  local ok, err = pcall(function()
    vim.cmd 'Review pr 7'
    wait_for(function()
      return vim.fn.bufexists 'review://sidebar/pr-7' == 1
    end, 'pr sidebar')

    -- sidebar o -> worktree 実ファイル -> 編集 -> 保存
    local sidebar = vim.fn.bufnr 'review://sidebar/pr-7'
    local win = vim.fn.win_findbuf(sidebar)[1]
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd 'normal o'
    local fname = vim.uv.fs_realpath(vim.fs.joinpath(wt_root, 'a.lua'))
    wait_for(function()
      return vim.fn.bufexists(fname) == 1
    end, 'worktree file open')
    local wbuf = vim.fn.bufnr(fname)
    local lines = vim.api.nvim_buf_get_lines(wbuf, 0, -1, false)
    lines[#lines + 1] = 'user edit for ai input'
    vim.bo[wbuf].modifiable = true
    vim.api.nvim_buf_set_lines(wbuf, 0, -1, false, lines)
    vim.cmd 'write'

    -- 1回目 close: force 確認キャンセル -> 何も変わらない
    vim.cmd 'Review close'
    wait_for(function()
      return #inputs >= 1
    end, 'force confirm prompt')
    assert(
      inputs[1]:find('未コミットの変更', 1, true) ~= nil,
      'force プロンプト不一致: ' .. inputs[1]
    )
    if vim.uv.fs_stat(wt_root) == nil then
      fail 'キャンセルしたのに worktree dir が消えた'
    end
    local status = vim.json.decode(
      table.concat(vim.fn.readfile(assert(os.getenv 'REVIEW_E2E_JSON')), '\n')
    ).status
    if status ~= 'open' then
      fail('キャンセル後に status が open でない: ' .. tostring(status))
    end
    if vim.fn.bufexists 'review://sidebar/pr-7' ~= 1 then
      fail 'キャンセル後に sidebar が閉じた'
    end
    print 'E2E-PR4 cancel-kept=1'

    -- 2回目 close: 承認 -> dir 消滅 + closed
    vim.cmd 'Review close'
    wait_for(function()
      return vim.uv.fs_stat(wt_root) == nil
    end, '承認後の worktree dir 消滅')
    print 'E2E-PR4 forced-closed=1'
    vim.cmd 'qa'
  end)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
