-- review UI 窓の chrome 設定 (GitHub 風の winbar 表示と diff 窓の行番号 off)。
-- winbar は window-local に set すると global オプションへ漏れて無関係な窓へ
-- 影響する (実測: set winbar の初回代入が global を書き換える = 0.10/0.13
-- 共通)。そのため global winbar は「窓変数を読むだけ読む」式を 1 回設定し、
-- 表示内容は各レンダラが w:review_winbar に保持する。b: 変数は実ファイル窓から
-- ユーザー窓・他 tab の winbar へ漏れるため使わない (窓単位が正 —
-- docs/design/features/diff-review.md「窓装飾 (chrome)」)。
-- ユーザーが自分で winbar を設定している場合は触らない。review セッションが
-- 閉じたとき (q close / review tab 消滅) は restore_global で空へ戻すので、
-- セッション表示中にユーザー窓が 2 窓以上のとき empty のヘッダー行が増える分
-- だけが残る (single window では winbar 自体が表示されない = nvim 仕様)。
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

--- review セッションが閉じたとき (q close / review tab 消滅) に呼ぶ。自前式が
--- 入っていれば global を空へ戻す。戻さないとユーザー窓が 2 窓以上のレイアウトで
--- 空のヘッダー行が残る (実測のユーザー報告)。冪等 / ユーザー定義は触らない。
function M.restore_global()
  if vim.api.nvim_get_option_value('winbar', { scope = 'global' }) == PLUGIN_WINBAR then
    vim.api.nvim_set_option_value('winbar', '', { scope = 'global' })
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
  M.ensure_global()
end

--- 窓の winbar 表示文字列を窓変数のみに保持する。winbar 表記の % をエスケープ。
--- 実ファイル窓では b: を経由するとユーザー窓・他 tab へ漏れるため窓単位 (設計決定)。
function M.winbar(win, text)
  if win == nil or not vim.api.nvim_win_is_valid(win) or text == nil then
    return
  end
  vim.w[win].review_winbar = (text:gsub('%%', '%%%%'))
end

return M
