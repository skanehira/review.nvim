-- レビュー submit (pr-comments「submit フロー」)。mode=pr セッションの
-- local pending コメント (インライン / ファイルレベル / 一般) を GitHub へ push し、
-- レビューを event (COMMENT / APPROVE / REQUEST_CHANGES) + 任意のサマリ本文で
-- 確定する。GitHub の「pending 蓄積 → submit で一括確定」を REST で実現する:
--   1. 新規スレッドの行コメントは create_review の comments 配列に載せて
--      event + body と一緒に 1 回のレビューとして submit する (GitHub の
--      PR レビュー画面と同じ: コメント + 判定 + サマリが 1 レビューになる)。
--      作成されたコメントの gh_id は GET /reviews/{id}/comments で対応付ける。
--   2. ファイルレベル (subject_type=file) と返信 (in_reply_to) は batch の
--      comments 配列に載せられない (GitHub スキーマ制約) ため、個別に
--      create_review_comment で POST する (返信はスレッド継承で submitted)。
--   3. 一般コメントの pending は create_issue_comment で POST する。
--   4. 行コメントが 1 件も無いときは create_review (event + body) で判定だけ確定。
--   5. 完了後に session.refresh (差分 + gh 再取り込み) で pending 表示を解消する。
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

-- レビューコメント 1 件を個別 POST する (ファイルレベル / 返信)。
-- 成功でコメントに gh_id を記録する。失敗は cb(false)。
local function push_one(session, repo, number, c, cb)
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
    opts.subject_type = 'file' -- ファイルレベル (line 不要)
  end
  gh.create_review_comment(opts, function(res)
    if not res.ok then
      notify_warn(('failed to push comment %s: %s'):format(c.id, res.error or 'unknown error'))
      cb(false)
      return
    end
    c.gh_id = res.data.id
    cb(true)
  end)
end

-- リストを直列に個別 POST する (中断時 cb(false))。
local function push_sequence(session, repo, number, list, cb)
  if #list == 0 then
    cb(true)
    return
  end
  local i = 1
  local function next_step()
    if i > #list then
      cb(true)
      return
    end
    push_one(session, repo, number, list[i], function(ok)
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

-- バッチ submit した行コメントの gh_id を、そのレビューに属するコメント一覧と
-- (path, line, body) で対応付ける (local の pending を解消するため)。
local function match_review_comment_ids(review_comments, line_roots)
  local roots = {}
  for _, c in ipairs(line_roots) do
    roots[#roots + 1] = {
      c = c,
      path = c.file,
      line = c.line,
      body = c.body,
    }
  end
  for _, gc in ipairs(review_comments or {}) do
    for _, r in ipairs(roots) do
      if r.c.gh_id == nil and gc.path == r.path and gc.line == r.line and gc.body == r.body then
        r.c.gh_id = gc.id
      end
    end
  end
end

-- 確定フロー本体。pending を push し、event + body でレビューを確定し、
-- 完了で session.refresh (差分 + gh コメント再取り込み) を走らせる。
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
  -- 種別で分割: バッチ (行 root) / 個別 (ファイルレベル root / 返信) / 一般
  local line_roots, file_roots, replies = {}, {}, {}
  for _, c in ipairs(pending) do
    if c.in_reply_to ~= nil then
      replies[#replies + 1] = c
    elseif c.subject_type == 'file' then
      file_roots[#file_roots + 1] = c
    else
      line_roots[#line_roots + 1] = c
    end
  end

  -- 1) ファイルレベル root と返信を個別 POST (返信は参照先 root の gh_id が要る。
  --    バッチ対象 (行 root) を先に submit してから、その gh_id 対応を済ませる)
  local function push_individuals(ok)
    if not ok then
      return
    end
    push_sequence(session, repo, number, file_roots, function(ok_files)
      if not ok_files then
        return
      end
      push_sequence(session, repo, number, replies, function(ok_replies)
        if not ok_replies then
          return
        end
        push_general(repo, number, pending_general, function(ok_gen)
          if not ok_gen then
            return
          end
          vim.notify('review.nvim: review submitted (event=' .. event .. ')', vim.log.levels.INFO)
          session_handler.refresh()
        end)
      end)
    end)
  end

  -- 2) 行 root を event + body + comments で 1 レビューとして submit
  local comments = {}
  for _, c in ipairs(line_roots) do
    comments[#comments + 1] = { path = c.file, line = c.line, body = c.body }
  end
  if #line_roots > 0 then
    gh.create_review({
      repo = repo,
      number = number,
      event = event,
      body = body,
      comments = comments,
    }, function(res)
      if not res.ok then
        notify_warn('failed to submit the review: ' .. (res.error or 'unknown error'))
        return
      end
      -- 作成されたコメントの gh_id を対応付けて pending を解消する
      gh.list_review_comments_by_review({
        repo = repo,
        number = number,
        review_id = res.data.id,
      }, function(cres)
        if cres.ok then
          match_review_comment_ids(cres.data, line_roots)
        end
        push_individuals(true)
      end)
    end)
    return
  end
  -- 3) 行 root が無い: event + body の判定レビューのみ確定
  gh.create_review({ repo = repo, number = number, event = event, body = body }, function(res)
    if not res.ok then
      notify_warn('failed to submit the review: ' .. (res.error or 'unknown error'))
      return
    end
    push_individuals(true)
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
