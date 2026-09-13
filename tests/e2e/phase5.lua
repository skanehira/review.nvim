-- E2E phase 5 (保存時リフレッシュ的最小シナリオ / issue-15「リフレッシュ (未コミット
-- 反映契約)」)。cwd = fixture repo で実行される (新規 XDG data dir 起動 = 保存
-- セッションなし -> 継承確認を踏まない)。
-- :Review start main feature -> repo 内 b.lua をレビュー窓とは別窓で編集 -> :write
-- -> BufWritePost の自動再取得で sidebar の ±カウントが +2 -> +3 に変わる。
-- さらに未保存の 1 行追記ではカウントが動かないこと (保存済み内容基準の二重基準)
-- も確認する。最後に disk だけを外部で戻して head 窓で `R` を打ち、panel が
-- +3 -> +2 になること (手動リフレッシュ = automatic refresh を通さない再取得経路)
-- を確認する。成否の目証は E2E-R1 / E2E-R2 行を print し、scripts/e2e.sh が
-- assert する。失敗は E2E-FAIL を stdout へ出して cquit (-c 実行中の error 素出しは
-- headless で入力待ちハングになるため pcall 経由で正規化する。契約は phase1 と同一)。

local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local function wait_for(pred, why)
  if not vim.wait(8000, pred, 20) then
    fail('timeout: ' .. why)
  end
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

  -- 基準: 開始時の b.lua 行 (feature で base 1 行を 2 行に置換 = +2 -1)。
  -- この値を保存前に見ることで「カウントが変わっていない」の陰性対照になる。
  local row0 = sidebar_row 'b.lua'
  if row0 ~= 'M b.lua +2 -1' then
    fail('開始直後の b.lua 行が不一致: ' .. tostring(row0))
  end

  -- 実ファイルを開いて編集 -> :write (レビュー窓の外から書かれた同一パスの
  -- バッファイベント = diff-review「リフレッシュ」1 の trigger)。
  local repo = vim.trim(vim.fn.system { 'git', 'rev-parse', '--show-toplevel' })
  vim.cmd(('silent edit %s'):format(vim.fn.fnameescape(repo .. '/b.lua')))
  vim.cmd 'normal! othird line'
  vim.cmd 'silent write'

  wait_for(function()
    return sidebar_row 'b.lua' == 'M b.lua +3 -1'
  end, '保存後の ±カウント自動リフレッシュ (+2 -> +3)')
  print 'E2E-R1 counts=updated'

  -- 未保存編集はカウントに反映されない (保存済み内容基準)。窓での追記から
  -- 一定時間待っても panel は +3 のまま = 自動再取得が保存時に限定されている。
  vim.cmd 'normal! ofourth line (unsaved)'
  vim.wait(300, function()
    return sidebar_row 'b.lua' == 'M b.lua +4 -1'
  end)
  local row_unsaved = sidebar_row 'b.lua'
  if row_unsaved ~= 'M b.lua +3 -1' then
    fail('未保存編集がカウントに混入した: ' .. tostring(row_unsaved))
  end

  -- 手動 `R` (issue #18 で登録されたレビュー窓のキー)。 BufWritePost を通さない
  -- 再取得経路の陽性対照: disk を外部で feature commit 相当 (2 行) へ戻しても
  -- panel は +3 のまま -> head 窓で R -> +2 -1 へ変わる。
  -- 前提: 生 `:edit` で開いた buffer にはレビューキーが張られない (gate 不成立 =
  -- drift)。まず panel <CR> (open_file 共通処理) で b.lua を開き直し、張込と窓
  -- gate を復旧してから打鍵する (diff-review「drift 復旧」の経路そのもの)。
  local windows = require 'review.ui.windows'
  local filepanel = require 'review.ui.filepanel'
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
  wait_for(function()
    return windows.role_of(vim.api.nvim_get_current_win()) == 'head'
  end, 'panel <CR> で b.lua head 窓 (gate 復旧)')
  local out_rb = vim.fn.system { 'git', 'checkout', '--', 'b.lua' }
  if vim.v.shell_error ~= 0 then
    fail('R 用の git checkout 失敗: ' .. out_rb)
  end
  -- 未保存編集は用済みなので読み直して FileChangedShell プロンプトを黙らせる
  -- (read なので BufWritePost は走らない = 自動リフレッシュ不经由のまま disk だけ
  -- 2 行基準へ戻せた状態を作る)。panel が +3 据え置きからの R での変化が対照。
  vim.cmd 'silent edit! b.lua'
  vim.api.nvim_set_current_win(windows.win 'head')
  -- open_file は viewed=true にするので行頭に [✓] が付く (needle は行内含一致)。
  local function b_row_has(cnt)
    local row = sidebar_row 'b.lua'
    return row ~= nil and row:find('b.lua ' .. cnt, 1, true) ~= nil
  end
  vim.cmd 'normal R'
  wait_for(function()
    return b_row_has '+2 -1'
  end, '手動 R で disk 基準の再取得 (+3 -> +2)')
  print 'E2E-R2 manual-refresh=ok'

  -- 後片付け: 保存済みの 1 行追加をディスクから戻す (以降のシナリオが同じ
  -- fixture を前提にできるよう作業ツリーを保存開始前に復元する)。
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
