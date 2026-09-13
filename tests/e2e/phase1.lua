-- E2E phase 1 (DoD golden path 前半 / 3 窓窓 diff)。cwd = fixture repo で実行。
-- :Review start main feature -> 専有 tab 3 窓 (panel│base│head) + tcd==repo +
-- head 窓は実ファイル (a.lua 実パス・編集可) -> head 窓で c キー (keygate 実経路)
-- -> 実ファイルへの extmark (件数 eol + 行下スレッド) と w:review_winbar ->
-- panel <CR> で b.lua へ (追加ファイル: base=null scratch, focus は head) ->
-- panel o で前行儀 tab に実ファイル (編集可) -> [d/i/S の窓移動 -> 視覚選択で
-- range コメント -> y で "0 -> :Review prompt 全文一致 -> 正常終了 (status=open)。
-- 失敗は E2E-FAIL を stdout へ出して cquit する (-c 実行中に error を素出しすると
-- headless nvim が入力待ちになりハングするため pcall で正規化する)。
-- buffer 名比較は実パス正規化 (macOS /var -> /private/var) を吸収するよう
-- fs_realpath 経由 (DESIGN.md「既知の制約」)。

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

local function realpath(p)
  return vim.uv.fs_realpath(p) or p
end

local function expect(cond, why)
  if not cond then
    fail(why)
  end
end

local function win_buf_name(w)
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
end

local function run()
  local user_tab = vim.api.nvim_get_current_tabpage()

  vim.cmd 'Review start main feature'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, 'sidebar buffer')

  -- 専有 tab 3 窓 (panel│base│head)
  local st = windows.state()
  if st == nil or not vim.api.nvim_tabpage_is_valid(st.tab) then
    fail 'レビュー専有 tab が開いていない'
  end
  if st.tab == user_tab then
    fail 'レビューがユーザー tab に開いた (専有 tabpage でない)'
  end
  if #vim.api.nvim_tabpage_list_wins(st.tab) ~= 3 then
    fail(
      'レビュー tab の窓数が ' .. #vim.api.nvim_tabpage_list_wins(st.tab) .. ' (期待 3)'
    )
  end
  local panel_win, base_win, head_win = windows.win 'panel', windows.win 'base', windows.win 'head'

  -- tcd == repo (レビュー tab のみ。ユーザー tab に漏れない)
  local top =
    vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { text = true }):wait(10000).stdout
  top = realpath((top or ''):gsub('[\r\n]+$', ''))
  local review_tabnr = nil
  for i, t in ipairs(vim.api.nvim_list_tabpages()) do
    if t == st.tab then
      review_tabnr = i
    end
  end
  if realpath(vim.fn.getcwd(-1, review_tabnr)) ~= top then
    fail('tcd が repo でない: ' .. vim.fn.getcwd(-1, review_tabnr))
  end

  -- head 窓は実ファイル (編集可) / base 窓は review://base scratch
  if win_buf_name(head_win) ~= realpath(vim.fs.joinpath(top, 'a.lua')) then
    fail('head 窓が実ファイルでない: ' .. win_buf_name(head_win))
  end
  local a_buf = vim.api.nvim_win_get_buf(head_win)
  -- 編集可 (実ファイル :edit 経路 / MUST 3) と read-only でないこと
  expect(vim.bo[a_buf].modifiable, 'head 実ファイル窓が modifiable でない')
  expect(not vim.bo[a_buf].readonly, 'head 実ファイル窓が read-only')
  if win_buf_name(base_win) ~= 'review://base/main--feature/a.lua' then
    fail('base 窓 scratch でない: ' .. win_buf_name(base_win))
  end
  local base_buf = vim.api.nvim_win_get_buf(base_win)
  -- base = git show main:a.lua (変更前の行がそのまま見える = 窓 diff の片側)。
  -- 充填は非同期 (git show) なので出現を待ってから内容を見る。
  wait_for(function()
    local bl = vim.api.nvim_buf_get_lines(base_buf, 0, -1, false)
    return bl[3] == 'line3'
  end, 'base scratch に git show main:a.lua が充填される')
  -- 窓 diff が効いている (base/head 2 窓 + fold/hunk 移動の土台)
  if not vim.wo[head_win].diff or vim.wo[head_win].foldmethod ~= 'diff' then
    fail 'head 窓に窓 diff opts が効いていない'
  end
  -- 開通 focus は head 窓 (直後の c/e が効く位置)
  expect(head_win == vim.api.nvim_get_current_win(), '開通 focus が head 窓でない')
  print(
    ('E2E-L1 wins=3 tcd=repo head=%s base=%s'):format(
      win_buf_name(head_win),
      win_buf_name(base_win)
    )
  )

  -- head 窓の恒等行 3 (LINE3-changed) で c キー (keygate 実経路)
  vim.api.nvim_win_set_cursor(head_win, { 3, 0 })
  vim.cmd 'normal c'
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative ~= ''
  end, 'comment float open')
  local body = 'use a map here'
  local cy = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)
  local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
  local crn = vim.api.nvim_replace_termcodes('<CR>', true, true, true)
  -- 新操作契約の主経路: insert で本文 -> <Esc> (Normal) -> <CR> 確定。
  vim.cmd('normal ' .. 'i' .. body .. esc .. crn)

  local ns = vim.api.nvim_get_namespaces()['review_comment']
  if ns == nil then
    fail 'review_comment namespace が無い'
  end
  wait_for(function()
    return #vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, {}) > 0
  end, 'comment extmark (実ファイル)')
  -- 張られた行 (恒等 = new 側 3 行目) を shell 側の復元照合に渡す
  local s_mark = vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, {})[1]
  print(('E2E-S1 body=%s line=%d'):format(body, s_mark[2] + 1))

  -- winbar chrome: 窓変数 w:review_winbar のみ (b: は実ファイル窓から漏れるため使わない)
  print(
    ('E2E-W1 winbar=%s'):format(
      tostring(vim.w[head_win].review_winbar ~= nil and vim.b[a_buf].review_winbar == nil)
    )
  )

  -- コメント行下スレッド (GitHub 風): eol に件数、virt_lines に本文 (同一 mark)
  local found_cnt, found_body = false, false
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, { details = true })) do
    local d = m[4] or {}
    local vt = d.virt_text and d.virt_text[1] and d.virt_text[1][1] or ''
    if vt:find('💬', 1, true) ~= nil and m[2] == 2 then
      found_cnt = true
    end
    for _, vl in ipairs(d.virt_lines or {}) do
      if vl[1] and vl[1][1] and vl[1][1]:find(body, 1, true) ~= nil then
        found_body = true
      end
    end
  end
  if not (found_cnt and found_body) then
    fail(
      'コメントスレッド表示が壊れた count='
        .. tostring(found_cnt)
        .. ' body='
        .. tostring(found_body)
    )
  end
  print 'E2E-T1 thread=eol+virtlines'

  -- panel <CR> で 2 ファイル目 (b.lua) へ (viewed 反映 + focus は head)
  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_cursor(panel_win, { 2, 0 })
  local cr = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
  vim.cmd('normal ' .. cr)
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win()) == realpath(vim.fs.joinpath(top, 'b.lua'))
  end, 'b.lua head 実ファイル + focus head')
  -- 変更ファイルの base 窓 = review://base scratch に git show main:b.lua。
  -- (追加 A の null scratch / 削除・binary 告知の張り分けは session_spec が unit pin)
  local b_base_buf = vim.api.nvim_win_get_buf(windows.win 'base')
  if win_buf_name(windows.win 'base') ~= 'review://base/main--feature/b.lua' then
    fail('b.lua base 窓 scratch でない: ' .. win_buf_name(windows.win 'base'))
  end
  wait_for(function()
    return vim.api.nvim_buf_get_lines(b_base_buf, 0, -1, false)[1] == 'base'
  end, 'base scratch に git show main:b.lua が充填される')
  -- '[✓] ' は 6 バイト ([ + ✓ 3B + ] + space)。string.sub はバイト指定。
  local sidebar = vim.fn.bufnr 'review://sidebar/main--feature'
  local sb_lines = vim.api.nvim_buf_get_lines(sidebar, 0, -1, false)
  if sb_lines[2] == nil or sb_lines[2]:sub(1, 6) ~= '[✓] ' then
    fail('sidebar viewed 切り替え後の行不一致: ' .. tostring(sb_lines[2]))
  end

  -- panel o: 前行儀 tab に実ファイルを開く (review tab を壊さず・編集可)。
  -- (縮退/checkout 側に無いファイルの git show read-only fallback は unit pin)
  vim.api.nvim_set_current_win(windows.win 'panel')
  local tabs_before = #vim.api.nvim_list_tabpages()
  vim.cmd 'normal o'
  wait_for(function()
    return #vim.api.nvim_list_tabpages() == tabs_before + 1
  end, 'o で前行儀 tab 增加')
  local b_real = realpath(vim.fs.joinpath(top, 'b.lua'))
  if win_buf_name(vim.api.nvim_get_current_win()) ~= b_real then
    fail(
      'o 後の現在 buf が実ファイルで無い: '
        .. win_buf_name(vim.api.nvim_get_current_win())
    )
  end
  local fbuf = vim.fn.bufnr(b_real)
  local b_lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
  if b_lines[1] ~= 'feature addition' or b_lines[2] ~= 'second line' then
    fail('o の実ファイル内容不一致: ' .. table.concat(b_lines, ' / '))
  end
  if vim.bo[fbuf].readonly then
    fail 'o の実ファイルが read-only (編集可でなければならない)'
  end
  print 'E2E-O1 fileview=real-editable'
  -- o で作った tab を閉じてレビュー tab へ戻る (レビュー tab は無傷のはず)
  vim.cmd 'tabclose'
  vim.api.nvim_set_current_tabpage(st.tab)
  expect(
    #vim.api.nvim_tabpage_list_wins(windows.state().tab) == 3,
    'o の tab を閉じた後にレビュー tab の 3 窓が壊れた'
  )

  -- [d で a.lua に戻り、i で閲覧 float -> 閉じる -> S で panel focus
  vim.api.nvim_set_current_win(windows.win 'head')
  vim.cmd 'normal [d'
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win()) == realpath(vim.fs.joinpath(top, 'a.lua'))
  end, '[d で a.lua head 実ファイル')
  vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 3, 0 })
  vim.cmd 'normal i'
  wait_for(function()
    return #vim.api.nvim_tabpage_list_wins(0) == 4
  end, 'comment view float')
  local vc = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  print(('E2E-V1 viewwin=%s'):format(vc == '' and 'scratch' or vc))
  vim.cmd 'normal q'
  wait_for(function()
    return #vim.api.nvim_tabpage_list_wins(0) == 3
  end, 'comment view close')
  vim.cmd 'normal S'
  wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
      == 'review://sidebar/main--feature'
  end, 'S で panel focus')

  -- --- prompt yank (ai-prompt.md テスト方針 golden path) -------------------
  -- b.lua (head 実ファイル) で視覚選択 range コメントを作り (既知の制約: :normal
  -- の視覚選択は Vj -> c の分割投入が単位)、y で "0、:Review prompt で全文照合。
  -- 期待値は docs/design/features/ai-prompt.md の書式から手で書いた正本
  -- (生成 code を呼ばない = 循環検証回避)。b.lua 恒等行: 1 / 2 行とも new 側。
  vim.api.nvim_set_current_win(windows.win 'panel')
  vim.api.nvim_win_set_cursor(windows.win 'panel', { 2, 0 })
  vim.cmd('normal ' .. cr)
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win()) == b_real
  end, 'b.lua head 実ファイル (range 用)')
  local b_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(b_win, { 1, 0 })
  vim.cmd 'normal Vj'
  vim.cmd 'normal c'
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative ~= ''
  end, 'range コメント float open')
  vim.cmd 'normal iprefer early return'
  vim.cmd('normal ' .. cy)

  -- y: range 内の行 (2 行目) で見出しなし本文を "0 にコピー
  vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
  vim.cmd 'normal y'
  -- yank は keygate → schedule 経由で走るので着地を待つ
  wait_for(function()
    return vim.fn.getreg '0' == '@b.lua#L1-L2\nprefer early return'
  end, 'y で "0 に @path#L.. + 本文')
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

  -- 正常終了 (VimLeave を通す。コメントは CRUD 直後に保存済み。
  -- q による tab 消滅 + extmark clear は phase2 が同じセッションで検証する)
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
