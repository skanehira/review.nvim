-- E2E phase 2 (DoD golden path 後半)。別 headless プロセスで起動し、
-- VimEnter の継続 notify -> :Review 復元 -> 本文 / 行位置 / viewed の一致を assert。
-- 行位置 / 本文の跨プロセス照合は shell 側で行うため、観測値は E2E-S2 で print する。
-- e2e_init が setup 済み (VimEnter フック登録込み)。

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
    return vim.fn.bufexists 'review://diff/main--feature/a.lua' == 1
  end, '復元 先頭ファイル (一覧先頭 a.lua)')

  local a_buf = vim.fn.bufnr 'review://diff/main--feature/a.lua'
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
  if not virt:find('use a map here', 1, true) then
    fail('復元 extmark virt text 本文不一致: ' .. virt)
  end
  if virt:find('⚠', 1, true) ~= nil then
    fail('anchor 検証で active のはずが outdated 表示: ' .. virt)
  end

  local sidebar_lines =
    vim.api.nvim_buf_get_lines(vim.fn.bufnr 'review://sidebar/main--feature', 0, -1, false)
  if sidebar_lines[2] == nil or sidebar_lines[2]:sub(1, 6) ~= '[✓] ' then
    fail('復元後 sidebar の viewed が復元されていない: ' .. tostring(sidebar_lines[2]))
  end

  print('E2E-S2 line=' .. (marks[1][2] + 1) .. ' body=use a map here viewed=1')
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
