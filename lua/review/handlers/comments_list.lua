-- handlers/comments_list: 横断コメント一覧 (`review://comments/<session-id>`) の
-- 開閉とジャンプ (docs/design/features/comment-list.md「操作」「ジャンプ」/
-- docs/design/DESIGN.md「API 一覧」:Review comments)。
-- sessions_list.lua と同型: current tab に vsplit で開き、既に開いていればその窓へ
-- focus (別 tab でも切替。再 vsplit しない)。render / 行写像 / キーは ui/commentlist。
-- 一覧内の削除/編集/yank と追随 (コメント CRUD・差分再取得・絞り込みへの再 render) は
-- issue-2 の担当 (本 handler には置かない)。
local chrome = require 'review.ui.chrome'
local commentlist = require 'review.ui.commentlist'
local result = require 'review.core.result'
local session_handler = require 'review.handlers.session'
local ui_windows = require 'review.ui.windows'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

-- 一覧の render は「折畳無視・tree 固定」の表示順 (comment-list「実装の配置」) と
-- head 表示名を使う。render 直後に窓 chrome (number off / winbar) を再適用する。
local function render_into(session, win)
  local opts = {
    order = session_handler.visible_order { collapsed = {}, mode = 'tree' },
    head_display = session_handler.head_display(),
  }
  local buf = commentlist.render(session, opts)
  if vim.api.nvim_win_get_buf(win) ~= buf then
    vim.api.nvim_win_set_buf(win, buf)
  end
  chrome.window(win)
  chrome.winbar(win, commentlist.winbar(session, commentlist.shown(buf), opts))
  return buf
end

--- `<leader>c` / `:Review comments`: 一覧を current tab の vsplit に開く。
--- 既に開いていればその窓へ focus (別 tab でも tab を切替えて focus。再 vsplit
--- しない。内容は常に最新へ再 render)。active 不在は E_NOT_ACTIVE を返す
--- (WARN «アクティブなセッションがありません» はコマンド層が行う)。
function M.open()
  local session = session_handler.active()
  if session == nil then
    return result.err(
      'review.nvim: アクティブなセッションがありません',
      result.codes.E_NOT_ACTIVE
    )
  end
  local existing = commentlist.find_window(session.id)
  if existing ~= nil then
    local tab = vim.api.nvim_win_get_tabpage(existing)
    if tab ~= vim.api.nvim_get_current_tabpage() then
      vim.api.nvim_set_current_tabpage(tab)
    end
    render_into(session, existing)
    vim.api.nvim_set_current_win(existing)
    return result.ok()
  end
  vim.cmd 'vsplit'
  render_into(session, vim.api.nvim_get_current_win())
  return result.ok()
end

--- `<CR>`: カーソル行コメントの位置へジャンプ。移動前に review tab を current tab に
--- する (open_file はレビュー 3 窓前提)。review tab / active セッションが無ければ
--- WARN、binary / 削除の告知表示・現在の差分に無いファイルは移動せず WARN
--- (outdated は記録行へ移動して INFO。文言の正本は comment-list「ジャンプ」)。
function M.jump_current()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'commentlist' then
    return
  end
  local c = commentlist.row_comment(buf, vim.api.nvim_win_get_cursor(0)[1])
  if c == nil then
    return
  end
  local session = session_handler.active()
  local st = ui_windows.state()
  if session == nil or st == nil then
    notify_warn 'アクティブなセッションがありません'
    return
  end
  local file = session_handler.file_of(c.file)
  if file == nil then
    notify_warn 'このファイルは現在の差分に無いため移動できません'
    return
  end
  if file.binary == true or file.status == 'D' then
    notify_warn 'binary / 削除の告知表示のため移動できません'
    return
  end
  if c.state == 'outdated' then
    vim.notify(
      'review.nvim: コメントは outdated です。記録された行へ移動します',
      vim.log.levels.INFO
    )
  end
  local tab = st.tab
  if vim.api.nvim_tabpage_is_valid(tab) and tab ~= vim.api.nvim_get_current_tabpage() then
    vim.api.nvim_set_current_tabpage(tab)
  end
  session_handler.open_file(c.file, { line = c.line })
end

--- `q`: 一覧窓を閉じるだけ (セッション状態は変えない)。bufhidden=wipe でバッファも
--- 消え、BufUnload が一覧 state を掃除する (次回 `<leader>c` は新規 vsplit)。
function M.close_current()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'commentlist' then
    return
  end
  vim.cmd 'close'
end

return M
