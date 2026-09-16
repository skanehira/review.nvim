-- E2E 復元時の head 解決再評価 / MUST 2 証跡の後半 (DESIGN 決定表「起動時復元」
-- 「復元時も head 解決フロー (switch 提案/scratch 縮退) を通す」、persistence-restore
-- 「復元手順」)。session JSON の refs は不変で、現在の checkout と session.head の
-- 関係だけ変えて、復元後の窓.kind が scratch/実ファイルへ切り替わることを実測する。
-- (コメント位置・viewed の跨プロセス一致は phase2 が同じ fixture 系統で pin 済み)
--
-- 実行は scripts/e2e.sh の順:
--   REVIEW_E2E_RMODE=real-start   : checkout feature -> :Review start main feature
--                                   -> head 窓 == 実ファイル (土台状態の作込)
--   REVIEW_E2E_RMODE=scratch-re   : checkout main    -> :Review 復元 -> 提案 n 応答
--                                   -> head/base とも review://head|base scratch
--   REVIEW_E2E_RMODE=real-resto   : checkout feature -> :Review 復元 -> 提案なしで
--                                   head 窓 == 実ファイルへ戻る (縮退 -> 通常)
-- 失敗は E2E-FAIL + cquit (契約は phase1 と同一)。

local windows = require 'review.ui.windows'

local rmode = assert(os.getenv 'REVIEW_E2E_RMODE', 'REVIEW_E2E_RMODE 未設定')

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

local function git(args)
  local out = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait(10000)
  if out.code ~= 0 then
    fail('git ' .. table.concat(args, ' ') .. ' 失敗: ' .. (out.stderr or ''))
  end
  return (out.stdout or ''):gsub('[\r\n]+$', '')
end

local function wait_resume_notify()
  local log_path = os.getenv 'REVIEW_E2E_LOG'
  wait_for(function()
    local f = log_path ~= nil and io.open(log_path, 'r')
    if f == nil then
      return false
    end
    local text = f:read '*a' or ''
    f:close()
    return text:find('review.nvim: main--feature のレビューが続けられます', 1, true)
      ~= nil
  end, 'VimEnter 継続 notify')
end

local function head_buf_name()
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, '復元/開始 sidebar main--feature')
  wait_for(function()
    return windows.state() ~= nil and windows.win 'head' ~= nil
  end, '復元/開始 3 窓')
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(windows.win 'head'))
end

local run = function()
  local top = realpath(git { 'rev-parse', '--show-toplevel' })

  if rmode == 'real-start' then
    -- 通常経路のセッションを作る (checkout==head なので提案は出ない)。
    git { 'checkout', '-q', 'feature' }
    local offers = 0
    require('review.handlers.session')._set_confirm(function(_, cb)
      offers = offers + 1
      cb(false)
    end)
    vim.cmd 'Review start main feature'
    local hb = head_buf_name()
    if offers ~= 0 then
      fail('real-start で switch 提案が出た (HEAD==head のはず): ' .. tostring(offers))
    end
    if hb ~= realpath(vim.fs.joinpath(top, 'a.lua')) then
      fail('real-start の head 窓が実ファイルでない: ' .. hb)
    end
    print 'E2E-RR1 mode=real-start head=real'
    vim.cmd 'qa'
    return
  end

  -- 復元 2 ラウンドは checkout を先に寄せてから :Review 1 操作。
  if rmode == 'scratch-restore' then
    git { 'checkout', '-q', 'main' }
    wait_resume_notify()
    local offers = 0
    require('review.handlers.session')._set_confirm(function(_, cb)
      offers = offers + 1
      cb(false)
    end)
    vim.cmd 'Review'
    local hb = head_buf_name()
    local bb = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(windows.win 'base'))
    if offers ~= 1 then
      fail('scratch-restore で switch 提案が再評価されない (回数 ' .. offers .. ')')
    end
    if hb ~= 'review://head/main--feature/a.lua' then
      fail('復元時に head 窓が scratch 化していない (checkout!=head): ' .. hb)
    end
    if bb ~= 'review://base/main--feature/a.lua' then
      fail('復元時に base 窓 scratch が壊れた: ' .. bb)
    end
    if git { 'rev-parse', '--abbrev-ref', 'HEAD' } ~= 'main' then
      fail 'n 応答の復元で checkout が動いた (INV-3)'
    end
    print 'E2E-RR2 mode=scratch-restore windows=scratch'
    vim.cmd 'qa'
    return
  end

  if rmode == 'real-restore' then
    git { 'checkout', '-q', 'feature' }
    wait_resume_notify()
    local offers = 0
    require('review.handlers.session')._set_confirm(function(_, cb)
      offers = offers + 1
      cb(false)
    end)
    vim.cmd 'Review'
    local hb = head_buf_name()
    if offers ~= 0 then
      fail(
        'real-restore で switch 提案が出た (checkout==head のはず): ' .. tostring(offers)
      )
    end
    if hb ~= realpath(vim.fs.joinpath(top, 'a.lua')) then
      fail('復元時に scratch 窓が実ファイルへ戻らない: ' .. hb)
    end
    local hbuf = vim.api.nvim_win_get_buf(windows.win 'head')
    if not vim.bo[hbuf].modifiable or vim.bo[hbuf].readonly then
      fail 'real-restore の head 実ファイル窓が編集不可'
    end
    print 'E2E-RR3 mode=real-restore head=real'
    vim.cmd 'qa'
    return
  end

  fail(' unknown REVIEW_E2E_RMODE: ' .. rmode)
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
