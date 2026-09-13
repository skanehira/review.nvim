-- E2E phase 2 (DoD golden path 後半 / 3 窓窓 diff)。別 headless プロセスで起動し、
-- VimEnter の継続 notify -> :Review 復元 -> 実ファイル head バッファの extmark
-- (本文 / 行位置) と viewed の一致を assert -> q (close 確認 y) -> レビュー tab
-- 消滅 + 張った実ファイルの extmark 残骸 0 + status=closed を assert。
-- 行位置 / 本文の跨プロセス照合は shell 側で行うため、観測値は E2E-S2 で print する。
-- e2e_init が setup 済み (VimEnter フック登録込み)。

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

local function run()
  local log_path = os.getenv 'REVIEW_E2E_LOG'
  if log_path == nil or log_path == '' then
    fail 'REVIEW_E2E_LOG 未設定'
  end

  -- VimEnter 継続通知 (起動自動) をログ経由で待つ
  wait_for(function()
    local f = io.open(log_path, 'r')
    if f == nil then
      return false
    end
    local text = f:read '*a' or ''
    f:close()
    return text:find('review.nvim: main--feature のレビューが続けられます', 1, true)
      ~= nil
  end, 'VimEnter 継続 notify')

  -- :Review 1 操作で復元 (open 1 件 = 即復元)
  vim.cmd 'Review'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, '復元 sidebar')
  wait_for(function()
    return windows.state() ~= nil and windows.win 'head' ~= nil
  end, '復元 3 窓')

  -- head 窓 = 復元先頭ファイルの実バッファ (一覧先頭 a.lua の open_file)
  local head_win = windows.win 'head'
  local a_buf = vim.api.nvim_win_get_buf(head_win)
  if not vim.api.nvim_buf_get_name(a_buf):match 'repo/a%.lua$' then
    fail('復元 head 窓が実ファイルでない: ' .. vim.api.nvim_buf_get_name(a_buf))
  end
  local ns = vim.api.nvim_get_namespaces()['review_comment']
  if ns == nil then
    fail 'review_comment namespace が無い'
  end
  local marks = vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, { details = true })
  if #marks ~= 1 then
    fail('復元後のコメント extmark 数が ' .. #marks .. ' (期待 1)')
  end
  local virt = marks[1][4].virt_text and marks[1][4].virt_text[1] and marks[1][4].virt_text[1][1]
    or ''
  -- 行下スレッド表示 (GitHub 風): eol は件数、本文は virt_lines 先頭行
  if not virt:find('💬', 1, true) then
    fail('復元 extmark の件数表示が無い: ' .. virt)
  end
  local vlines = marks[1][4].virt_lines or {}
  local first_line = vlines[1] and vlines[1][1] and vlines[1][1][1] or ''
  if not first_line:find('use a map here', 1, true) then
    fail('復元 extmark virt_lines 本文不一致: ' .. first_line)
  end
  local all = virt .. first_line
  if all:find('⚠', 1, true) ~= nil then
    fail('anchor 検証で active のはずが outdated 表示: ' .. all)
  end

  local sidebar_lines =
    vim.api.nvim_buf_get_lines(vim.fn.bufnr 'review://sidebar/main--feature', 0, -1, false)
  if sidebar_lines[2] == nil or sidebar_lines[2]:sub(1, 6) ~= '[✓] ' then
    fail('復元後 sidebar の viewed が復元されていない: ' .. tostring(sidebar_lines[2]))
  end

  print('E2E-S2 line=' .. (marks[1][2] + 1) .. ' body=use a map here viewed=1')

  -- q (close) 経路: コメントありなので vim.ui.input 確認になる (headless では
  -- 応答を注入。pr4 と同手法)。承認後、レビュー tab 消滅 + 実ファイルの
  -- extmark 残骸 0 + status=closed。
  local review_tab = windows.state().tab
  vim.ui.input = function(_, cb)
    cb 'y'
  end
  vim.api.nvim_set_current_win(head_win)
  vim.cmd 'normal q'
  wait_for(function()
    return not vim.api.nvim_tabpage_is_valid(review_tab)
  end, 'q 後のレビュー tab 消滅')
  if #vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, {}) ~= 0 then
    fail 'close 後に実ファイルの extmark 残骸が残った'
  end
  if not vim.api.nvim_buf_is_valid(a_buf) then
    fail 'close でユーザー所有の実ファイルバッファが消えた (消してはいけない)'
  end
  local json = vim.fn.glob(
    (vim.fn.stdpath 'data') .. '/review.nvim/sessions/*/main--feature.json',
    false,
    true
  )
  if #json ~= 1 then
    fail('セッション JSON が 1 件でない: ' .. vim.inspect(json))
  end
  local status = vim.json.decode(table.concat(vim.fn.readfile(json[1]), '\n')).status
  if status ~= 'closed' then
    fail('q close 後の status が closed でない: ' .. tostring(status))
  end
  print 'E2E-Q1 cleared=1 tabclosed=1 status=closed'
  vim.cmd 'qa'
end

-- phase1 と同じ理由で defer_fn 実行 (この driver は VimEnter notify 待ち)。
vim.defer_fn(function()
  local ok, err = pcall(run)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
