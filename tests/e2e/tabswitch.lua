-- E2E review tab を離れたときの winbar 領域解放 (diff-review「窓装飾 (chrome)」)。
-- 契約: global winbar 式は「現在の tab に w:review_winbar を持つ窓がある間」だけ
-- 入る (式が非空だと空評価でも窓に 1 行確保される — 実 PTY 実測)。
--   review tab で式が入る -> 無関係な user tab へ移ると式が空 -> w:review_winbar は
--   保持 -> review tab へ戻ると式が再適用。
-- headless は winheight に winbar を反映しないため、行の解放そのものは実 PTY で
-- 別途実測し、ここでは式の有無と窓変数の保持を契約として pin する。
-- 失敗は E2E-FAIL + cquit (契約は phase1 と同一)。

local windows = require 'review.ui.windows'

local PLUGIN_WINBAR = '%{get(w:,"review_winbar","")}'

local function fail(why)
  print('E2E-FAIL: ' .. why)
  vim.cmd 'cquit!'
end

local function wait_for(pred, why)
  if not vim.wait(8000, pred, 20) then
    fail('timeout: ' .. why)
  end
end

local function global_winbar()
  return vim.api.nvim_get_option_value('winbar', { scope = 'global' })
end

local run = function()
  local user_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd 'Review start main feature'
  wait_for(function()
    local hw = windows.win 'head'
    return hw ~= nil and vim.w[hw].review_winbar ~= nil
  end, '開通 + chrome 適用 (head winbar)')

  local review_tab = windows.state().tab
  if review_tab == user_tab then
    fail '前提: レビューは専有 tab (ユーザー tab でない)'
  end
  if global_winbar() ~= PLUGIN_WINBAR then
    fail('review tab で global winbar 式が入っていない: ' .. vim.o.winbar)
  end
  local head_win = windows.win 'head'
  local head_bar = vim.w[head_win].review_winbar

  -- review.nvim とは無関係のユーザー tab へ移る (式が残ると空ヘッダー行が確保される)
  vim.api.nvim_set_current_tabpage(user_tab)
  if global_winbar() ~= '' then
    fail('user tab で global winbar 式が残っている: ' .. vim.o.winbar)
  end
  if vim.w[head_win].review_winbar ~= head_bar then
    fail '離れた tab で head 窓の w:review_winbar が失われた'
  end

  -- review tab へ戻ると再適用される
  vim.api.nvim_set_current_tabpage(review_tab)
  if global_winbar() ~= PLUGIN_WINBAR then
    fail('review tab へ戻っても式が再適用されない: ' .. vim.o.winbar)
  end

  print 'E2E-TSW1 away=cleared back=restored vars=kept'
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
