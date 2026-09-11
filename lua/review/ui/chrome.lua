-- review UI 窓の chrome 設定 (GitHub 風の winbar 表示と diff 窓の行番号 off)。
-- winbar は window-local に set すると global オプションへ漏れて無関係な窓へ
-- 影響する (実測: set winbar の初回代入が global を書き換える = 0.10/0.13
-- 共通)。そのため global winbar は「バッファに埋めた文字列を読むだけ読む」
-- 式 を 1 回設定し、表示内容は各レンダラが b:review_winbar に保持する。
-- ユーザーが自分で winbar を設定している場合は触らない。single window では
-- winbar 自体が表示されない (nvim 仕様) ので非レビュー利用時の影響は 2 窓以上
-- のとき empty の winbar 行が増える分だけ (README に注記)。
local config = require 'review.config'

local M = {}

local PLUGIN_WINBAR = '%{get(b:,"review_winbar","")}'

--- review セッション UI を開く時に呼ぶ。config.winbar=true かつ global winbar
--- が空のときだけ自前式を入れる (冪等 / ユーザー定義を尊重)。
function M.ensure_global()
  if config.get().winbar and vim.o.winbar == '' then
    vim.o.winbar = PLUGIN_WINBAR
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

--- 対象バッファの winbar 表示文字列を保持する。winbar 表記の % をエスケープ。
function M.bar(buf, text)
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) or text == nil then
    return
  end
  vim.b[buf].review_winbar = (text:gsub('%%', '%%%%'))
end

return M
