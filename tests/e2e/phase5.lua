-- E2E phase 5 (未コミット反映契約 / diff-review「リフレッシュ (未コミット反映契約)」)。
-- cwd = fixture repo (feature checkout)。新規 XDG data dir 起動 = 保存セッション
-- なし -> 継承確認を踏まない。契約の連鎖を head 窓内で通す:
--   :Review start main feature
--   -> panel <CR> で b.lua を head 窓 (実ファイル) に開く (gate 張込)
--   -> head 窓 2 行目で c キー -> コメント作成 (extmark + 保存)
--   -> head 窓 1 行目へ O で 1 行前置して :write (BufWritePost 自動リフレッシュ)
--      -> panel ±カウント +2 -1 -> +3 -1 (E2E-R1)
--      -> anchor 検証が直近パース結果で走り outdated 0 + 保持行が 2 -> 3 へ補正
--         (E2E-U1。検証が no-op なら行補正が起きず E2E-U2 の期待と不一致になる)
--      -> 3 行目で y -> "0 に「保存 (リフレッシュ済み) 基準」の prompt が入る
--         (E2E-U2。期待文字列は ai-prompt.md 書式から手で書いた正本)
--   -> 未保存の追記はカウントに反映されない (保存済み内容基準の二重基準)
--   -> disk だけ外部で feature commit 相当へ戻し、head 窓 R で手動再取得
--      (E2E-R2。BufWritePost を通さない再取得経路の陽性対照)
-- 失敗は E2E-FAIL を stdout へ出して cquit (-c 実行中の error 素出しは headless で
-- 入力待ちハングになるため pcall 経由で正規化する。契約は phase1 と同一)。

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

-- 編集 float 確定後の focus が head 窓へ戻っていることの検査 (戻りが遅い場合の
-- y 打鍵の取りこぼしを timeout ではなくここで失敗させる)。
local function expect_focus_head()
  wait_for(function()
    return windows.role_of(vim.api.nvim_get_current_win()) == 'head'
  end, 'コメント確定後に focus が head 窓')
end

local function sidebar_row(needle)
  local buf = vim.fn.bufnr 'review://sidebar/main--feature'
  if buf == -1 then
    return nil
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(needle, 1, true) ~= nil then
      return line
    end
  end
  return nil
end

local function run()
  vim.cmd 'Review start main feature'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, 'sidebar buffer')

  -- 基準: 開始時の b.lua 行 (feature で base 1 行を 2 行に置換 = +2 -1)。開封では
  -- マークを付けない契約なので [✓] 接頭は付かない。この値を編集前に見るのが
  -- 「カウントが変わっていない」の陰性対照になる。
  local row0 = sidebar_row 'b.lua'
  if row0 ~= 'M b.lua +2 -1' then
    fail('開始直後の b.lua 行が不一致: ' .. tostring(row0))
  end

  -- panel <CR> = open_file 共通経路で b.lua を head 窓 (実ファイル) に開く。
  -- 以降の編集・c・y・R はレビュー契約どおり head 窓内で打鍵する。
  wait_for(function()
    return windows.state() ~= nil and windows.win 'head' ~= nil
  end, '初期 3 窓')
  local pw = windows.win 'panel'
  local pbuf = vim.api.nvim_win_get_buf(pw)
  local brow = nil
  for r = 1, vim.api.nvim_buf_line_count(pbuf) do
    local e = filepanel.row_entry(pbuf, r)
    if e ~= nil and e.kind == 'file' and e.path == 'b.lua' then
      brow = r
    end
  end
  assert(brow, 'panel に b.lua 行がない')
  vim.api.nvim_set_current_win(pw)
  vim.api.nvim_win_set_cursor(pw, { brow, 0 })
  vim.cmd('normal ' .. vim.api.nvim_replace_termcodes('<CR>', true, false, true))
  local head_win
  wait_for(function()
    head_win = windows.win 'head'
    if head_win == nil or windows.role_of(head_win) ~= 'head' then
      return false
    end
    -- buffer 名は symlink 解決後 (/var -> /private/var)。末尾比較で吸収する。
    local hb = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(head_win))
    return hb:sub(-#'b.lua') == 'b.lua'
  end, 'panel <CR> で b.lua head 窓')

  -- head 窓 2 行目 (second line) で c -> コメント作成 (INV-4: CRUD 直後保存)。
  -- 打鍵契約は phase1 と同一 (:normal のみ安定。本文 -> <Esc> -> Normal <CR> 確定)。
  vim.api.nvim_win_set_cursor(head_win, { 2, 0 })
  vim.cmd 'normal c'
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative ~= ''
  end, 'comment float open')
  local body = 'keep this path explicit'
  local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
  local crn = vim.api.nvim_replace_termcodes('<CR>', true, true, true)
  vim.cmd('normal ' .. 'i' .. body .. esc .. crn)
  local b_buf = vim.api.nvim_win_get_buf(head_win)
  local ns = vim.api.nvim_get_namespaces()['review_comment']
  wait_for(function()
    return ns ~= nil and #vim.api.nvim_buf_get_extmarks(b_buf, ns, 0, -1, {}) == 1
  end, 'コメント extmark (1 件)')

  -- head 窓で 1 行目へ O (built-in 插入。review キー衝突を避ける normal!) + 前置
  -- -> :write。BufWritePost 自動リフレッシュが走る。保存後の new 側:
  --   1 prepended line / 2 feature addition / 3 second line  (base 1 行 -> +3 -1)
  -- anchor ('second line') は保存行 2 -> 3 へ補正され active が続く。
  vim.api.nvim_win_set_cursor(head_win, { 1, 0 })
  -- 単独 :normal で O -> 本文打鍵まで通す (headless の :normal は insert が継続
  -- しないため分割すると 2 段目の挿入先が崩れる。phase 既存の 'othird line' 前例)。
  vim.cmd 'normal! Oprepended line'
  vim.cmd 'silent write'

  wait_for(function()
    return sidebar_row 'b.lua' == 'M b.lua +3 -1'
  end, '保存後の ±カウント自動リフレッシュ (+2 -> +3)')
  print 'E2E-R1 counts=updated'

  -- anchor 検証 (直近パース結果 / outdated 0) + 行補正 2 -> 3。検証が no-op
  -- (保存行をそのまま置くだけ) なら line は 2 のままで次の E2E-U2 と不一致になる。
  local session_handler = require 'review.handlers.session'
  local sess = session_handler.active()
  if sess == nil or #sess.comments ~= 1 then
    fail 'リフレッシュ後の active コメント件数が 1 でない'
  end
  local c1 = sess.comments[1]
  if c1.state ~= 'active' or c1.line ~= 3 or c1.end_line ~= 3 then
    fail(
      'anchor 検証の結果が契約と違う: state='
        .. tostring(c1.state)
        .. ' line='
        .. tostring(c1.line)
    )
  end
  local mk = vim.api.nvim_buf_get_extmarks(b_buf, ns, 0, -1, { details = true })[1]
  local vt = (mk and mk[4] and mk[4].virt_text and mk[4].virt_text[1] or { [1] = '' })[1] or ''
  if vt:find('⚠', 1, true) ~= nil then
    fail('outdated 0 のはずが extmark に ⚠ が出た: ' .. vt)
  end
  print 'E2E-U1 anchor=active+corrected'

  -- 3 行目 (補正後の位置) で y -> "0 に保存基準 (リフレッシュ適用後) の prompt。
  expect_focus_head()
  vim.api.nvim_win_set_cursor(head_win, { 3, 0 })
  vim.cmd 'normal y'
  wait_for(function()
    return vim.fn.getreg '0' == '@b.lua#L3\n' .. body
  end, 'y で "0 に保存基準の prompt (@b.lua#L3)')
  print 'E2E-U2 yank=saved-baseline'

  -- 未保存編集はカウントに反映されない (保存済み内容基準)。窓で 4 行目を追記して
  -- 一定時間待っても panel は +3 のまま = 自動再取得が保存時に限定されている。
  vim.cmd 'normal! ofourth line (unsaved)'
  vim.wait(300, function()
    return sidebar_row 'b.lua' == 'M b.lua +4 -1'
  end)
  local row_unsaved = sidebar_row 'b.lua'
  if row_unsaved ~= 'M b.lua +3 -1' then
    fail('未保存編集がカウントに混入した: ' .. tostring(row_unsaved))
  end

  -- 手動 `R` (BufWritePost を通さない再取得経路の陽性対照)。disk を外部で
  -- feature commit 相当 (2 行) へ戻しても panel は +3 のまま -> head 窓で R ->
  -- +2 -1 へ変わる。未保存追記は edit! で読み捨てる (read なので BufWritePost
  -- 経由しない = disk だけ戻った対照状態を作る)。
  vim.cmd 'silent edit! b.lua'
  local out_rb = vim.fn.system { 'git', 'checkout', '--', 'b.lua' }
  if vim.v.shell_error ~= 0 then
    fail('R 用の git checkout 失敗: ' .. out_rb)
  end
  local row_before_r = sidebar_row 'b.lua'
  if row_before_r ~= 'M b.lua +3 -1' then
    fail(
      'disk 復帰後 (R 前) の panel が +3 のままではない: ' .. tostring(row_before_r)
    )
  end
  vim.api.nvim_set_current_win(head_win)
  vim.cmd 'normal R'
  wait_for(function()
    return sidebar_row 'b.lua' == 'M b.lua +2 -1'
  end, '手動 R で disk 基準の再取得 (+3 -> +2)')
  print 'E2E-R2 manual-refresh=ok'

  -- 後片付け: 保存した 1 行前置をディスクから戻す (以降のシナリオが同じ fixture
  -- を前提にできる状態へ作業ツリーを復元する)。
  vim.cmd 'silent edit! b.lua'
  local out = vim.fn.system { 'git', 'checkout', '--', 'b.lua' }
  if vim.v.shell_error ~= 0 then
    fail('fixture 復元失敗: ' .. out)
  end
  vim.cmd 'qa!'
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
