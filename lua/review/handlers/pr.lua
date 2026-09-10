-- PR セッション開始の調停: gh で PR 解決 -> head ref 解決 -> 開始フロー委譲
-- (pr-worktree.md「入出力と振る舞い」PR 解決 1〜3)。worktree 作成判断と UI 開局は
-- handlers/session / session.begin 共通経路に載せる (PR 専用経路を作らない)。
-- gh / git の失敗は結果型の理由文字列を WARN 通知し、開始を中断する
-- (E_GH / E_PR はアダプタ側で確定。gh 実行中の成否は非同期 = 戻り値は受理)。
local gh = require 'review.git.gh'
local usermsg = require 'review.handlers.usermsg'
local git_ref = require 'review.git.ref'
local paths = require 'review.store.paths'
local result = require 'review.core.result'
local session = require 'review.handlers.session'

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

-- 解決した refs で開始フロー (継承確認 -> diff -> worktree 判断 -> UI)。
local function begin_pr(repo, meta, number, head)
  local state_note = ''
  if meta.state ~= nil and meta.state ~= 'OPEN' then
    -- closed/merged PR もレビュー可能。状態は開始時 INFO に添えるだけ (エッジケース)
    state_note = (' (%s)'):format(meta.state)
  end
  session.begin {
    repo = repo,
    id = paths.pr_slug(number),
    mode = 'pr',
    base = meta.baseRefName,
    head = head,
    pr = { number = tonumber(number) or number, url = meta.url },
    info = ('PR #%s: %s%s'):format(number, meta.title or '', state_note),
  }
end

--- `:Review pr <number|url>`。戻り値はディスパッチ受理 (gh / git を伴う成否は
--- 非同期 notify。target 認識不能だけ同期 err + WARN を返す)。
function M.start(target)
  local number = M.extract_number(target)
  if number == nil then
    notify_warn 'PR 番号または URL を認識できません: :Review pr <number|url> の形式で指定してください'
    return result.err(
      'review.nvim: PR 番号または URL を認識できません',
      result.codes.E_PR
    )
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
          begin_pr(repo, meta, number, meta.headRefName)
          return
        end
        git_ref.remotes({ cwd = repo }, function(rr)
          if not rr.ok or #rr.data == 0 then
            notify_warn(
              'git remote が解決できません。PR のターゲットリポジトリ内で実行するか、'
                .. ':Review pr <URL> でリポジトリを特定してください'
            )
            return
          end
          git_ref.fetch_pull({
            remote = pick_remote(rr.data),
            number = number,
            cwd = repo,
          }, function(fres)
            if not fres.ok then
              notify_warn(fres.error)
              return
            end
            begin_pr(repo, meta, number, fres.data)
          end)
        end)
      end)
    end)
  end)
  return result.ok()
end

return M
