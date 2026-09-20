-- E2E セッション一覧 (:Review list) の削除追随 (issue #41 / persistence-restore
-- 「:Review list」の再 render 契約)。cwd = fixture repo (main / feature / hotfix、
-- hotfix は feature と同一ツリー)。専有 XDG data dir で起動する。
--   :Review start main feature -> q close
--   :Review start main hotfix  -> q close
--   (closed 2 件をディスクへ = セッション JSON 2 件)
--   :Review list -> 一覧 2 行 + winbar «review.nvim · 2 sessions»
--   main--hotfix 行で d -> [y/N] 確認 (headless では応答を注入) ->
--     削除は非同期なので wait_for で一覧 1 行 + winbar «· 1 session» + 行消滅
--     + ディスクの JSON 1 件 (INV 判定はメモリでなくディスク) を assert。
-- 失敗は E2E-FAIL を stdout へ出して cquit (phase1/phase6 と同一契約)。

local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local function wait_for(pred, why)
  if not vim.wait(8000, pred, 20) then
    fail('timeout: ' .. why)
  end
end

local function list_buf()
  return vim.fn.bufnr 'review://sessions'
end

local function list_lines()
  return vim.api.nvim_buf_get_lines(list_buf(), 0, -1, false)
end

local function list_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == list_buf() then
      return w
    end
  end
  return nil
end

local function row_of(slug)
  for i, line in ipairs(list_lines()) do
    if line:find(slug, 1, true) ~= nil then
      return i
    end
  end
  return nil
end

local function session_jsons()
  return vim.fn.glob((vim.fn.stdpath 'data') .. '/review.nvim/sessions/*/*.json', false, true)
end

local function close_review(slug)
  wait_for(function()
    return vim.fn.bufexists('review://sidebar/' .. slug) == 1
  end, slug .. ' 開通')
  -- コメントなし = q close に確認は出ない (head 窓の buffer-local q)。
  vim.cmd 'normal q'
  wait_for(function()
    return vim.fn.bufexists('review://sidebar/' .. slug) == 0
  end, slug .. ' close')
end

local function run()
  -- 2 セッションを作る (コメントなしの closed 2 件)
  vim.cmd 'Review start main feature'
  close_review 'main--feature'
  vim.cmd 'Review start main hotfix'
  close_review 'main--hotfix'
  if #session_jsons() ~= 2 then
    fail('前提: セッション JSON が 2 件でない: ' .. vim.inspect(session_jsons()))
  end

  -- 一覧を開く: 2 行 + winbar 2 sessions
  vim.cmd 'Review list'
  wait_for(function()
    return vim.fn.bufexists 'review://sessions' == 1
  end, 'sessionlist 開通')
  wait_for(function()
    return #list_lines() == 2
  end, '一覧 2 行')
  local lw = list_win()
  if vim.w[lw].review_winbar ~= 'review.nvim · 2 sessions' then
    fail('winbar が 2 sessions でない: ' .. tostring(vim.w[lw].review_winbar))
  end

  -- main--hotfix 行で d -> [y/N] 確認 -> 削除完了後に一覧が追随する
  -- (delete は非同期なので wait_for が必須。d 押下直後の同期 assert は競合する)。
  local row = row_of 'main--hotfix'
  if row == nil then
    fail('一覧に main--hotfix 行が無い: ' .. vim.inspect(list_lines()))
  end
  vim.api.nvim_set_current_win(lw)
  vim.api.nvim_win_set_cursor(lw, { row, 0 })
  vim.ui.input = function(_, cb)
    cb 'y'
  end
  vim.cmd 'normal d'
  wait_for(function()
    return #list_lines() == 1
  end, 'd 後に一覧が 1 行へ追随')
  wait_for(function()
    local w = list_win()
    return w ~= nil and vim.w[w].review_winbar == 'review.nvim · 1 session'
  end, 'd 後に winbar の件数が減る')
  if row_of 'main--hotfix' ~= nil then
    fail '削除した main--hotfix 行が一覧に残っている'
  end
  if #session_jsons() ~= 1 then
    fail('削除後に JSON が 1 件でない: ' .. vim.inspect(session_jsons()))
  end
  local rest = list_lines()
  if rest[1]:find('main--feature', 1, true) == nil then
    fail('残った行が main--feature でない: ' .. rest[1])
  end
  print 'E2E-SL1 deleted rows=1 winbar=1 session json=1'

  vim.cmd 'qa!'
end

-- phase1/phase6 と同じ理由でイベントループ開始後の defer_fn から走らせる。
vim.defer_fn(function()
  local ok, err = pcall(run)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
