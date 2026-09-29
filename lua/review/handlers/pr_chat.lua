-- handlers/pr_chat: PR 一般コメント (conversation) の開閉・返信・追随
-- (`review://pr-chat/<session-id>`、pr-comments「一般コメント」)。
-- commentlist と同型: レビュー tab の最下部に全幅で開き (窓生成は
-- ui/windows.open_comment_list を共用)、既に開いていればその窓へ focus。
-- 返信 (`r`) は local pending の一般コメントとして session.general に追加し、
-- submit (`s`) で issues/{n}/comments へ投稿される。render は ui/prchat。
local chrome = require 'review.ui.chrome'
local prchat = require 'review.ui.prchat'
local result = require 'review.core.result'
local session_handler = require 'review.handlers.session'
local ui_input = require 'review.ui.input'
local ui_windows = require 'review.ui.windows'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

local now = os.time

local function render_into(session, win)
  local buf = prchat.render(session)
  if vim.api.nvim_win_get_buf(win) ~= buf then
    vim.api.nvim_win_set_buf(win, buf)
  end
  chrome.window(win)
  chrome.winbar(win, prchat.winbar(session, session.general or {}))
  return buf
end

--- `p` / `:Review pr-chat`: PR 一般コメント (conversation) をレビュー tab の
--- 最下部に全幅で開く (mode=pr のみ。branch は E_NOT_ACTIVE 同様の WARN)。
function M.open()
  local session = session_handler.active()
  if session == nil then
    return result.err('review.nvim: no active session', result.codes.E_NOT_ACTIVE)
  end
  if session.mode ~= 'pr' then
    notify_warn 'PR conversation is only available for PR sessions (:Review pr)'
    return result.ok()
  end
  local existing = prchat.find_window(session.id)
  if existing ~= nil then
    local tab = vim.api.nvim_win_get_tabpage(existing)
    if tab ~= vim.api.nvim_get_current_tabpage() then
      vim.api.nvim_set_current_tabpage(tab)
    end
    render_into(session, existing)
    vim.api.nvim_set_current_win(existing)
    return result.ok()
  end
  local win = ui_windows.open_comment_list()
  render_into(session, win)
  return result.ok()
end

--- `q`: pr-chat 窓を閉じるだけ (セッション状態は変えない)。
function M.close_current()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'prchat' then
    return
  end
  vim.cmd 'close'
end

--- `r`: カーソル行の一般コメントへ返信する。返信は local pending の一般コメント
--- (origin='local') として session.general に追加され、submit で issues/{n}/comments
--- へ投稿される (GitHub の conversation はフラットなので返信 = 新規投稿)。
function M.reply_current()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'prchat' then
    return
  end
  local g = prchat.row_comment(buf, vim.api.nvim_win_get_cursor(0)[1])
  if g == nil then
    return
  end
  local session = session_handler.active()
  if session == nil then
    notify_warn 'no active session'
    return
  end
  ui_input.open {
    hint = g.origin == 'gh' and ('reply to %s'):format(g.gh_user or 'gh') or 'reply to the PR',
    on_confirm = function(body)
      session.general = session.general or {}
      session.general[#session.general + 1] = {
        id = ('g%d'):format(#session.general + 1),
        origin = 'local',
        body = body,
        created_at = now(),
      }
      session_handler.commit_comment_change()
      require('review.handlers.pr_chat').refresh()
      vim.notify('review.nvim: reply saved (submit with s)', vim.log.levels.INFO)
    end,
  }
end

--- 追随: pr-chat 窓が表示中のときだけ再 render する (fetch / submit 後の
--- session.general 変化に追随。非表示は開く時に最新を render)。
function M.refresh()
  local session = session_handler.active()
  if session == nil then
    return
  end
  local win = prchat.find_window(session.id)
  if win == nil or not vim.api.nvim_win_is_valid(win) then
    return
  end
  render_into(session, win)
end

return M
