-- E2E レビュー tab の直接消滅経路 (b) / diff-review「レビュー tab の消滅経路」。
-- 契約化されていない「閉じる」= ユーザーが :tabclose で専有 tab を直接閉じたとき:
--   TabClosed フックが save (status=open 維持) + extmark namespace clear + active
--   解除 + INFO «レビュー tab を閉じました…» を行う (close と解釈しない)。
-- 実 git + 実 float 打鍵での接線を pin する (unit の応答スタブでは観測できない
-- 経路)。INFO 語句のログ出現は shell 側 grep (陽性対照)。
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

local function realpath(p)
  return vim.uv.fs_realpath(p) or p
end

local run = function()
  local user_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd 'Review start main feature'
  wait_for(function()
    return vim.fn.bufexists 'review://sidebar/main--feature' == 1
  end, '開始 (sidebar main--feature)')
  local top =
    realpath((vim.fn.system { 'git', 'rev-parse', '--show-toplevel' } or ''):gsub('[\r\n]+$', ''))

  -- extmark 残骸検査の対象にする実ファイルバッファへ、head 窓打鍵でコメントを
  -- 1 件張っておく (:tabclose 前に残骸 > 0 の状態を作らないと clear を検証できない)。
  local head_win = windows.win 'head'
  local a_buf = vim.api.nvim_win_get_buf(head_win)
  if vim.api.nvim_buf_get_name(a_buf) ~= realpath(vim.fs.joinpath(top, 'a.lua')) then
    fail(
      '前提の head 実ファイル窓が壊れている: ' .. vim.api.nvim_buf_get_name(a_buf)
    )
  end
  vim.api.nvim_win_set_cursor(head_win, { 3, 0 })
  vim.cmd 'normal c'
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative ~= ''
  end, 'comment float open')
  local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
  local crn = vim.api.nvim_replace_termcodes('<CR>', true, true, true)
  vim.cmd('normal ' .. 'i' .. 'survives tabclose' .. esc .. crn)
  local ns = vim.api.nvim_get_namespaces()['review_comment']
  wait_for(function()
    return ns ~= nil and #vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, {}) == 1
  end, 'コメント extmark 1 件 (張られた状態)')

  local review_tab = windows.state().tab
  if review_tab == user_tab then
    fail '前提: レビューは専有 tab (ユーザー tab でない)'
  end

  -- 契約化されていない閉じ方: :tabclose (レビュー tab が現在の tab のまま実行)。
  vim.api.nvim_set_current_tabpage(review_tab)
  vim.cmd 'tabclose'
  wait_for(function()
    return not vim.api.nvim_tabpage_is_valid(review_tab)
  end, 'tabclose 後のレビュー tab 消滅')

  -- (a) active 解除 (再 render 対象が残っていない)
  local session_handler = require 'review.handlers.session'
  wait_for(function()
    return session_handler.active() == nil
  end, 'TabClosed 後の active 解除')

  -- (b) extmark namespace 残骸 0 (張った実ファイルバッファ側の実測)。
  if not vim.api.nvim_buf_is_valid(a_buf) then
    fail 'tabclose でユーザー閲覧用の実ファイルバッファまで wipe された'
  end
  local debris = #vim.api.nvim_buf_get_extmarks(a_buf, ns, 0, -1, {})
  if debris ~= 0 then
    fail('tabclose 後の extmark 残骸が ' .. debris .. ' (期待 0)')
  end

  -- (c) close ではなく save: status=open がディスクの JSON に残る (MUST 2)。
  local jsons = vim.fn.glob(
    (vim.fn.stdpath 'data') .. '/review.nvim/sessions/*/main--feature.json',
    false,
    true
  )
  if #jsons ~= 1 then
    fail('セッション JSON が ' .. #jsons .. ' 件 (期待 1)')
  end
  local sess = vim.json.decode(table.concat(vim.fn.readfile(jsons[1]), '\n'))
  if sess.status ~= 'open' then
    fail('tabclose 後の status が ' .. tostring(sess.status) .. ' (期待 open)')
  end
  if #sess.comments ~= 1 then
    fail('tabclose で保存 comments が失われた: ' .. vim.inspect(#sess.comments))
  end
  if sess.comments[1].body ~= 'survives tabclose' or sess.comments[1].line ~= 3 then
    fail('tabclose 後の保存コメントが不一致: ' .. vim.inspect(sess.comments[1]))
  end

  -- (d) global winbar が元 (空) へ戻る: ユーザー窓が 2 窓以上のとき empty の
  -- ヘッダー行が残る掃除漏れ (実測のユーザー報告) の回帰 pin。
  if vim.o.winbar ~= '' then
    fail('tabclose 後に global winbar が戻っていない: ' .. vim.o.winbar)
  end

  print 'E2E-TB1 status=open extmarks=0 winbar=restored'
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
