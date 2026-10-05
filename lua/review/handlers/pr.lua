-- PR セッション開始の調停: gh で PR 解決 -> head ref 解決 -> base ref 解決 ->
-- 開始フロー委譲 (pr-worktree.md「入出力と振る舞い」PR 解決 1〜4)。worktree 作成判断と UI 開局は
-- handlers/session / session.begin 共通経路に載せる (PR 専用経路を作らない)。
-- gh / git の失敗は結果型の理由文字列を WARN 通知し、開始を中断する
-- (E_GH / E_PR はアダプタ側で確定。gh 実行中の成否は非同期 = 戻り値は受理)。
local gh = require 'review.git.gh'
local usermsg = require 'review.handlers.usermsg'
local git_ref = require 'review.git.ref'
local paths = require 'review.store.paths'
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

-- base ref: ローカル branch の有無・鮮度に依存せず、常に remote から fetch した
-- remote-tracking ref (<remote>/<baseRefName>) を使う (pr-worktree.md「PR 解決」
-- 手順 3。stacked PR の base はローカルに無いことが多い)。remote は head 解決で
-- 選んだもの (fork 経路) を受け取り、無ければ git remote から選ぶ。
local function resolve_base(repo, meta, remote, cb)
  local function fetch(name)
    git_ref.fetch_branch({ remote = name, branch = meta.baseRefName, cwd = repo }, function(fres)
      if not fres.ok then
        notify_warn(
          ('cannot fetch the PR base branch "%s" from %s: %s'):format(
            meta.baseRefName,
            name,
            fres.error
          )
        )
        return
      end
      cb(fres.data)
    end)
  end
  if remote ~= nil then
    fetch(remote)
    return
  end
  git_ref.remotes({ cwd = repo }, function(rr)
    if not rr.ok or #rr.data == 0 then
      notify_warn(NO_REMOTE_MSG)
      return
    end
    fetch(pick_remote(rr.data))
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
    gh.pr_view({ target = target, cwd = repo }, function(vres)
      if not vres.ok then
        notify_warn(usermsg.gh_error(vres.error))
        return
      end
      local meta = vres.data
      -- head ref: 同一リポジトリに headRefName があればそのまま、無ければ
      -- (fork) refs/pull/<n>/head から自前一時 ref を作る (pr-worktree.md 手順 2、
      -- DESIGN.md「既知の制約」fork PR 行)。
      git_ref.rev_parse({ ref = meta.headRefName, cwd = repo }, function(hr)
        if hr.ok then
          resolve_base(repo, meta, nil, function(base)
            begin_pr(repo, meta, number, meta.headRefName, base)
          end)
          return
        end
        git_ref.remotes({ cwd = repo }, function(rr)
          if not rr.ok or #rr.data == 0 then
            notify_warn(NO_REMOTE_MSG)
            return
          end
          local remote = pick_remote(rr.data)
          git_ref.fetch_pull({
            remote = remote,
            number = number,
            cwd = repo,
          }, function(fres)
            if not fres.ok then
              notify_warn(fres.error)
              return
            end
            resolve_base(repo, meta, remote, function(base)
              begin_pr(repo, meta, number, fres.data, base)
            end)
          end)
        end)
      end)
    end)
  end)
  return result.ok()
end

return M
