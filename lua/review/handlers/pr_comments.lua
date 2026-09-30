-- PR レビューコメントの GitHub 取り込み・突合 (pr-comments)。
-- mode=pr セッションの開始時と R リフレッシュ時に、GitHub のレビューコメント
-- (インライン + ファイルレベル、未 submit 含む) と一般コメント (conversation) を
-- gh api で取得し、session.comments / session.general に突合する。
-- 契約:
--   - gh コメントは gh_id をキーに冪等に突合 (更新/追加/削除)
--   - local origin のコメント (pending) は常に保持
--   - gh_state は reviews 一覧の PENDING review との突合で決める
--   - state (active/outdated) は現在の差分 (files_by_path) に対する表示可否で決める
-- 呼び出し側 (handlers/session) が突合後に persist + UI 再適用を行う。
-- この層は session を top-level require しない (循環回避 — session 側が
-- 本モジュールを require する方向)。引数で session を受ける。
local gh = require 'review.git.gh'
local comment_model = require 'review.core.comment'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

-- files_by_path から file の new 側行数 (可視行 = add/context の最大 new_line)。
-- 削除専用・空 hunk は 0 を返す (行コメントは表示不可と判定される)。
local function file_new_line_count(file)
  if file == nil then
    return 0
  end
  local max = 0
  for _, hunk in ipairs(file.hunks or {}) do
    for _, line in ipairs(hunk.lines) do
      if line.new_line ~= nil and line.new_line > max then
        max = line.new_line
      end
    end
  end
  return max
end

-- displayability: file が現在の差分にあり行が存在すれば active、それ以外 outdated。
-- ファイルレベルは file の存在のみで判定する。
local function display_state(comment, files_by_path)
  local file = files_by_path[comment.file]
  if comment.subject_type == 'file' then
    return file ~= nil and 'active' or 'outdated'
  end
  -- line が vim.NIL (JSON null の userdata) のまま残った経路でも落ちないよう
  -- 防御する (from_gh が正規化するが、他の代入経路の保険)。
  if file == nil or comment.line == nil or comment.line == vim.NIL then
    return 'outdated'
  end
  local count = file_new_line_count(file)
  if count == 0 or comment.line > count then
    return 'outdated'
  end
  return 'active'
end

local function pending_review_ids(reviews)
  local ids = {}
  for _, r in ipairs(reviews or {}) do
    if r.state == 'PENDING' then
      ids[r.id] = true
    end
  end
  return ids
end

--- レビューコメントを session.comments に突合する (in-place)。
--- gh_comments = GET pulls/{n}/comments の配列、reviews = GET pulls/{n}/reviews。
--- files_by_path は displayability (active/outdated) の判定用。
--- 戻り値: { added, updated, removed }。
function M.reconcile_review_comments(session, gh_comments, reviews, files_by_path)
  local pending = pending_review_ids(reviews)
  local by_id = {}
  for _, c in ipairs(session.comments or {}) do
    if c.origin == 'gh' and c.gh_id ~= nil then
      by_id[c.gh_id] = c
    end
  end
  local seen = {}
  local added, updated, removed = 0, 0, 0
  for _, gc in ipairs(gh_comments or {}) do
    seen[gc.id] = true
    local norm = comment_model.from_gh(gc, { id = 'tmp' })
    norm.gh_state = pending[gc.pull_request_review_id] and 'pending' or 'submitted'
    norm.state = display_state(norm, files_by_path or {})
    local existing = by_id[gc.id]
    if existing ~= nil then
      existing.body = norm.body
      existing.gh_user = norm.gh_user
      existing.gh_state = norm.gh_state
      existing.subject_type = norm.subject_type
      existing.line = norm.line
      existing.end_line = norm.end_line
      existing.in_reply_to = norm.in_reply_to
      existing.created_at = norm.created_at
      existing.state = norm.state
      updated = updated + 1
    else
      norm.id = comment_model.new_id(session.comments or {})
      session.comments[#session.comments + 1] = norm
      added = added + 1
    end
  end
  -- server から消えた gh コメントと、submit でサーバー側へ「採用」された
  -- local コメント (gh_id が server の集合に載った = 重複を避けるため gh 版に
  -- 置き換える) を削除する。local で gh_id を持たない pending は常に保持。
  for i = #(session.comments or {}), 1, -1 do
    local c = session.comments[i]
    if c.origin == 'gh' and c.gh_id ~= nil and not seen[c.gh_id] then
      table.remove(session.comments, i)
      removed = removed + 1
    elseif c.origin ~= 'gh' and c.gh_id ~= nil and seen[c.gh_id] then
      table.remove(session.comments, i)
      removed = removed + 1
    end
  end
  return { added = added, updated = updated, removed = removed }
end

-- 一般コメントのローカル id 採番 ('g<n>'。comments の c<n> とは別系列)。
local function new_general_id(general)
  local max = 0
  for _, g in ipairs(general or {}) do
    local n = tonumber((g.id or ''):match '^g(%d+)$')
    if n ~= nil and n > max then
      max = n
    end
  end
  return 'g' .. (max + 1)
end

--- 一般コメント (issue comments) を session.general に突合する (in-place)。
--- 呼び出し側が session.general を初期化 (nil -> {}) しておくこと。
--- 戻り値: { added, updated, removed }。
function M.reconcile_general(session, issue_comments)
  local general = session.general
  local by_id = {}
  for _, g in ipairs(general) do
    if g.origin == 'gh' and g.gh_id ~= nil then
      by_id[g.gh_id] = g
    end
  end
  local seen = {}
  local added, updated, removed = 0, 0, 0
  for _, ic in ipairs(issue_comments or {}) do
    seen[ic.id] = true
    local existing = by_id[ic.id]
    if existing ~= nil then
      existing.body = ic.body
      existing.gh_user = (ic.user or {}).login
      existing.created_at = comment_model.gh_time(ic.created_at)
      updated = updated + 1
    else
      general[#general + 1] = {
        id = new_general_id(general),
        origin = 'gh',
        gh_id = ic.id,
        gh_user = (ic.user or {}).login,
        body = ic.body,
        created_at = comment_model.gh_time(ic.created_at),
      }
      added = added + 1
    end
  end
  for i = #general, 1, -1 do
    local g = general[i]
    if g.origin == 'gh' and g.gh_id ~= nil and not seen[g.gh_id] then
      table.remove(general, i)
      removed = removed + 1
    end
  end
  return { added = added, updated = updated, removed = removed }
end

--- GitHub から取り込みの要否。mode=pr かつ PR url から owner/repo が取れる場合のみ。
--- (branch モードや PR 番号/URL を欠くセッションは対象外。pr は vim.NIL も可)
function M.enabled(session)
  if session.mode ~= 'pr' then
    return false
  end
  local pr = session.pr
  if pr == nil or pr == vim.NIL or type(pr) ~= 'table' then
    return false
  end
  return gh.repo_from_url(pr.url) ~= nil
end

--- 3 系統 (review comments / reviews / issue comments) を並列取得し突合する。
--- opts = { files_by_path }。cb(failed: boolean, added: number) —
--- failed は 1 系統以上の取得失敗、added は今回新規追加したコメント総数
--- (レビュー + 一般)。失敗系統があっても成功した系統は突合する
--- (ローカル機能は継続)。
function M.fetch(session, opts, cb)
  local pr = session.pr
  if pr == nil or pr == vim.NIL or type(pr) ~= 'table' then
    if cb ~= nil then
      cb(true, 0)
    end
    return
  end
  local repo = gh.repo_from_url(pr.url)
  if repo == nil then
    if cb ~= nil then
      cb(true, 0)
    end
    return
  end
  local number = tostring(pr.number)
  local remaining = 3
  local failed = false
  local review_comments, reviews, issue_comments = nil, nil, nil

  local function settle()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end
    local added = 0
    if review_comments ~= nil then
      local r =
        M.reconcile_review_comments(session, review_comments, reviews or {}, opts.files_by_path)
      added = added + r.added
    end
    if issue_comments ~= nil then
      session.general = session.general or {}
      local r = M.reconcile_general(session, issue_comments)
      added = added + r.added
    end
    if cb ~= nil then
      cb(failed, added)
    end
  end

  gh.list_review_comments({ repo = repo, number = number }, function(res)
    if res.ok then
      review_comments = res.data
    else
      failed = true
      notify_warn('failed to fetch GitHub review comments: ' .. (res.error or 'unknown error'))
    end
    settle()
  end)
  gh.list_reviews({ repo = repo, number = number }, function(res)
    if res.ok then
      reviews = res.data
    else
      failed = true
    end
    settle()
  end)
  gh.list_issue_comments({ repo = repo, number = number }, function(res)
    if res.ok then
      issue_comments = res.data
    else
      failed = true
      notify_warn('failed to fetch GitHub PR comments: ' .. (res.error or 'unknown error'))
    end
    settle()
  end)
end

--- local pending のレビューコメント (origin='local' かつ gh_id 未付与) を返す。
function M.pending_comments(session)
  local pending = {}
  for _, c in ipairs(session.comments or {}) do
    if c.origin ~= 'gh' and c.gh_id == nil then
      pending[#pending + 1] = c
    end
  end
  return pending
end

--- local pending の一般コメント (origin='local' かつ gh_id 未付与) を返す。
function M.pending_general(session)
  local pending = {}
  for _, g in ipairs(session.general or {}) do
    if g.origin ~= 'gh' and g.gh_id == nil then
      pending[#pending + 1] = g
    end
  end
  return pending
end

return M
