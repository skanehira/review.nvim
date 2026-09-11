-- :Review list フロー: repo の保存済みセッション一覧を開き、<Enter> で再開する
-- (persistence-restore.md「:Review list」/ 実装の配置 handlers/sessions_list.lua)。
-- repo path 消失セッションは grey 表示で行データから外す (<Enter> 不可)。
local chrome = require 'review.ui.chrome'
local git_ref = require 'review.git.ref'
local restore = require 'review.handlers.restore'
local store = require 'review.store.session'
local ui_list = require 'review.ui.list'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

local function repo_missing(sess)
  return vim.uv.fs_stat(sess.repo) == nil
end

--- 現 cwd の repo のセッション一覧を scratch split window に開く。
function M.open()
  git_ref.top_level({ cwd = vim.fn.getcwd() }, function(res)
    if not res.ok then
      notify_warn(res.error)
      return
    end
    local sessions = store.list(res.data).data
    vim.cmd 'vsplit'
    local buf = ui_list.render_sessionlist(sessions, { is_grey = repo_missing })
    vim.api.nvim_win_set_buf(0, buf)
    chrome.window(0)
  end)
end

--- 一覧のカーソル行セッションを再開 (<Enter>)。grey 行は開けない旨 WARN。
function M.open_current()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'sessionlist' then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local sess = ui_list.row_session(buf, row)
  if sess == nil then
    notify_warn 'そのセッションは repo path が存在しないため開けません'
    return
  end
  restore.resume_session(sess)
end

--- 一覧のカーソル行セッションを削除 (d)。`:Review delete` と同一の
--- 確認フロー (コメント件数 WARN + [y/N]) を経由する。grey 行 (repo path 消失)
--- は対象解決できないため WARN。
function M.delete_current()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'sessionlist' then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local sess = ui_list.row_session(buf, row)
  if sess == nil then
    notify_warn 'その行はセッションではないため削除できません (repo path 消失行は :Review delete <id> を直接)'
    return
  end
  local session_handler = require 'review.handlers.session'
  session_handler.delete(sess.id)
end

return M
