-- E2E phase 5 (保存時リフレッシュ的最小シナリオ / issue-15「リフレッシュ (未コミット
-- 反映契約)」)。cwd = fixture repo で実行される (新規 XDG data dir 起動 = 保存
-- セッションなし -> 継承確認を踏まない)。
-- :Review start main feature -> repo 内 b.lua をレビュー窓とは別窓で編集 -> :write
-- -> BufWritePost の自動再取得で sidebar の ±カウントが +2 -> +3 に変わる。
-- さらに未保存の 1 行追記ではカウントが動かないこと (保存済み内容基準の二重基準)
-- も確認する。成否の目証は E2E-R1 行を print し、scripts/e2e.sh が assert する。
-- 失敗は E2E-FAIL を stdout へ出して cquit (-c 実行中の error 素出しは headless で
-- 入力待ちハングになるため pcall 経由で正規化する。契約は phase1 と同一)。

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
