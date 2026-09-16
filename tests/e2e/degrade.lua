-- E2E head 解決フロー / scratch 縮退分支 (diff-review「開始」2、DESIGN 決定表)。
-- fixture REPO2 (checkout=main、feature 先行) で `:Review start main feature`、
-- 提案スタブの応答を n にする -> 縮退:
--   両窓 review://head|base/... scratch (head 側は read-only scratch) +
--   INFO «head の状態はチェックアウトされていません…» +
--   panel ヘッダの head 表示名は保存 head ref 名 («main..feature»、縮退のみ)。
-- 拒否で checkout が動かれないこと (INV-3: 確認を通過しなければ switch しない) も
-- 実 git 実測で pin する。INFO 語句のログ出現は shell 側 grep (陽性対照)。
-- 失敗は E2E-FAIL + cquit (契約は phase1 と同一)。

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

local function git(args)
  local out = vim.system(vim.list_extend({ 'git' }, args), { text = true }):wait(10000)
  if out.code ~= 0 then
    fail('git ' .. table.concat(args, ' ') .. ' 失敗: ' .. (out.stderr or ''))
  end
  return (out.stdout or ''):gsub('[\r\n]+$', '')
end

local run = function()
  -- 単独実行でも決定的に (先行シナリオが switch した残骸を正規化)。
  git { 'checkout', '-q', 'main' }

  local answers = { 'n' }
  local prompt_seen = nil
  local session_handler = require 'review.handlers.session'
  session_handler._set_confirm(function(prompt, cb)
    prompt_seen = prompt
    cb(table.remove(answers) == 'y')
  end)

  vim.cmd 'Review start main feature'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, '縮退開始 (sidebar main--feature)')

  if prompt_seen == nil or answers[1] ~= nil then
    fail(
      '縮退経路が switch 提案を 1 回だけ引いていない: ' .. tostring(prompt_seen)
    )
  end

  -- 両窓 scratch: head = review://head/... (読み取り専用) / base = review://base/...。
  local head_win, base_win = windows.win 'head', windows.win 'base'
  if head_win == nil or base_win == nil then
    fail '縮退後に base/head 窓が導出できない (3 窓開通)'
  end
  local head_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(head_win))
  local base_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(base_win))
  if head_name ~= 'review://head/main--feature/a.lua' then
    fail('縮退 head 窓が review://head scratch でない: ' .. head_name)
  end
  if base_name ~= 'review://base/main--feature/a.lua' then
    fail('縮退 base 窓が review://base scratch でない: ' .. base_name)
  end
  local hbuf = vim.api.nvim_win_get_buf(head_win)
  if vim.bo[hbuf].modifiable then
    fail '縮退 head scratch が modifiable (読み取り専用でなければならない)'
  end
  -- base = git show main:a.lua、head scratch = git show feature:a.lua (充填待ち)。
  wait_for(function()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(base_win), 0, -1, false)[1] == 'one'
      and vim.api.nvim_buf_get_lines(hbuf, 0, -1, false)[1] == 'ONE changed'
  end, '縮退両窓の git show 充填')

  -- panel ヘッダ: 縮退時だけ head 表示名 = 保存 ref 名 (DESIGN「file panel 表示」)。
  local sb = vim.api.nvim_buf_get_lines(vim.fn.bufnr 'review://sidebar/main--feature', 0, -1, false)
  if sb[2] ~= 'Showing changes for: main..feature' then
    fail('縮退時の panel ヘッダが ref 名表示でない: ' .. tostring(sb[2]))
  end

  -- INV-3: 拒否で checkout は動かない。
  if git { 'rev-parse', '--abbrev-ref', 'HEAD' } ~= 'main' then
    fail('n 応答で checkout が動いた: ' .. git { 'rev-parse', '--abbrev-ref', 'HEAD' })
  end

  print('E2E-DG1 scratch-pair head=' .. head_name)
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
