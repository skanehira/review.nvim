-- E2E phase 1 (DoD golden path 前半 / 3 窓窓 diff)。cwd = fixture repo で実行。
-- :Review start main feature -> 専有 tab 3 窓 (panel│base│head) + tcd==repo +
-- head 窓は実ファイル (a.lua 実パス・編集可) -> head 窓で c キー (keygate 実経路)
-- -> 実ファイルへの extmark (件数 eol + 行下スレッド) と w:review_winbar ->
-- panel <CR> で b.lua へ (変更ファイル: base は git show scratch, focus は panel 維持) ->
-- head 窓が実ファイル (編集可) -> <S-Tab>/]F/[F/i/<leader>e の
-- 窓移動 (最終キー表 #18) -> panel l で entry 開く -> 視覚選択で range コメント ->
-- y で "0 -> :Review prompt 全文一致 -> 正常終了 (status=open)。
-- 失敗は E2E-FAIL を stdout へ出して cquit する (-c 実行中に error を素出しすると
-- headless nvim が入力待ちになりハングするため pcall で正規化する)。
-- buffer 名比較は実パス正規化 (macOS /var -> /private/var) を吸収するよう
-- fs_realpath 経由 (DESIGN.md「既知の制約」)。

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

-- file panel の行は tree ヘッダで揺れるので entry 写像で行を引く (#17)
local function panel_row(kind, path)
  local buf = vim.fn.bufnr 'review://sidebar/main--feature'
  for r = 1, vim.api.nvim_buf_line_count(buf) do
    local e = filepanel.row_entry(buf, r)
    if e ~= nil and e.kind == kind and e.path == path then
      return r
    end
  end
  return nil
end

local function panel_lines()
  return vim.api.nvim_buf_get_lines(vim.fn.bufnr 'review://sidebar/main--feature', 0, -1, false)
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
  -- 窓 diff opts (diff/scrollbind/foldmethod=diff) が base/head 2 窓それぞれの
  -- 窓ローカルに効いている (fold/hunk 移動と連動スクロールの土台)
  for _, w in ipairs { head_win, base_win } do
    local wo = vim.wo[w]
    if not wo.diff then
      fail('窓 diff が効いていない (win=' .. tostring(w) .. ')')
    end
    if not wo.scrollbind then
      fail('scrollbind が効いていない (win=' .. tostring(w) .. ')')
    end
    if wo.foldmethod ~= 'diff' then
      fail('foldmethod=diff でない (win=' .. tostring(w) .. ')')
    end
  end
  -- 開通 focus は head 窓 (直後の c/e が効く位置)
  expect(head_win == vim.api.nvim_get_current_win(), '開通 focus が head 窓でない')
  print(
    ('E2E-L1 wins=3 tcd=repo head=%s base=%s'):format(
      win_buf_name(head_win),
      win_buf_name(base_win)
    )
  )

  -- file panel tree golden path (issue #17): ヘッダ 2 行・単一 child 連結 dir・
  -- 開始 open ではマークを付けない (レビュー完了 [✓] = x トグルのみ)・親パス接尾なし
  local tl = panel_lines()
  expect(tl[1] == 'Changes (3)', 'panel tree ヘッダ不一致: ' .. tostring(tl[1]))
  expect(
    tl[2] == 'Showing changes for: main..作業ツリー',
    'Showing ヘッダ不一致: ' .. tostring(tl[2])
  )
  expect(panel_row('dir', 'src/deep') ~= nil, 'src/deep 連結 dir 行が無い')
  local nrow = panel_row('file', 'src/deep/new.lua')
  expect(nrow ~= nil, 'new.lua 子行が無い')
  expect(tl[nrow] == '    A new.lua +1 -0', 'new.lua 行フォーマット不一致: ' .. tl[nrow])
  expect(
    tl[panel_row('file', 'a.lua')] == 'M a.lua +2 -2',
    '開始 open の行に mark が付いている (開封では [✓] を付けない契約): '
      .. tostring(tl[panel_row('file', 'a.lua')])
  )

  -- `i` = list フラット ⇄ tree と、dir 行 <CR> の折り畳み/展開 (#17 契約)
  local cr_key = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
  vim.api.nvim_set_current_win(panel_win)
  vim.cmd 'normal i'
  local ll = panel_lines()
  expect(
    table.concat(ll, '\n') == 'M a.lua +2 -2\nM b.lua +2 -1\nA src/deep/new.lua +1 -0',
    'i で list 表示にならない: ' .. table.concat(ll, ' / ')
  )
  print 'E2E-TR2 i=list'
  vim.cmd 'normal i'
  expect(panel_lines()[1] == 'Changes (3)', 'i 再押下で tree に戻らない')
  print 'E2E-TR3 i=tree'
  local drow = panel_row('dir', 'src/deep')
  vim.api.nvim_win_set_cursor(panel_win, { drow, 0 })
  vim.cmd('normal ' .. cr_key)
  local folded = panel_lines()
  expect(
    folded[drow] == '▸ A src/deep/',
    'dir 行 <CR> で畳まれない: ' .. tostring(folded[drow])
  )
  expect(
    table.concat(folded, '\n'):find('new.lua', 1, true) == nil,
    '畳んだ後も new.lua が出る'
  )
  vim.cmd('normal ' .. cr_key)
  expect(panel_lines()[drow] == 'A src/deep/', '<CR> 再押下で展開されない')
  expect(panel_row('file', 'src/deep/new.lua') ~= nil, '展開後も new.lua 行が無い')
  print 'E2E-TR4 fold=toggled'
  expect(tl[panel_row('file', 'a.lua')] ~= nil, 'tree 復帰後に a.lua 行が消えた')
  print 'E2E-TR1 tree=header+chain'
  -- 以降の c キー (head 窓) に備えて focus を戻す (開通時 focus = head の状態へ)
  vim.api.nvim_set_current_win(head_win)

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

  -- コメント行下スレッド (GitHub 風): eol に件数、virt_lines に本文 (同一 mark)。
  -- 本文行は hl の異なる chunk に分割されうる (outdated の id 接頭辞と本文の分離
  -- など) ため、全文連結で照合する。
  local function chunk_text(chunk)
    if type(chunk) == 'table' then
      local inner = chunk[1]
      return type(inner) == 'table' and inner[1] or inner
    end
    return chunk
  end
  local function line_text(chunks)
    local parts = {}
    for _, chunk in ipairs(chunks or {}) do
      parts[#parts + 1] = chunk_text(chunk)
    end
    return table.concat(parts)
  end
  local found_cnt, found_body = false, false
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, { details = true })) do
    local d = m[4] or {}
    local vt = d.virt_text and d.virt_text[1] and d.virt_text[1][1] or ''
    if vt:find('\u{EA6B}', 1, true) ~= nil and m[2] == 2 then
      found_cnt = true
    end
    for _, vl in ipairs(d.virt_lines or {}) do
      if line_text(vl):find(body, 1, true) ~= nil then
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

  -- panel <CR> で 2 ファイル目 (b.lua) へ (open だけではマークは付かない + focus は panel 維持)
  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_cursor(panel_win, { panel_row('file', 'b.lua'), 0 })
  local cr = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
  vim.cmd('normal ' .. cr)
  wait_for(function()
    return win_buf_name(windows.win 'head') == realpath(vim.fs.joinpath(top, 'b.lua'))
      and windows.role_of(vim.api.nvim_get_current_win()) == 'panel'
  end, 'b.lua head 実ファイル + focus panel 維持')
  -- 変更ファイルの base 窓 = review://base scratch に git show main:b.lua。
  -- (追加 A の 0 行 scratch / 削除・binary 告知の張り分けは session_spec が unit pin)
  local b_base_buf = vim.api.nvim_win_get_buf(windows.win 'base')
  if win_buf_name(windows.win 'base') ~= 'review://base/main--feature/b.lua' then
    fail('b.lua base 窓 scratch でない: ' .. win_buf_name(windows.win 'base'))
  end
  wait_for(function()
    return vim.api.nvim_buf_get_lines(b_base_buf, 0, -1, false)[1] == 'base'
  end, 'base scratch に git show main:b.lua が充填される')
  -- <CR> open だけでは行頭に [✓] は出ない (開封 != レビュー完了)
  local brow = panel_row('file', 'b.lua')
  local sb_lines = panel_lines()
  if sb_lines[brow] == nil or sb_lines[brow]:sub(1, 6) == '[✓] ' then
    fail('open だけで [✓] が付いた: ' .. tostring(sb_lines[brow]))
  end

  -- head 窓 = b.lua の実ファイル (編集可)。#18 以降はこの窓自体が実ファイルなので
  -- 別 tab に実ファイルを開く o 導線は削除された (2026-09。導線の二重化を解消)。
  local b_real = realpath(vim.fs.joinpath(top, 'b.lua'))
  expect(
    win_buf_name(windows.win 'head') == b_real,
    '<CR> 後の b.lua head 窓が実ファイルでない'
  )
  expect(
    windows.role_of(vim.api.nvim_get_current_win()) == 'panel',
    '<CR> 後の focus が panel から動いている'
  )
  expect(
    vim.api.nvim_win_get_cursor(panel_win)[1] == panel_row('file', 'b.lua'),
    '<CR> 後の panel カーソルが開いたファイル行でない'
  )
  local fbuf = vim.fn.bufnr(b_real)
  local b_lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
  if b_lines[1] ~= 'feature addition' or b_lines[2] ~= 'second line' then
    fail('head 実ファイル内容不一致: ' .. table.concat(b_lines, ' / '))
  end
  if vim.bo[fbuf].readonly then
    fail 'head 実ファイルが read-only (編集可でなければならない)'
  end
  print 'E2E-O1 fileview=real-editable'
  -- b.lua に x でマーク付与 (focus は head 窓へ戻す)
  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_cursor(panel_win, { brow, 0 })
  vim.cmd 'normal x'
  wait_for(function()
    local l = panel_lines()[brow]
    return l ~= nil and l:sub(1, 6) == '[✓] '
  end, 'x で b.lua 行に [✓]')
  vim.api.nvim_set_current_win(head_win)
  print 'E2E-VW x=mark'

  -- 移動キー (最終キー表 #18 の表示順版): <S-Tab> で a.lua -> ]F 最後 (b.lua) ->
  -- [F 最初 (src/deep/new.lua, ツリーは dir 先行) -> <Tab>/<S-Tab> 往復
  -- -> i で閲覧 float -> 閉じる -> <leader>e で panel focus
  vim.api.nvim_set_current_win(windows.win 'head')
  local stab = vim.api.nvim_replace_termcodes('<S-Tab>', true, true, true)
  vim.cmd('normal ' .. stab)
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win()) == realpath(vim.fs.joinpath(top, 'a.lua'))
  end, '<S-Tab> で a.lua head 実ファイル')
  print 'E2E-M1 S-Tab=prev'
  vim.cmd 'normal ]F'
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win()) == realpath(vim.fs.joinpath(top, 'b.lua'))
  end, ']F で最後のファイル b.lua (ツリー表示順の末尾)')
  print 'E2E-M2 ]F=last'
  vim.cmd 'normal [F'
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win())
      == realpath(vim.fs.joinpath(top, 'src/deep/new.lua'))
  end, '[F で最初のファイル src/deep/new.lua (ツリーは dir 先行)')
  print 'E2E-M3 [F=first'
  -- 追加ファイル (A) は base = 0 行 scratch とのペアなので両窓 diffoff
  -- (全行 DiffAdd の塗りつぶしを作らない — issue #38。a.lua (M) の窓 diff 有効が
  -- 上の L1 ループで陰性対照になる)。名前は変更ファイルと同じ review://base
  -- (issue #39。種別は winbar の (new file) で分かる)
  local nbase = windows.win 'base'
  if win_buf_name(nbase) ~= 'review://base/main--feature/src/deep/new.lua' then
    fail('new.lua base 窓の scratch 名が不正: ' .. win_buf_name(nbase))
  end
  if vim.wo[windows.win 'head'].diff or vim.wo[nbase].diff then
    fail '追加ファイル (new.lua) で窓 diff が有効 (diffoff 契約違反)'
  end
  local nbar = vim.w[windows.win 'head'].review_winbar or ''
  if nbar:find('new file', 1, true) == nil then
    fail('head winbar に new file マークが無い: ' .. nbar)
  end
  print 'E2E-A1 diffoff=newfile'
  -- <Tab> 次ファイル (押下は 0 接頭で渡す = :normal の引数先頭 whitespace 回避。
  -- 実測で 0<Tab> 注入の発火を確認済み)。表示順 [new.lua, a.lua, b.lua] を辿る。
  local tab_key = vim.api.nvim_replace_termcodes('<Tab>', true, false, true)
  vim.cmd('normal 0' .. tab_key)
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win()) == realpath(vim.fs.joinpath(top, 'a.lua'))
  end, '<Tab> で a.lua')
  print 'E2E-M4 Tab=next'
  vim.cmd('normal 0' .. stab)
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win())
      == realpath(vim.fs.joinpath(top, 'src/deep/new.lua'))
  end, '<S-Tab> で src/deep/new.lua 復帰')
  -- 続くコメント閲覧 float は 2 行以上ある a.lua で行う (new.lua は 1 行)
  vim.cmd('normal 0' .. tab_key)
  wait_for(function()
    return win_buf_name(vim.api.nvim_get_current_win()) == realpath(vim.fs.joinpath(top, 'a.lua'))
  end, 'コメント閲覧前の a.lua 復帰')
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
  -- <leader>e (= \ + e)。[[..]] のロングブラケットで Lua エスケープ不经由にする
  -- ("\e" は Lua では不正 escape で spec 側が壊れるため)
  vim.cmd [[normal \e]]
  wait_for(function()
    return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
      == 'review://sidebar/main--feature'
  end, '<leader>e で panel focus')

  -- panel 起点の <Tab> も <CR> と同じく focus を panel に維持する (issue #36)。
  -- 上の head 窓起点の移動シーケンスが focus を head に残すことの対照にもなる。
  -- 現対象 a.lua の次 = b.lua (表示順 [new.lua, a.lua, b.lua])
  vim.cmd('normal 0' .. tab_key)
  wait_for(function()
    return win_buf_name(windows.win 'head') == realpath(vim.fs.joinpath(top, 'b.lua'))
      and windows.role_of(vim.api.nvim_get_current_win()) == 'panel'
  end, 'panel 起点の <Tab> で b.lua 張替 + focus panel 維持')
  print 'E2E-M5 Tab-from-panel=focus-kept'

  -- --- prompt yank (ai-prompt.md テスト方針 golden path) -------------------
  -- b.lua (head 実ファイル) で視覚選択 range コメントを作り (既知の制約: :normal
  -- の視覚選択は Vj -> c の分割投入が単位)、y で "0、:Review prompt で全文照合。
  -- 期待値は docs/design/features/ai-prompt.md の書式から手で書いた正本
  -- (生成 code を呼ばない = 循環検証回避)。b.lua 恒等行: 1 / 2 行とも new 側。
  -- panel の `l` (<CR>/o/l = entry を開く #18) で b.lua を開く経路を使う。
  -- panel <CR>/o/l は focus を panel に維持するので、打鍵は head 窓へ移ってから行う。
  vim.api.nvim_set_current_win(windows.win 'panel')
  vim.api.nvim_win_set_cursor(windows.win 'panel', { panel_row('file', 'b.lua'), 0 })
  vim.cmd 'normal l'
  wait_for(function()
    return win_buf_name(windows.win 'head') == b_real
      and windows.role_of(vim.api.nvim_get_current_win()) == 'panel'
  end, 'l で b.lua head 張替 + focus panel 維持 (range 用)')
  local b_win = windows.win 'head'
  vim.api.nvim_set_current_win(b_win)
  vim.api.nvim_win_set_cursor(b_win, { 1, 0 })
  vim.cmd 'normal Vj'
  vim.cmd 'normal c'
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative ~= ''
  end, 'range コメント float open')
  vim.cmd 'normal iprefer early return'
  vim.cmd('normal ' .. cy)

  -- 範囲コメント (1..2) のスレッド mark は最終行の下 (row == end_line-1) に来て、
  -- 下線 mark と分かれる (diff-review「コメント表示」。旧契約は開始行の下)
  wait_for(function()
    local dmarks = vim.api.nvim_buf_get_extmarks(fbuf, ns, 0, -1, { details = true })
    for _, m in ipairs(dmarks) do
      if m[4].virt_text ~= nil and m[2] == 1 then
        return true
      end
    end
    return false
  end, '範囲コメントのスレッド mark が最終行 (row 1) に来る')
  local underlines = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, ns, 0, -1, { details = true })) do
    if m[4].virt_text == nil and m[4].hl_group == 'ReviewCommentLine' then
      underlines = underlines + 1
      if m[2] ~= 0 or m[4].end_row ~= 1 then
        fail '範囲コメントの下線 mark が 1..2 行を覆っていない'
      end
    end
  end
  if underlines ~= 1 then
    fail('範囲コメントの下線 mark が 1 本でない: ' .. tostring(underlines))
  end

  -- provider 無し退路の WARN を決定的に pin する: macOS の既定 pbcopy provider は
  -- provider#clipboard#Call として検出されるため (2026-09 修正)、ログの WARN だけを
  -- 見ると環境で結果が変わる。検出元 4 系統をこのプロセスで落としてから yank する
  -- (有り経路は unit spec が provider autoload 配置で決定的に pin する)。
  vim.g.clipboard = vim.NIL
  vim.cmd 'silent! delfunction clipboard#copy'
  vim.cmd 'silent! delfunction provider#clipboard#Call'
  vim.g.loaded_clipboard_provider = 0
  package.preload.clipboard = nil
  package.loaded.clipboard = nil
  require('review.handlers.prompt')._set_clipboard_probe(function()
    return false
  end)

  -- y: range 内の行 (2 行目) で見出しなし本文を "0 にコピー
  vim.api.nvim_set_current_win(b_win)
  vim.api.nvim_win_set_cursor(b_win, { 2, 0 })
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
