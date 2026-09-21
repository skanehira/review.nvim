-- :Review list フロー: repo の保存済みセッション一覧を開き、<Enter> で再開する
-- (persistence-restore.md「:Review list」/ 実装の配置 handlers/sessions_list.lua)。
-- repo path 消失セッションは grey 表示で行データから外す (<Enter> 不可)。
-- 状態変化 (全 save 経路 = session.persist、delete の finalize) から M.refresh が
-- 呼ばれ、表示中の一覧がディスクの最新状態へ追随する (issue #41)。
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

--- 一覧バッファ (review://sessions) を表示中の窓を返す。役割は内容 (review_meta)
--- から導く (バッファ名でなく meta で見る — commentlist.find_window 同型の
--- drift 対策。ユーザーが :edit 等で中身を差し替えた窓は meta が一致しない)。
local function find_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local meta = vim.b[vim.api.nvim_win_get_buf(win)].review_meta or {}
    if meta.kind == 'sessionlist' then
      return win
    end
  end
  return nil
end

--- 一覧バッファを表示中の全窓へ winbar を当て直す。行の再 render は名前で
--- 再利用されるバッファへの書き込みなので全窓に伝播するが、winbar は窓ローカル
--- なので全窓の手当てが要る (ui/list.lua の win_findbuf 走査と同型)。
local function repaint_winbars(buf, sessions)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    chrome.winbar(win, ui_list.sessionlist_winbar(sessions))
  end
end

--- 現 cwd の repo のセッション一覧を scratch split window に開く。
--- 既に開いていればその窓へ focus (再分割しない = 窓が増殖しない)。内容は常に
--- 最新へ再 render する。
function M.open()
  git_ref.top_level({ cwd = vim.fn.getcwd() }, function(res)
    if not res.ok then
      notify_warn(res.error)
      return
    end
    local sessions = store.list(res.data).data
    local existing = find_window()
    if existing ~= nil then
      ui_list.render_sessionlist(sessions, { repo = res.data, is_grey = repo_missing })
      repaint_winbars(vim.api.nvim_win_get_buf(existing), sessions)
      vim.api.nvim_set_current_win(existing)
      return
    end
    vim.cmd 'vsplit'
    local buf = ui_list.render_sessionlist(sessions, { repo = res.data, is_grey = repo_missing })
    vim.api.nvim_win_set_buf(0, buf)
    chrome.window(0)
    -- winbar 文字列は窓変数 (b: にしない — chrome 決定)
    chrome.winbar(0, ui_list.sessionlist_winbar(sessions))
  end)
end

--- 追随: 表示中のセッション一覧をディスクから再読込して再 render する
--- (persistence-restore「:Review list」。session.persist と delete finalize から
--- 呼ばれる)。窓が無いときは bufhidden=wipe で一覧バッファ自体が既に消えている
--- ので何もしない (無条件 render は孤児バッファを作る)。repo は状態変化側から
--- 渡す — 表示中の一覧と repo が違う (別 repo の一覧を開いたまま状態変化) 場合は
--- 追随しない (開いたときの repo の一覧を壊さない)。
function M.refresh(repo)
  if repo == nil then
    return
  end
  local win = find_window()
  if win == nil or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local meta = vim.b[buf].review_meta or {}
  if meta.repo ~= repo then
    return
  end
  local sessions = store.list(repo).data
  ui_list.render_sessionlist(sessions, { repo = repo, is_grey = repo_missing })
  repaint_winbars(buf, sessions)
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
    notify_warn 'cannot open the session: its repo path no longer exists'
    return
  end
  -- 防御: 行データは render 時点の写し。削除済み (d 完了後の旧行や別インスタンス
  -- による削除) を <CR> しても persist で削除済み JSON を復活させないため、
  -- 開始前にディスクで存在を再確認する (refresh で行は消えるが、render と読み取り
  -- の間に削除された場合の二重ガード)。
  local loaded = store.load(sess.repo, sess.id).data
  if loaded == nil then
    notify_warn(('cannot open session %s: it was already deleted'):format(sess.id))
    return
  end
  restore.resume_session(loaded)
end

--- 一覧のカーソル行セッションを削除 (d)。`:Review delete` と同一の
--- 確認フロー (コメント件数 WARN + [y/N]) を経由する。grey 行 (repo path 消失)
--- は対象解決できないため WARN。削除完了後の一覧追随は session.M.delete の
--- finalize (store.delete 成功直後) から M.refresh が呼ぶ (delete は非同期のため
--- ここで同期的に render しても削除前の状態を描く)。
function M.delete_current()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind ~= 'sessionlist' then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local sess = ui_list.row_session(buf, row)
  if sess == nil then
    notify_warn(
      'not a session row; cannot delete (for a row with a missing '
        .. 'repo path use :Review delete <id> directly)'
    )
    return
  end
  local session_handler = require 'review.handlers.session'
  session_handler.delete(sess.id)
end

return M
