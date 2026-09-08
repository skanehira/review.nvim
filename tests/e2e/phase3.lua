-- E2E phase 3 (head 省略経路)。`:Review start main` (1 引数) -> 実 vim.ui.input
-- 既定実装 (vim.fn.input) が補完 (Tab -> customlist グローバル関数) と Enter 確定を
-- 受けつけて head を選び、セッション開始することを pin する。
-- 既定 vim.ui.input は opts に Lua 関数が混入すると E467 で黙って失敗するため
-- (DESIGN.md「既知の制約」)、この経路は mock を通さない実 UI 接続そのもの。
-- 入力は起動待ちの間に nvim_input で先入れする (headless では input() が
-- アクティブになるまで typeahead は消費されない — 実測確認済み)。

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
  local tab = vim.api.nvim_replace_termcodes('<Tab>', true, false, true)
  local cr = vim.api.nvim_replace_termcodes('<CR>', true, false, true)

  -- 'hot' + Tab (単一候補 hotfix に補完展開) + Enter に相当する typeahead。
  -- cmd 実行は非同期 git を経て input() に到達するため、先に投入して待つ。
  vim.api.nvim_input('hot' .. tab .. cr)
  vim.cmd 'Review start main'

  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--hotfix' == 1
  end, 'head 選択後の session 開始 (sidebar main--hotfix)')
  local dbuf = vim.fn.bufnr 'review://diff/main--hotfix/a.lua'
  if dbuf == -1 then
    fail 'head 選択後の先頭ファイル diff が無い'
  end
  print 'E2E-S3 head=hotfix'

  -- 後続に open セッションを残さない (コメント 0 件 = 無確認で閉じる)
  vim.cmd 'Review close'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--hotfix' == 0
  end, 'close 後 sidebar 消滅')
  vim.cmd 'qa'
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
