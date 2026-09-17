-- handlers/comments_list: 横断コメント一覧 (`review://comments/<session-id>`) の
-- 開閉・ジャンプ・行操作 (d / e / y) と追随 (docs/design/features/comment-list.md
-- 「操作」「ジャンプ」「追随」/ docs/design/DESIGN.md「API 一覧」:Review comments)。
-- sessions_list.lua と同型: current tab に vsplit で開き、既に開いていればその窓へ
-- focus (別 tab でも切替。再 vsplit しない)。render / 行写像 / キーは ui/commentlist。
-- d / e / y は diff 窓の同名キーと同一動作 (d の arming だけは一覧専用の状態を
-- 持ち、diff 窓の arming とは共有しない — comment-list「操作」)。追随の再 render は
-- コメント CRUD / 差分再取得 / 絞り込み適用の 3 経路から M.refresh が呼ばれる。
local comment_model = require 'review.core.comment'
local chrome = require 'review.ui.chrome'
local commentlist = require 'review.ui.commentlist'
local prompt_handler = require 'review.handlers.prompt'
local result = require 'review.core.result'
local session_handler = require 'review.handlers.session'
local ui_input = require 'review.ui.input'
local ui_windows = require 'review.ui.windows'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

local now = os.time

--- テストフック: 時刻針の注入 (nil で本物へ戻す)。d の arming 窓の検証用。
function M._set_now(fn)
  now = fn or os.time
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

-- 一覧のカーソル行コメント («コメントはありません» 行・範囲外・非一覧 buffer は nil)。
local function current_comment()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'commentlist' then
    return nil
  end
  return commentlist.row_comment(buf, vim.api.nvim_win_get_cursor(0)[1])
end

--- 操作の共通前段: 一覧 buffer の行コメントと active セッションを解決する。
--- stale な一覧窓 (close 済みの残骸) はここで弾く。
local function target_comment()
  local c = current_comment()
  if c == nil then
    return nil
  end
  local session = session_handler.active()
  if session == nil then
    notify_warn 'アクティブなセッションがありません'
    return nil
  end
  return c, session
end

-- 削除 arming (M.delete_current が消費)。diff 窓の arming とは共有しない一覧専用の
-- 状態 (comment-list「操作」)。「同じ comment id・2 秒内」の 2 回目で確定し、
-- arming は編集確定と削除確定で解除される (diff 窓と同じ規則)。
local DELETE_ARM_WINDOW_S = 2.0
local delete_armed = nil

--- `d`: カーソル行コメントを arming 二重押しで削除する (1 コメント = 1 行なので
--- 対象は常に 1 件)。確定で session を永続化し、削除通知は diff 窓と同文言
--- (comment-list「操作」)。追随の再 render は commit_comment_change 経由。
function M.delete_current()
  local c, session = target_comment()
  if c == nil then
    return
  end
  local t = now()
  if
    delete_armed ~= nil
    and delete_armed.id == c.id
    and t - delete_armed.at <= DELETE_ARM_WINDOW_S
  then
    delete_armed = nil
    local removed = comment_model.remove(session.comments, c.id)
    if removed == nil then
      return
    end
    session_handler.commit_comment_change()
    vim.notify(
      ('review.nvim: コメント %s を削除しました'):format(removed.id),
      vim.log.levels.INFO
    )
    return
  end
  delete_armed = { id = c.id, at = t }
  notify_warn(
    ('コメント %s を削除するには、この行で d をもう一度 (取り消しは他行へ移動か 2 秒待機)'):format(
      c.id
    )
  )
end

--- `e`: カーソル行コメントを編集する (diff `e` と同じ入力 float。確定で session
--- 永続化 + 追随)。1 コメント = 1 行なので vim.ui.select は挟まない。
function M.edit_current()
  local c, session = target_comment()
  if c == nil then
    return
  end
  ui_input.open {
    value = c.body,
    hint = c.file
      .. ':'
      .. (c.line == c.end_line and tostring(c.line) or (c.line .. '-' .. c.end_line)),
    on_confirm = function(body)
      comment_model.update(session.comments, c.id, body)
      session_handler.commit_comment_change()
      -- comment_model.update は同一 table を書き換える (id 一致の arming が続く)
      -- ため、契約どおり明示解除する (diff 窓と同じ)。
      delete_armed = nil
    end,
  }
end

--- `y`: カーソル行 1 件の prompt (見出しなし) を "0 (+クリップボード) へコピー。
--- outdated はプロンプト側が既定除外し INFO を出す (ai-prompt.md「出力経路」)。
function M.yank_current()
  local c, session = target_comment()
  if c == nil then
    return
  end
  prompt_handler.for_line(session, { c })
end

--- 追随: 一覧窓が表示中のときだけ再 render する (非表示は開く時に最新を render
--- する — comment-list「追随 (再 render)」)。コメント CRUD
--- (commit_comment_change) / 差分再取得 (apply_refresh) / 絞り込み適用
--- (filter_sidebar) の 3 経路から呼ばれる。カーソル追従 (comment id) は render の
--- 契約に任せる — 削除で選択行が消えた場合は同じ行位置の次コメントへ寄る。
function M.refresh()
  local session = session_handler.active()
  if session == nil then
    return
  end
  local win = commentlist.find_window(session.id)
  if win == nil or not vim.api.nvim_win_is_valid(win) then
    return
  end
  render_into(session, win)
end

return M
