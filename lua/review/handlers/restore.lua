-- 復元フロー (diff 再取得と anchor 検証の調停)
-- (docs/design/features/persistence-restore.md「復元手順」「anchor 検証」「起動時」)。
-- anchor 検証の純粋ロジックは core/anchor (session 層との循環回避)。
-- diff 再取得は session.fetch_prepared 経由 (復元時も head 解決フロー = switch
-- 提案 / scratch 縮退を通す。worktree 解決も同じ関数内、pr-worktree.md
-- 「worktree 作成判断」)。
local config = require 'review.config'
local git_ref = require 'review.git.ref'
local result = require 'review.core.result'
local health = require 'review.handlers.health'
local scan = require 'review.store.scan'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local usermsg = require 'review.handlers.usermsg'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

local function sort_by_slug(sessions)
  local sorted = {}
  for _, s in ipairs(sessions) do
    sorted[#sorted + 1] = s
  end
  table.sort(sorted, function(a, b)
    return a.id < b.id
  end)
  return sorted
end

local function fetch_and_resume(session)
  -- 復元時も開始と同じ解決経路を通す (head 解決フローで diff 引数形と worktree
  -- 解が決まる。pr-worktree.md「worktree 作成判断」/ DESIGN「起動時復元」)。
  session_handler.fetch_prepared({
    repo = session.repo,
    id = session.id,
    mode = session.mode,
    base = session.base,
    head = session.head,
    record = session.worktree,
    -- 復元経路も開始と同じ後片付け (pr-worktree.md「0 差分・差分取得失敗時の掃除」):
    -- 作りたて / 再利用の自前 worktree を掃除されたら、実在しない dir を指した
    -- 記録を nil 化して save する (save 前の delete 競合ガード込み、session 側と
    -- 共通ヘルパー)。
    on_worktree_swept = function(wt)
      session_handler.nullify_inherited_record(session, wt)
    end,
  }, function(res)
    if not res.ok then
      -- E_CANCELLED はユーザー自身の中断なので通知しない (開始と同じ)。
      if res.code == result.codes.E_CANCELLED then
        return
      end
      -- ref が解決不能 (force push / 削除) でも保存セッションは残す
      if res.code == result.codes.E_REF then
        notify_warn(usermsg.git_ref_error(res.error))
        return
      end
      notify_warn(res.error)
      return
    end
    session_handler.resume_into(session, res.data.files, res.data.worktree, res.data.degraded)
  end)
end

--- 保存済みセッションを 1 件再開する (:Review / :Review list <Enter> 共通)。
--- 別セッションが active なら確認後に save -> close してから開始する (INV-1)。
function M.resume_session(session)
  local current = session_handler.active()
  if current ~= nil and current.id ~= session.id then
    vim.ui.input({
      prompt = ('review.nvim: %s が開いています。閉じて %s を再開しますか？ [y/N]: '):format(
        current.id,
        session.id
      ),
    }, function(answer)
      if answer == 'y' then
        -- close の worktree 掃除 (--force 確認含む) が完了してから再開 (INV-1)。
        -- force_close 側でキャンセルされた場合はコールバックが走らない = 再開しない。
        session_handler.force_close(function()
          fetch_and_resume(session)
        end)
      end
    end)
    return
  end
  if current ~= nil and current.id == session.id then
    vim.notify(
      ('review.nvim: %s は既に開いています'):format(session.id),
      vim.log.levels.INFO
    )
    return
  end
  fetch_and_resume(session)
end

--- :Review (無印)。open セッション 1 件 = 即復元、複数 = vim.ui.select、
--- 0 件 / repo 外 = 新規開始ガイダンス。
function M.resume_or_select()
  local function guide()
    vim.notify(
      'review.nvim: 復元できるセッションがありません。:Review start で開始してください',
      vim.log.levels.INFO
    )
  end
  git_ref.top_level({ cwd = vim.fn.getcwd() }, function(res)
    if not res.ok then
      guide()
      return
    end
    local open = sort_by_slug(scan.open_sessions(res.data).data)
    if #open == 0 then
      guide()
      return
    end
    if #open == 1 then
      M.resume_session(open[1])
      return
    end
    vim.ui.select(open, {
      prompt = '復元するセッション:',
      format_item = function(s)
        return ('%s (%s..%s, %d comments)'):format(s.id, s.base, s.head, #(s.comments or {}))
      end,
    }, function(choice)
      if choice ~= nil then
        M.resume_session(choice)
      end
    end)
  end)
end

--- 指定 id の保存済みセッションを即再開する (DESIGN.md「API 一覧」resume({id})。
--- 一覧選択は :Review 無印のみで、id 指定では vim.ui.select を通さない)。
--- 見つからない / repo 外は WARN 通知で開始しない。戻り値はディスパッチ受理。
function M.resume_by_id(id)
  if type(id) ~= 'string' or id == '' then
    return result.err(
      'review.nvim: 復元するセッションの id が必要です',
      result.codes.E_REF
    )
  end
  git_ref.top_level({ cwd = vim.fn.getcwd() }, function(res)
    local sess = nil
    if res.ok then
      sess = store.load(res.data, id).data
    end
    if sess == nil then
      notify_warn(('セッション %s が見つかりません'):format(id))
      return
    end
    M.resume_session(sess)
  end)
  return result.ok()
end

--- VimEnter 起動シーケンス: worktree 残骸 scan (pr-worktree.md「異常終了からの回復」)
--- -> open セッション通知。掃除は auto_notify_resume と無関係に走る (MUST 3 の担保)。
function M.startup_scan()
  git_ref.top_level({ cwd = vim.fn.getcwd() }, function(res)
    if not res.ok then
      return -- repo 外は何もしない (scan の対象外)
    end
    health.sweep(res.data, function()
      if config.get().auto_notify_resume then
        M.notify_open_sessions()
      end
    end)
  end)
end

--- VimEnter 起動時 scan: open セッションの continue notify (窓は開かない)。
--- auto_notify_resume=false のときは startup_scan 側で呼ばれない。
function M.notify_open_sessions()
  git_ref.top_level({ cwd = vim.fn.getcwd() }, function(res)
    if not res.ok then
      return -- repo 外は何もしない (scan の対象外)
    end
    local open = sort_by_slug(scan.open_sessions(res.data).data)
    if #open == 1 then
      vim.notify(
        ('review.nvim: %s のレビューが続けられます (:Review で復元)'):format(
          open[1].id
        ),
        vim.log.levels.INFO
      )
    elseif #open > 1 then
      vim.notify(
        ('review.nvim: %d 件のレビューが続けられます (例: %s)。:Review で復元'):format(
          #open,
          open[1].id
        ),
        vim.log.levels.INFO
      )
    end
  end)
end

return M
