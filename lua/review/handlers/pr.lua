-- PR セッション開始の調停: gh で PR 解決 (remote tip 込み) -> remote 選択 ->
-- base / head の ref を remote tip と照合 -> 古いものだけ fetch -> 開始フロー委譲
-- (pr-worktree.md「入出力と振る舞い」PR 解決 1〜4)。worktree 作成判断と UI 開局は
-- handlers/session / session.begin 共通経路に載せる (PR 専用経路を作らない)。
-- gh / git の失敗は結果型の理由文字列を WARN 通知し、開始を中断する
-- (E_GH / E_PR はアダプタ側で確定。gh 実行中の成否は非同期 = 戻り値は受理)。
local gh = require 'review.git.gh'
local usermsg = require 'review.handlers.usermsg'
local git_ref = require 'review.git.ref'
local paths = require 'review.store.paths'
local progress = require 'review.handlers.progress'
local result = require 'review.core.result'
local session = require 'review.handlers.session'
local store = require 'review.store.session'

local M = {}

local function notify_warn(msg)
  vim.notify('review.nvim: ' .. msg, vim.log.levels.WARN)
end

--- `<number|url>` から PR 番号 (string) を抜く。素の数字はそのまま、
--- URL は `/pull/<n>` の末尾 (最終出現) を採用。認識不能は nil。
function M.extract_number(target)
  if type(target) == 'number' then
    return tostring(target)
  end
  if type(target) ~= 'string' or target == '' then
    return nil
  end
  if target:match '^%d+$' then
    return target
  end
  local last
  for n in target:gmatch '/pull/(%d+)' do
    last = n
  end
  return last
end

-- remote 選択: default remote に無ければ origin (pr-worktree.md「PR 解決」2)。
-- 実装では `git remote` 名一覧から origin を優先、無ければ最初の 1 件。
local function pick_remote(names)
  for _, name in ipairs(names) do
    if name == 'origin' then
      return name
    end
  end
  return names[1]
end

local NO_REMOTE_MSG = 'cannot resolve the git remote; run inside the PR target repository, '
  .. 'or identify the repository with :Review pr <URL>'

-- 旧形式 (base = 素の baseRefName) で保存された同じ PR のセッションを、
-- 解決後の base (<remote>/<baseRefName>) へ移す。refs 組の一意性 (slug_conflict)
-- は文字列比較なので、移さないと同じ PR の再開始が slug 衝突で拒否される。
-- head が違う既存は別の refs 組なので触らない (従来どおり衝突として扱う)。
local function migrate_legacy_base(repo, slug, meta, head, base)
  local existing = store.load(repo, slug).data
  if
    existing == nil
    or existing.mode ~= 'pr'
    or existing.base ~= meta.baseRefName
    or existing.head ~= head
  then
    return
  end
  existing.base = base
  local sres = store.save(existing)
  if not sres.ok then
    notify_warn(sres.error)
  end
end

-- 解決した refs で開始フロー (継承確認 -> diff -> worktree 判断 -> UI)。
local function begin_pr(repo, meta, number, head, base)
  local slug = paths.pr_slug(number)
  migrate_legacy_base(repo, slug, meta, head, base)
  local state_note = ''
  if meta.state ~= nil and meta.state ~= 'OPEN' then
    -- closed/merged PR もレビュー可能。状態は開始時 INFO に添えるだけ (エッジケース)
    state_note = (' (%s)'):format(meta.state)
  end
  session.begin {
    repo = repo,
    id = slug,
    mode = 'pr',
    base = base,
    head = head,
    pr = { number = tonumber(number) or number, url = meta.url },
    info = ('PR #%s: %s%s'):format(number, meta.title or '', state_note),
  }
end

-- ローカルの ref が remote tip (GraphQL で得た sha) と一致するか。tip が無い
-- (remote にブランチが無い) ときは照合せず不一致として fetch に任せ、失敗を
-- そのまま利用者へ見せる。
local function is_current(repo, ref, tip, cb)
  if tip == nil then
    cb(false)
    return
  end
  git_ref.rev_parse({ ref = ref, cwd = repo }, function(res)
    cb(res.ok and res.data == tip)
  end)
end

-- 手元が古い ref だけを fetch する (pr-worktree.md「PR 解決」手順 2・3)。
-- fork PR で head と base の両方が古いときは 1 回の fetch にまとめる
-- (fetch の所要時間の大半は remote への接続確立なので、2 回に分けない)。
local function fetch_stale(repo, meta, number, remote, stale, cb)
  local base_label = ('"%s"'):format(meta.baseRefName)
  local tracking = ('%s/%s'):format(remote, meta.baseRefName)
  if stale.head and stale.base then
    local stage = progress.start(('fetching the head of PR #%s and %s'):format(number, tracking))
    git_ref.fetch_pull_and_branch({
      remote = remote,
      number = number,
      branch = meta.baseRefName,
      cwd = repo,
    }, function(res)
      progress.stop(stage)
      if not res.ok then
        notify_warn(
          ('cannot fetch the head and base branch %s of PR #%s from %s: %s'):format(
            base_label,
            number,
            remote,
            res.error
          )
        )
        return
      end
      cb()
    end)
    return
  end
  if stale.head then
    local stage = progress.start(('fetching the head of PR #%s from %s'):format(number, remote))
    git_ref.fetch_pull({ remote = remote, number = number, cwd = repo }, function(res)
      progress.stop(stage)
      if not res.ok then
        notify_warn(res.error)
        return
      end
      cb()
    end)
    return
  end
  if stale.base then
    local stage = progress.start('fetching ' .. tracking)
    git_ref.fetch_branch({ remote = remote, branch = meta.baseRefName, cwd = repo }, function(res)
      progress.stop(stage)
      if not res.ok then
        notify_warn(
          ('cannot fetch the PR base branch %s from %s: %s'):format(base_label, remote, res.error)
        )
        return
      end
      cb()
    end)
    return
  end
  cb()
end

-- head ref: 同一リポジトリに headRefName があればそのまま、無ければ (fork)
-- refs/pull/<n>/head から作る自前一時 ref (pr-worktree.md 手順 2、DESIGN.md
-- 「既知の制約」fork PR 行)。cb(head, head_stale)。
local function resolve_head(repo, meta, number, cb)
  git_ref.rev_parse({ ref = meta.headRefName, cwd = repo }, function(hr)
    if hr.ok then
      cb(meta.headRefName, false)
      return
    end
    is_current(repo, git_ref.pr_ref_storage(number), meta.head_tip, function(current)
      cb(git_ref.pr_ref(number), not current)
    end)
  end)
end

-- base ref は常に remote-tracking ref (<remote>/<baseRefName>)。ローカル branch
-- の有無・鮮度には依存しない (stacked PR の base はローカルに無いことが多い)。
local function resolve_refs(repo, meta, number, cb)
  git_ref.remotes({ cwd = repo }, function(rr)
    if not rr.ok or #rr.data == 0 then
      notify_warn(NO_REMOTE_MSG)
      return
    end
    local remote = pick_remote(rr.data)
    local tracking = ('refs/remotes/%s/%s'):format(remote, meta.baseRefName)
    is_current(repo, tracking, meta.base_tip, function(base_current)
      resolve_head(repo, meta, number, function(head, head_stale)
        fetch_stale(repo, meta, number, remote, {
          base = not base_current,
          head = head_stale,
        }, function()
          cb(head, ('%s/%s'):format(remote, meta.baseRefName))
        end)
      end)
    end)
  end)
end

--- `:Review pr <number|url>`。戻り値はディスパッチ受理 (gh / git を伴う成否は
--- 非同期 notify。target 認識不能だけ同期 err + WARN を返す)。
function M.start(target)
  local number = M.extract_number(target)
  if number == nil then
    notify_warn 'cannot recognize the PR number or URL. use the form :Review pr <number|url>'
    return result.err('review.nvim: cannot recognize the PR number or URL', result.codes.E_PR)
  end
  git_ref.top_level({ cwd = vim.fn.getcwd() }, function(tres)
    if not tres.ok then
      notify_warn(tres.error)
      return
    end
    local repo = tres.data
    local url = type(target) == 'string' and not target:match '^%d+$' and target or nil
    local stage = progress.start(('resolving PR #%s'):format(number))
    gh.pr_view({ number = number, url = url, cwd = repo }, function(vres)
      progress.stop(stage)
      if not vres.ok then
        notify_warn(usermsg.gh_error(vres.error))
        return
      end
      local meta = vres.data
      resolve_refs(repo, meta, number, function(head, base)
        begin_pr(repo, meta, number, head, base)
      end)
    end)
  end)
  return result.ok()
end

return M
