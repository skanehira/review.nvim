-- E2E phase 1 (DoD golden path 前半)。cwd = fixture repo で実行される。
-- :Review start main feature -> diff バッファに hunk -> c キーでコメント作成 ->
-- extmark / virt text -> sidebar <Enter> でファイル切替 + viewed -> nvim を正常終了。
-- 失敗は E2E-FAIL を stdout へ出して cquit する (-c 実行中に error を素出しすると
-- headless nvim が入力待ちになりハングするため pcall で正規化する)。
-- 成否の目証は E2E-S1 行を print し、scripts/e2e.sh が assert する。

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
  vim.cmd 'Review start main feature'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, 'sidebar buffer')

  local a_buf = vim.fn.bufnr 'review://diff/main--feature/a.lua'
  if a_buf == -1 then
    fail 'start 直後の先頭ファイル diff (a.lua) が無い'
  end

  local lines = vim.api.nvim_buf_get_lines(a_buf, 0, -1, false)
  if lines[1] ~= '■ M a.lua +2 -2' then
    fail('ヘッダ行不一致: ' .. tostring(lines[1]))
  end
  local hunk_count = 0
  for _, line in ipairs(lines) do
    if line:sub(1, 2) == '@@' then
      hunk_count = hunk_count + 1
    end
  end
  if hunk_count ~= 2 then
    fail('multi-hunk の hunk 数が 2 でない: ' .. hunk_count)
  end

  -- 1 つ目の + 行にカーソルを置いて c キー
  local target_row = nil
  for i, line in ipairs(lines) do
    if line:sub(1, 1) == '+' then
      target_row = i
      break
    end
  end
  if target_row == nil then
    fail 'a.lua diff に + 行が無い'
  end
  local win = vim.fn.win_findbuf(a_buf)[1]
  if win == nil then
    fail 'a.lua diff の window が見つからない'
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { target_row, 0 })

  vim.cmd 'normal c'
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative ~= ''
  end, 'comment float open')
  local body = 'use a map here'
  local cy = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)
  local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
  local crn = vim.api.nvim_replace_termcodes('<CR>', true, true, true)
  -- 新操作契約の主経路: insert で本文 -> <Esc> (Normal) -> <CR> 確定。
  -- (:normal はキー列を続けて解釈 — <C-y> エイリアスは range 側で維持検証)
  vim.cmd('normal ' .. 'i' .. body .. esc .. crn)

  local ns = vim.api.nvim_get_namespaces()['review_comment']
  if ns == nil then
    fail 'review_comment namespace が無い'
  end
  wait_for(function()
    return #vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, {}) > 0
  end, 'comment extmark')
  print(('E2E-S1 body=%s line=%d'):format(body, target_row))

  -- sidebar <CR> で 2 ファイル目へ切り替える (viewed 反映)
  local sidebar = vim.fn.bufnr 'review://sidebar/main--feature'
  local sb_win = vim.fn.win_findbuf(sidebar)[1]
  vim.api.nvim_set_current_win(sb_win)
  vim.api.nvim_win_set_cursor(sb_win, { 2, 0 })
  local cr = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
  vim.cmd('normal ' .. cr)
  wait_for(function()
    return vim.fn.bufexists 'review://diff/main--feature/b.lua' == 1
  end, 'b.lua diff')
  -- '[✓] ' は 6 バイト ([ + ✓ 3B + ] + space)。string.sub はバイト指定。
  local sb_lines = vim.api.nvim_buf_get_lines(sidebar, 0, -1, false)
  if sb_lines[2] == nil or sb_lines[2]:sub(1, 6) ~= '[✓] ' then
    fail('sidebar viewed 切り替え後の行不一致: ' .. tostring(sb_lines[2]))
  end

  -- [d キーバインド系 (UX 提案): focus は sidebar <CR> で diff に渡っているので、
  -- 直接 [d で a.lua に戻り、i で閲覧 float -> 閉じる -> S で一覧へ。
  vim.cmd 'normal [d'
  wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
      == 'review://diff/main--feature/a.lua'
  end, '[d で a.lua diff')
  -- 閲覧 float は「コメントのある行」からしか開かない (S1 の行へ戻る)
  vim.api.nvim_win_set_cursor(0, { target_row, 0 })
  vim.cmd 'normal i'
  wait_for(function()
    return #vim.api.nvim_tabpage_list_wins(0) == 3
  end, 'comment view float')
  local vc = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  print(('E2E-V1 viewwin=%s'):format(vc == '' and 'scratch' or vc))
  vim.cmd 'normal q'
  wait_for(function()
    return #vim.api.nvim_tabpage_list_wins(0) == 2
  end, 'comment view close')
  vim.cmd 'normal S'
  wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
      == 'review://sidebar/main--feature'
  end, 'S で sidebar focus')
  -- 以降の range コメント検証は b.lua diff 窓が必要。sidebar 2 行目の <CR> で
  -- 開き直すこの動作自体が sidebar <CR> + focus 移動の回帰にもなる)。
  vim.cmd('normal ' .. cr)
  wait_for(function()
    return vim.fn.win_findbuf(vim.fn.bufnr 'review://diff/main--feature/b.lua')[1] ~= nil
  end, 'b.lua diff win')

  -- sidebar o キー (キーマップ経由): git show <head>:<path> の read-only
  -- fileview が開く (DESIGN.md キーマップ表 sidebar o 行)。
  vim.cmd 'normal o'
  wait_for(function()
    return vim.fn.bufexists 'review://file/main--feature/b.lua' == 1
  end, 'fileview buffer')
  local fbuf = vim.fn.bufnr 'review://file/main--feature/b.lua'
  local flines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
  if flines[1] ~= 'feature addition' or flines[2] ~= 'second line' then
    fail('fileview 内容不一致: ' .. table.concat(flines, ' / '))
  end
  if not vim.bo[fbuf].readonly then
    fail 'fileview が read-only でない (git show 経路)'
  end
  print 'E2E-O1 fileview=readonly'

  -- --- prompt yank (ai-prompt.md テスト方針 golden path) -------------------
  -- b.lua の diff で視覚選択による range コメントを作り (既知の制約: :normal の
  -- 視覚選択は Vj -> c の分割投入が単位)、y で "0、:Review prompt で全文を照合する。
  -- 期待値は docs/design/features/ai-prompt.md の書式から手で書いた正本 (生成 code を
  -- 呼ばない = 循環検証回避)。b.lua 行写像: row3=+行(new1) row4=+行(new2)。
  local b_buf = vim.fn.bufnr 'review://diff/main--feature/b.lua'
  if b_buf == -1 then
    fail 'prompt 検証用の b.lua diff が無い'
  end
  local b_win = vim.fn.win_findbuf(b_buf)[1]
  if b_win == nil then
    fail 'b.lua diff の window が見つからない'
  end
  vim.api.nvim_set_current_win(b_win)
  vim.api.nvim_win_set_cursor(b_win, { 3, 0 })
  vim.cmd 'normal Vj'
  vim.cmd 'normal c'
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative ~= ''
  end, 'range コメント float open')
  vim.cmd 'normal iprefer early return'
  vim.cmd('normal ' .. cy)

  -- y: range 内の行 (row4 = new 2) で見出しなし本文を "0 にコピー
  vim.api.nvim_win_set_cursor(b_win, { 4, 0 })
  vim.cmd 'normal y'
  local got_y = vim.fn.getreg '0'
  if got_y ~= '@b.lua#L1-L2\nprefer early return' then
    fail('y の "0 が不一致: ' .. vim.inspect(got_y))
  end
  print 'E2E-Y1 yank=@path-range+body'

  -- :Review prompt: 見出し + 全コメント (id 昇順 = c1 a.lua#L3, c2 b.lua#L1-L2)
  vim.cmd 'Review prompt'
  local expected_prompt = table.concat({
    'Review the changes in main..feature. Please address the comments below.',
    '',
    '@a.lua#L3',
    'use a map here',
    '',
    '@b.lua#L1-L2',
    'prefer early return',
  }, '\n')
  local got_prompt = vim.fn.getreg '0'
  if got_prompt ~= expected_prompt then
    fail(':Review prompt の "0 が全文不一致: ' .. vim.inspect(got_prompt))
  end
  print 'E2E-P1 prompt=exact'

  -- 正常終了 (VimLeave を通す。コメントは CRUD 直後に保存済み)
  vim.cmd 'qa'
end

-- 起動シーケンスの途中 (-c) で vim.wait すると VimEnter 等の後続イベントが
-- 止まるため、イベントループ開始後の defer_fn で走らせる。
vim.defer_fn(function()
  local ok, err = pcall(run)
  if not ok then
    fail('driver error: ' .. tostring(err))
  end
end, 10)

vim.defer_fn(function()
  fail 'watchdog timeout'
end, 60000)
