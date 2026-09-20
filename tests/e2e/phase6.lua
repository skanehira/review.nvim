-- E2E phase 6 (comment-list「テスト方針」e2e golden path / issue #31)。
-- cwd = fixture repo (feature checkout)。専有 XDG data dir で起動する。
--   :Review start main feature
--   -> 初期 head a.lua の 3 行目で c -> コメント 1 (body 'phase6 alpha')
--   -> panel <CR> で b.lua head 窓 -> 2 行目で c -> コメント 2 (body 'phase6 bravo')
--   -> head 窓で <leader>c (非 expr 同期 mapping の実経路) -> 一覧
--      review://comments/main--feature が 2 行 (tree 順 = a.lua:3, b.lua:2)
--   -> 一覧 1 行目で <CR> -> a.lua head 窓の記録行 3 へジャンプ
--   -> head 窓へ戻り再度 <leader>c -> 既存一覧窓へ focus (再 vsplit しない)
--   -> 一覧 1 行目で d 二重押し -> 行消滅 (1 行) + カーソルは同じ行位置
--      + ディスクの session JSON 1 件 (INV-4) を assert。
-- 失敗は E2E-FAIL を stdout へ出して cquit (phase1/phase5 と同一契約)。

local windows = require 'review.ui.windows'
local filepanel = require 'review.ui.filepanel'

local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local function wait_for(pred, why)
  if not vim.wait(8000, pred, 20) then
    fail('timeout: ' .. why)
  end
end

local function buf_name(w)
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
end

local function tail_eq(name, suffix)
  return name:sub(-#suffix) == suffix
end

local function list_buf()
  return vim.fn.bufnr 'review://comments/main--feature'
end

local function list_lines()
  return vim.api.nvim_buf_get_lines(list_buf(), 0, -1, false)
end

-- head 窓の行で c キーにより 1 行コメントを作る (c float -> insert 本文 ->
-- <Esc> -> Normal <CR> 確定。打鍵契約は phase1/phase5 と同一 = :normal のみ安定)。
local function add_comment(line, body, why)
  local hw = windows.win 'head'
  vim.api.nvim_set_current_win(hw)
  vim.api.nvim_win_set_cursor(hw, { line, 0 })
  vim.cmd 'normal c'
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative ~= ''
  end, 'comment float open (' .. why .. ')')
  local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
  local crn = vim.api.nvim_replace_termcodes('<CR>', true, true, true)
  vim.cmd('normal ' .. 'i' .. body .. esc .. crn)
  wait_for(function()
    return windows.role_of(vim.api.nvim_get_current_win()) == 'head'
  end, 'コメント確定後の focus head (' .. why .. ')')
end

local function session_json()
  local files = vim.fn.glob(
    (vim.fn.stdpath 'data') .. '/review.nvim/sessions/*/main--feature.json',
    false,
    true
  )
  if #files ~= 1 then
    fail('セッション JSON が 1 件でない: ' .. vim.inspect(files))
  end
  return vim.json.decode(table.concat(vim.fn.readfile(files[1]), '\n'))
end

local function run()
  vim.cmd 'Review start main feature'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, 'sidebar buffer')
  wait_for(function()
    return windows.state() ~= nil and windows.win 'head' ~= nil
  end, '初期 3 窓')

  -- コメント 1: a.lua 変更行 3 (LINE3-changed) の実ファイル head 窓。
  local hw = windows.win 'head'
  if not tail_eq(buf_name(hw), 'a.lua') then
    fail('初期 head 窓が a.lua でない: ' .. buf_name(hw))
  end
  add_comment(3, 'phase6 alpha', 'a.lua')
  local a_buf = vim.api.nvim_win_get_buf(hw)
  local ns = vim.api.nvim_get_namespaces()['review_comment']
  if ns == nil then
    fail 'review_comment namespace が無い'
  end
  wait_for(function()
    return #vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, {}) == 1
  end, 'a.lua コメント extmark 1 件')

  -- コメント 2: panel <CR> で b.lua へ (追加ファイル: 1/2 行とも new 側)。
  local pw = windows.win 'panel'
  local pbuf = vim.api.nvim_win_get_buf(pw)
  local brow = nil
  for r = 1, vim.api.nvim_buf_line_count(pbuf) do
    local e = filepanel.row_entry(pbuf, r)
    if e ~= nil and e.kind == 'file' and e.path == 'b.lua' then
      brow = r
    end
  end
  if brow == nil then
    fail 'panel に b.lua 行がない'
  end
  vim.api.nvim_set_current_win(pw)
  vim.api.nvim_win_set_cursor(pw, { brow, 0 })
  local cr = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
  vim.cmd('normal ' .. cr)
  wait_for(function()
    local w = windows.win 'head'
    return w ~= nil and tail_eq(buf_name(w), 'b.lua')
  end, 'panel <CR> で b.lua head 窓')
  add_comment(2, 'phase6 bravo', 'b.lua')
  local b_buf = vim.api.nvim_win_get_buf(windows.win 'head')
  wait_for(function()
    return #vim.api.nvim_buf_get_extmarks(b_buf, ns, 0, -1, {}) == 1
  end, 'b.lua コメント extmark 1 件')

  -- <leader>c: head 窓の非 expr 同期 mapping 実経路 -> current tab に一覧 vsplit。
  vim.api.nvim_set_current_win(windows.win 'head')
  vim.cmd [[normal \c]]
  wait_for(function()
    return list_buf() ~= -1
      and vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
        == 'review://comments/main--feature'
  end, '<leader>c で一覧が開き focus が移る')
  -- 位置契約 (issue #37): 一覧はレビュー tab の最下部に全幅で開く
  -- (押した窓が head でも panel でも位置は変わらない)。
  local lw = vim.fn.bufwinid(list_buf())
  local lrow = vim.fn.win_screenpos(lw)[1]
  local hrow = vim.fn.win_screenpos(windows.win 'head')[1]
  if lrow <= hrow then
    fail('一覧が最下部に無い (list row=' .. lrow .. ' head row=' .. hrow .. ')')
  end
  if vim.api.nvim_win_get_width(lw) ~= vim.o.columns then
    fail(
      '一覧が全幅でない (width='
        .. vim.api.nvim_win_get_width(lw)
        .. ' columns='
        .. vim.o.columns
        .. ')'
    )
  end
  if vim.api.nvim_win_get_height(lw) ~= 10 then
    fail('一覧の高さが既定 10 でない: ' .. vim.api.nvim_win_get_height(lw))
  end
  print(('E2E-CL0 list row=%d width=%d'):format(lrow, vim.api.nvim_win_get_width(lw)))
  local lines = list_lines()
  if #lines ~= 2 then
    fail('一覧の行数が ' .. #lines .. ' (期待 2): ' .. vim.inspect(lines))
  end
  if lines[1]:find('a.lua:3', 1, true) == nil or lines[1]:find('phase6 alpha', 1, true) == nil then
    fail('一覧 1 行目が a.lua:3 のコメントでない: ' .. lines[1])
  end
  if lines[2]:find('b.lua:2', 1, true) == nil or lines[2]:find('phase6 bravo', 1, true) == nil then
    fail('一覧 2 行目が b.lua:2 のコメントでない: ' .. lines[2])
  end
  print(('E2E-CL1 rows=%d'):format(#lines))

  -- <CR>: 1 行目 (a.lua#L3) へジャンプ。head 窓が記録行 3 に位置決めされる。
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd('normal ' .. cr)
  local jw
  wait_for(function()
    jw = windows.win 'head'
    return jw ~= nil and vim.api.nvim_get_current_win() == jw and tail_eq(buf_name(jw), 'a.lua')
  end, '<CR> ジャンプで a.lua head 窓')
  wait_for(function()
    return vim.api.nvim_win_get_cursor(jw)[1] == 3
  end, 'head 窓カーソルが記録行 3')
  print 'E2E-CL2 jump=a.lua:3'

  -- 一覧へ戻る: head 窓から再 <leader>c -> 既存一覧窓へ focus (再 vsplit しない)。
  vim.cmd [[normal \c]]
  wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
      == 'review://comments/main--feature'
  end, '再 <leader>c で一覧窓 focus')
  if #vim.api.nvim_tabpage_list_wins(0) ~= 4 then
    fail(
      '再 <leader>c で一覧が増殖した (窓数 '
        .. #vim.api.nvim_tabpage_list_wins(0)
        .. ' != 4)'
    )
  end

  -- d 二重押し: 1 回目は arming の WARN で消さず、2 回目で削除 + save + 追随。
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd 'normal d'
  if #list_lines() ~= 2 then
    fail 'd 1 回目で消えた (arming 契約違反)'
  end
  vim.cmd 'normal d'
  wait_for(function()
    return #list_lines() == 1
  end, 'd 二重押しで一覧が 1 行へ追随')
  local rest = list_lines()
  if rest[1]:find('b.lua:2', 1, true) == nil then
    fail('削除後に残る行が b.lua:2 でない: ' .. rest[1])
  end
  if vim.api.nvim_win_get_cursor(0)[1] ~= 1 then
    fail(
      '削除後のカーソルが同じ行位置でない: '
        .. tostring(vim.api.nvim_win_get_cursor(0)[1])
    )
  end

  -- INV-4: メモリでなくディスクの session JSON を読んで 1 件を確認する。
  local data = session_json()
  if #data.comments ~= 1 or data.comments[1].body ~= 'phase6 bravo' then
    fail('ディスク JSON が 1 件 (b.lua) でない: ' .. vim.inspect(data.comments))
  end
  print(
    ('E2E-CL3 deleted rows=%d json=%d cursor=%d'):format(
      #rest,
      #data.comments,
      vim.api.nvim_win_get_cursor(0)[1]
    )
  )

  vim.cmd 'qa!'
end

-- phase1 と同じ理由でイベントループ開始後の defer_fn から走らせる。
vim.defer_fn(function()
  local ok, err = pcall(run)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
