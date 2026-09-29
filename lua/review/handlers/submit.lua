-- レビュー submit (pr-comments「submit フロー」)。mode=pr セッションの
-- local pending コメント (インライン / ファイルレベル / 一般) を GitHub へ push し、
-- レビューを event (COMMENT / APPROVE / REQUEST_CHANGES) + 任意のサマリ本文で
-- 確定する。GitHub の「pending review → submit」モデルを再現する:
--   1. 新規スレッドの pending を先に create_review_comment (path + line / file)
--   2. 返信 (in_reply_to) を create_review_comment — 根がローカルのときは
--      1 で採番された gh_id へ解決する
--   3. 一般コメントの pending を create_issue_comment
--   4. 作成された pending review を submit_review (event + body) で確定
--      (コメントが 1 件も無い場合は create_review で event のみ確定)
--   5. 完了後に差分再取得 (session.refresh) で gh 状態へ突合 (pending 表示が消える)
-- 失敗時は WARN し、未 push の pending は保持する (再試行可)。
local gh = require 'review.git.gh'
local pr_comments = require 'review.handlers.pr_comments'
local result = require 'review.core.result'
local session_handler = require 'review.handlers.session'

local M = {}

local EVENTS = { 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

-- session.comments から id でローカルコメントを引き、gh_id を返す (nil 可)。
local function local_gh_id(comments, id)
  for _, c in ipairs(comments or {}) do
    if c.id == id then
      return c.gh_id
    end
  end
  return nil
end

-- pending コメント 1 件を push する。replies は in_reply_to 解決済みの gh_id で、
-- roots は path (+line / file) で作る。成功でコメントに gh_id を記録し、
-- created (レビュー comment の配列) へ追記。失敗は cb(false)。
local function push_one(session, repo, number, c, created, cb)
  local opts = { repo = repo, number = number, body = c.body }
  if c.in_reply_to ~= nil then
    local target = c.in_reply_to
    if type(target) == 'string' then
      target = local_gh_id(session.comments, target)
    end
    if target == nil then
      notify_warn(
        ('cannot resolve the reply target of %s; skipping it (submit the rest)'):format(c.id)
      )
      cb(true)
      return
    end
    opts.in_reply_to = target
  else
    opts.path = c.file
    if c.subject_type == 'file' then
      opts.subject_type = 'file'
    else
      opts.line = c.line
    end
  end
  gh.create_review_comment(opts, function(res)
    if not res.ok then
      notify_warn(('failed to push comment %s: %s'):format(c.id, res.error or 'unknown error'))
      cb(false)
      return
    end
    c.gh_id = res.data.id
    created[#created + 1] = res.data
    cb(true)
  end)
end

local function push_all(session, repo, number, pending, cb)
  if #pending == 0 then
    cb(true)
    return
  end
  local created = {}
  local i = 1
  local function next_step()
    if i > #pending then
      cb(true, created)
      return
    end
    push_one(session, repo, number, pending[i], created, function(ok)
      if not ok then
        cb(false)
        return
      end
      i = i + 1
      next_step()
    end)
  end
  next_step()
end

local function push_general(repo, number, pending, cb)
  if #pending == 0 then
    cb(true)
    return
  end
  local i = 1
  local function next_step()
    if i > #pending then
      cb(true)
      return
    end
    local g = pending[i]
    gh.create_issue_comment({ repo = repo, number = number, body = g.body }, function(res)
      if not res.ok then
        notify_warn(('failed to push the PR comment %s: %s'):format(g.id, res.error or ''))
        cb(false)
        return
      end
      g.gh_id = res.data.id
      i = i + 1
      next_step()
    end)
  end
  next_step()
end

-- 確定フロー本体。pending を push し、その pending review (または event のみ) を
-- submit し、完了で session.refresh (差分 + gh コメント再取り込み) を走らせる。
local function do_submit(session, event, body)
  local pr = session.pr
  local repo = gh.repo_from_url(pr and pr.url)
  if repo == nil then
    notify_warn 'cannot resolve the PR repository; run inside the PR target repository'
    return
  end
  local number = tostring(pr.number)
  local pending = pr_comments.pending_comments(session)
  local pending_general = pr_comments.pending_general(session)
  -- roots (in_reply_to=nil) を先に push して gh_id を採番し、返信がそれを参照できる
  -- ようにする (submit フロー 1→2)。
  local roots = {}
  local replies = {}
  for _, c in ipairs(pending) do
    if c.in_reply_to == nil then
      roots[#roots + 1] = c
    else
      replies[#replies + 1] = c
    end
  end
  push_all(session, repo, number, roots, function(ok_roots, created_roots)
    if not ok_roots then
      return
    end
    push_all(session, repo, number, replies, function(ok_replies, created_replies)
      if not ok_replies then
        return
      end
      push_general(repo, number, pending_general, function(ok_gen)
        if not ok_gen then
          return
        end
        local all_created = vim.list_extend(created_roots or {}, created_replies or {})
        local review_id = all_created[1] ~= nil and all_created[1].pull_request_review_id or nil
        local function submitted(res)
          if not res.ok then
            notify_warn('failed to submit the review: ' .. (res.error or 'unknown error'))
            return
          end
          vim.notify('review.nvim: review submitted (event=' .. event .. ')', vim.log.levels.INFO)
          -- 差分 + gh コメントを再取り込みして pending 表示を解消する (submit フロー 5)。
          session_handler.refresh()
        end
        if review_id ~= nil then
          gh.submit_review({
            repo = repo,
            number = number,
            review_id = review_id,
            event = event,
            body = body,
          }, submitted)
        else
          gh.create_review({ repo = repo, number = number, event = event, body = body }, submitted)
        end
      end)
    end)
  end)
end

--- `s` / `:Review submit`: event 選択 -> 任意のサマリ本文 -> push + submit。
function M.submit_review()
  local session = session_handler.active()
  if session == nil then
    return result.err('review.nvim: no active session', result.codes.E_NOT_ACTIVE)
  end
  if session.mode ~= 'pr' then
    notify_warn 'submitting a review is only available for PR sessions (:Review pr)'
    return result.ok()
  end
  local n_pending = #pr_comments.pending_comments(session) + #pr_comments.pending_general(session)
  vim.ui.select(EVENTS, {
    prompt = ('review.nvim: submit the review (%d pending comment(s))? event: '):format(n_pending),
    format_item = function(e)
      return e
    end,
  }, function(event)
    if event == nil then
      return
    end
    vim.ui.input({
      prompt = 'review.nvim: review summary (optional, <Enter> to skip): ',
    }, function(body)
      if body == nil then
        return
      end
      do_submit(session, event, body)
    end)
  end)
  return result.ok()
end

return M
