-- review UI 窓の chrome 設定 (GitHub 風の winbar 表示と diff 窓の行番号 off)。
-- winbar は window-local に set すると global オプションへ漏れて無関係な窓へ
-- 影響する (実測: set winbar の初回代入が global を書き換える = 0.10/0.13
-- 共通)。そのため global winbar は「窓変数を読むだけ読む」式を設定し、表示内容は
-- 各レンダラが w:review_winbar に保持する。b: 変数は実ファイル窓からユーザー窓・
-- 他 tab の winbar へ漏れるため使わない (窓単位が正 —
-- docs/design/features/diff-review.md「窓装飾 (chrome)」)。
-- 式が非空だと空評価でも窓は 1 行の winbar 領域を確保する (実 PTY 実測:
-- w:review_winbar 未設定でも winheight が 1 減る)。そのため式は「今いる tab に
-- w:review_winbar を持つ窓がある間」だけ入れ (TabEnter で sync_tab)、review 外 tab
-- へ移ったら式を空へ戻す。窓変数は保持し、review tab へ戻ると再適用される。
-- ユーザーが自分で winbar を設定している場合は触らない。review セッションが
-- 閉じたとき (q close / review tab 消滅) と、review セッションが無い状態で
-- `:Review list` の一覧窓 (review tab 外) が閉じたときは restore_global で空へ
-- 戻し、残った窓変数も掃除する。戻さないとユーザー窓が 2 窓以上のレイアウトで
-- 空のヘッダー行が残る (実測のユーザー報告)。
local config = require 'review.config'

local M = {}

local PLUGIN_WINBAR = '%{get(w:,"review_winbar","")}'

-- global winbar の書込 / 復元は scope=global の API で行う。:set / vim.o 代入は
-- global-local option の current window ローカル値まで書き、ユーザー窓へ漏れる
-- (実測教訓)。復元対象は「今の global 値が自前式と一致する」場合のみ = 状態を
-- 持たない冪等判定 (ユーザー定義 / review 中の書き換えは触らない)。

--- review セッション UI を開く時に呼ぶ。config.winbar=true かつ global winbar
--- が空のときだけ自前式を入れる (冪等 / ユーザー定義を尊重)。
function M.ensure_global()
  if not config.get().winbar then
    return
  end
  if vim.api.nvim_get_option_value('winbar', { scope = 'global' }) == '' then
    vim.api.nvim_set_option_value('winbar', PLUGIN_WINBAR, { scope = 'global' })
  end
end

--- 自前式が入っていれば global winbar を空へ戻す (窓変数は触らない)。式が非空
--- だと空評価でも窓に 1 行確保されるため、review バーの窓が 1 つも見えていない
--- tab / セッション終了では式自体を戻す必要がある。冪等 / ユーザー定義は触らない。
function M.clear_global()
  if vim.api.nvim_get_option_value('winbar', { scope = 'global' }) == PLUGIN_WINBAR then
    vim.api.nvim_set_option_value('winbar', '', { scope = 'global' })
  end
end

--- 今いる tab に w:review_winbar を持つ窓があるか。
local function current_tab_has_review_winbar()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].review_winbar ~= nil then
      return true
    end
  end
  return false
end

--- 現在 tab 追従: review バーの窓がある間だけ global 式を維持する。無ければ式を
--- 空へ戻す (窓変数は保持 — review tab へ戻ったときの再適用は TabEnter が行う)。
function M.sync_tab()
  if current_tab_has_review_winbar() then
    M.ensure_global()
  else
    M.clear_global()
  end
end

--- review セッションが閉じたとき (q close / review tab 消滅) に呼ぶ。式を空へ戻し
--- (clear_global)、残った窓変数の表示文字列も全窓から掃除する。変数を残す意味は
--- 無く、次の review で stale バーとして再表示される。冪等 / ユーザー定義は触らない。
function M.restore_global()
  M.clear_global()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    vim.w[win].review_winbar = nil
  end
end

--- review セッション (専有 tab) が開いていないときだけ restore_global。`:Review list`
--- の一覧窓は review tab 外 (current tab の vsplit) に開くため tab 消滅経路
--- (windows.close / TabClosed) に乗らず、バッファが閉じた時点でセッションが無ければ
--- 式も窓変数も不要になる。windows は循環回避のため遅延 require する。
function M.restore_global_if_unused()
  local windows = require 'review.ui.windows'
  if windows.state() == nil then
    M.restore_global()
  end
end

--- review 専用窓 (diff / sidebar / list) に chrome を当てる。
--- number=false (既定) のとき窓単位で行番号を消す (global は触らない)。
function M.window(win)
  if win ~= nil and vim.api.nvim_win_is_valid(win) and not config.get().number then
    -- nvim_win_set_option / vim.wo[w] は number で global 側にも波及する
    -- (nvim_win_set_option の scope=local でも実測で global 窓が変化する)。
    -- 当該窓で :setl を実行する win_call 経路を使い、窓の「見えている値」だけを
    -- 変える (spec も get_option_value({win}) の窓値契約で assert する)。
    vim.api.nvim_win_call(win, function()
      vim.cmd 'setl nonumber'
      vim.cmd 'setl norelativenumber'
    end)
  end
  -- 非表示 tab の窓へ chrome を再適用しても式は入れない (:wa 経由の render などで
  -- user tab 側に空ヘッダー行が戻るのを防ぐ)。現在 tab の窓だけを追従させる。
  if
    win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  then
    M.ensure_global()
  end
end

--- 窓の winbar 表示文字列を窓変数のみに保持する。winbar 表記の % をエスケープ。
--- 実ファイル窓では b: を経由するとユーザー窓・他 tab へ漏れるため窓単位 (設計決定)。
function M.winbar(win, text)
  if win == nil or not vim.api.nvim_win_is_valid(win) or text == nil then
    return
  end
  vim.w[win].review_winbar = (text:gsub('%%', '%%%%'))
end

-- review 外 tab の空ヘッダー行を残さない tab 追従フック。module load 時に 1 回だけ
-- 登録する (windows.lua と同じ流儀)。group の clear で再 require / テスト間の
-- ハンドル重複を防ぐ。
vim.api.nvim_create_autocmd('TabEnter', {
  group = vim.api.nvim_create_augroup('review_chrome', { clear = true }),
  desc = 'review.nvim: review バーの窓が無い tab では global winbar 式を戻す',
  callback = function()
    M.sync_tab()
  end,
})

return M
