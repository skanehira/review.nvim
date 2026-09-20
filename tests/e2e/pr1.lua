-- E2E PR phase 1 (DoD シナリオ 1+2 / 3 窓)。cwd = fixture repo (PR クローン)。
-- :Review pr 7 -> worktree 作成 -> 専有 tab はその worktree に tcd され、head 窓は
-- worktree 内の実ファイル (content = head 実物・編集可) -> `o` はレビュー tab の外
-- (前行儀) に worktree 基準パスの実ファイルを開く -> :Review close (clean) ->
-- worktree dir 消滅 (ref は残る側は shell assert)。
-- buffer/dir 比較は realpath (macOS /var -> /private/var 正規化)。
-- 失敗は E2E-FAIL + cquit (raw error は headless でハングするため正規化)。

local windows = require 'review.ui.windows'

local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local function wait_for(pred, why)
  if not vim.wait(8000, pred, 20) then
    fail('timeout: ' .. why)
  end
end

-- 比較は symlink 解決後の実パスで行う (macOS /var -> /private/var)。gsub の
-- 多値戻りを実関数に直接渡さない。
local function realpath(p)
  local s = (p or ''):gsub('[\r\n]+$', '')
  return vim.uv.fs_realpath(s) or s
end

-- worktree dir はレビュー開始時に作られる (起動時点では未存在)。realpath は
-- 生成後に解決する必要があるので raw のまま保持し、比較箇所で lazy resolve する。
local wt_root = assert(os.getenv 'REVIEW_E2E_WT', 'REVIEW_E2E_WT 未設定')

local run = function()
  vim.cmd 'Review pr 7'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/pr-7' == 1
  end, 'PR sidebar')

  local st = windows.state()
  if st == nil or #vim.api.nvim_tabpage_list_wins(st.tab) ~= 3 then
    fail 'PR レビューの専有 tab 3 窓が開かない'
  end

  -- tab は worktree に tcd (head 実ファイル + LSP の cwd 根拠)
  local review_tabnr = nil
  for i, t in ipairs(vim.api.nvim_list_tabpages()) do
    if t == st.tab then
      review_tabnr = i
    end
  end
  if realpath(vim.fn.getcwd(-1, review_tabnr)) ~= realpath(wt_root) then
    fail(
      'PR tab の tcd が worktree でない: got='
        .. realpath(vim.fn.getcwd(-1, review_tabnr))
        .. ' want='
        .. tostring(realpath(wt_root))
        .. ' raw='
        .. tostring(wt_root)
    )
  end

  -- head 窓 = worktree 内の実ファイル (初期開き = 一覧先頭 a.lua)
  local head_win = windows.win 'head'
  local fname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(head_win))
  if fname ~= realpath(vim.fs.joinpath(wt_root, 'a.lua')) then
    fail('head 窓が worktree 実ファイルでない: ' .. tostring(fname))
  end
  local wbuf = vim.api.nvim_win_get_buf(head_win)
  local lines = vim.api.nvim_buf_get_lines(wbuf, 0, -1, false)
  if lines[1] ~= 'PR HEAD content' or lines[2] ~= 'second' then
    fail('worktree 実ファイル内容不一致: ' .. table.concat(lines, ' / '))
  end
  if vim.bo[wbuf].readonly then
    fail 'worktree 実ファイルが read-only (編集可でなければならない)'
  end

  -- o (別 tab に実ファイル) は 2026-09 削除。head 窓自体が worktree 実ファイル
  -- であることを上の assert が担保する (marker は shell 互換のため据え置き)。
  vim.api.nvim_set_current_tabpage(st.tab)
  print('E2E-PR1 wt-file=' .. fname)

  vim.cmd 'Review close'
  wait_for(function()
    return vim.uv.fs_stat(wt_root) == nil
  end, 'close 後の worktree dir 消滅')
  -- fs watcher (E211) は dir 消滅直後の非同期イベントなので少し待ってから見る。
  -- バッファは remove spawn より先に同期破棄される契約なので、dir 消滅後に
  -- E211 が出たら破棄漏れ (= issue #40 の回帰)。
  vim.wait(500, function()
    return false
  end)
  if vim.fn.bufexists(fname) == 1 then
    fail 'close 後も worktree 内の実ファイルバッファが残っている (E211 の源)'
  end
  if vim.fn.execute('messages'):find('E211', 1, true) ~= nil then
    fail 'close 中に E211 (File no longer available) が出た'
  end
  print 'E2E-PR1 bufs-wiped=1 no-e211=1'
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
