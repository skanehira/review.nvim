-- E2E worktree 編集の削除 (DoD シナリオ 4 改訂)。worktree 内実ファイルを開いて
-- 編集保存 (dirty) -> :Review close は worktree を削除しない (keep が契約。
-- force 確認なしで status=closed) -> :Review delete で --force 確認 ->
-- キャンセルは無変更 / 承認で dir + JSON 消滅。
-- 確認プロンプトは vim.ui.input 経由 (headless では入力者が居ないため応答を注入し、
-- プロンプト文そのものは log に印字して shell 側で assert する)。
-- delete の応答順: [delete 確認 y] -> [force 確認 n] / [delete 確認 y] -> [force 確認 y]
local inputs = {}
local answers = { 'y', 'n', 'y', 'y' }
vim.ui.input = function(opts, cb)
  inputs[#inputs + 1] = opts.prompt or ''
  cb(answers[#inputs] or 'y')
end

local e2e = require 'helpers.e2e'
local fail = e2e.fail
local wait_for = e2e.wait_for

local wt_root = assert(os.getenv 'REVIEW_E2E_WT', 'REVIEW_E2E_WT 未設定')
local json_path = assert(os.getenv 'REVIEW_E2E_JSON', 'REVIEW_E2E_JSON 未設定')

local function session_status()
  local ok, d = pcall(vim.json.decode, table.concat(vim.fn.readfile(json_path), '\n'))
  return ok and d.status or nil
end

vim.defer_fn(function()
  local ok, err = pcall(function()
    vim.cmd 'Review pr 7'
    wait_for(function()
      return vim.fn.bufexists 'review://sidebar/pr-7' == 1
    end, 'pr sidebar')

    -- panel o (#18 で entry を開く) -> head 窓 = worktree 実ファイル -> 編集 -> 保存
    local sidebar = vim.fn.bufnr 'review://sidebar/pr-7'
    local win = vim.fn.win_findbuf(sidebar)[1]
    vim.api.nvim_set_current_win(win)
    -- tree 既定では a.lua 行はヘッダの後ろ。entry 写像で行を引く (#17)
    local filepanel = require 'review.ui.filepanel'
    local row = nil
    for r = 1, vim.api.nvim_buf_line_count(sidebar) do
      local e = filepanel.row_entry(sidebar, r)
      if e ~= nil and e.kind == 'file' and e.path == 'a.lua' then
        row = r
      end
    end
    assert(row, 'pr panel に a.lua 行がない')
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    vim.cmd 'normal o'
    local fname = vim.uv.fs_realpath(vim.fs.joinpath(wt_root, 'a.lua'))
    wait_for(function()
      return vim.fn.bufexists(fname) == 1
    end, 'worktree file open')
    -- panel <CR>/o/l は focus を panel に維持する (現行契約) — 編集と保存は head 窓で打つ。
    vim.api.nvim_set_current_win(require('review.ui.windows').win 'head')
    local wbuf = vim.fn.bufnr(fname)
    local lines = vim.api.nvim_buf_get_lines(wbuf, 0, -1, false)
    lines[#lines + 1] = 'user edit for ai input'
    vim.bo[wbuf].modifiable = true
    vim.api.nvim_buf_set_lines(wbuf, 0, -1, false, lines)
    vim.cmd 'write'

    -- close は worktree を削除しない: force 確認なしで status=closed、dir は残る
    vim.cmd 'Review close'
    wait_for(function()
      return session_status() == 'closed'
    end, 'close 後の status=closed')
    if vim.uv.fs_stat(wt_root) == nil then
      fail 'close で worktree dir が消えた (keep が契約)'
    end
    if #inputs ~= 0 then
      fail('close に確認プロンプトが出た (削除しないのに): ' .. tostring(#inputs))
    end
    print 'E2E-PR4 close-kept=1'

    -- 1回目 delete: force 確認キャンセル -> 何も変わらない
    vim.cmd 'Review delete pr-7'
    wait_for(function()
      return #inputs >= 2
    end, 'delete force confirm prompt')
    assert(
      inputs[2]:find('has uncommitted changes', 1, true) ~= nil,
      'force プロンプト不一致: ' .. inputs[2]
    )
    if vim.uv.fs_stat(wt_root) == nil then
      fail 'キャンセルしたのに worktree dir が消えた'
    end
    if vim.uv.fs_stat(json_path) == nil then
      fail 'キャンセルしたのにセッション JSON が消えた'
    end
    print 'E2E-PR4 cancel-kept=1'

    -- 2回目 delete: force 承認 -> dir + JSON 消滅
    vim.cmd 'Review delete pr-7'
    wait_for(function()
      return vim.uv.fs_stat(wt_root) == nil and vim.uv.fs_stat(json_path) == nil
    end, '承認後の worktree dir + JSON 消滅')
    -- E211 は dir 消滅直後の非同期イベントなので少し待ってから見る (issue #40)。
    vim.wait(500, function()
      return false
    end)
    if vim.fn.bufexists(fname) == 1 then
      fail '--force 承認後も worktree 内の実ファイルバッファが残っている (E211 の源)'
    end
    if vim.fn.execute('messages'):find('E211', 1, true) ~= nil then
      fail 'delete 中に E211 (File no longer available) が出た'
    end
    print 'E2E-PR4 bufs-wiped=1'
    print 'E2E-PR4 forced-deleted=1'
    vim.cmd 'qa'
  end)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
