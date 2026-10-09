-- handlers/pr: `:Review pr <number|url>` の PR 解決 (gh) -> head ref 解決
-- (同一 repo branch / fork は refs/pull 一時 ref) -> 開始フロー委譲
-- (pr-worktree.md「入出力と振る舞い」PR 解決 + worktree 作成判断 mode=pr)。
-- gh / git は同一の cli 注入スタブで引数組み立てと応答を制御する。
local cli = require 'review.git.cli'
local config = require 'review.config'
local paths = require 'review.store.paths'
local pr_handler = require 'review.handlers.pr'
local progress = require 'review.handlers.progress'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'

local REPO_TOP = '/spec/repo-top'

local RAW_DIFF_A = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1 +1,2 @@',
  ' line1',
  '+line2',
  '',
}, '\n')

-- remote 上の tip (GraphQL 応答の baseRef.target.oid / headRefOid)。ローカルの
-- ref がこれと一致すれば fetch しない (pr-worktree.md「PR 解決」手順 2・3)。
local BASE_TIP = string.rep('b', 40)
local HEAD_TIP = string.rep('c', 40)

local function pr_json(overrides)
  local pr = {
    number = 7,
    title = 'Add widget',
    baseRefName = 'main',
    headRefName = 'topic',
    headRepositoryOwner = { login = 'forkguy' },
    url = 'https://github.com/acme/demo/pull/7',
    state = 'OPEN',
    baseRef = { target = { oid = BASE_TIP } },
    headRefOid = HEAD_TIP,
  }
  for k, v in pairs(overrides or {}) do
    pr[k] = v
  end
  return vim.json.encode { data = { repository = { pullRequest = pr } } }
end

local json_ok = function(contents)
  return function()
    return { code = 0, stdout = contents, stderr = '' }
  end
end

local top_ok = function()
  return { code = 0, stdout = REPO_TOP .. '\n', stderr = '' }
end

local sha_ok = function()
  return { code = 0, stdout = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n', stderr = '' }
end

local function sha(value)
  return function()
    return { code = 0, stdout = value .. '\n', stderr = '' }
  end
end

-- ローカルの ref が remote tip と一致 / 不一致 / 不在
local base_fresh = sha(BASE_TIP)
local base_stale = sha(string.rep('0', 40))
local head_fresh = sha(HEAD_TIP)
local ref_missing = function()
  return { code = 128, stdout = '', stderr = 'fatal: Needed a single revision\n' }
end
-- 同一 repo に headRefName の branch が無い = fork PR
local not_a_branch = function()
  return { code = 128, stdout = '', stderr = "fatal: ambiguous argument 'topic'\n" }
end

local diff_a = function()
  return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
end

local git_ok = function()
  return { code = 0, stdout = '', stderr = '' }
end

local origin_ok = function()
  return { code = 0, stdout = 'origin\n', stderr = '' }
end

-- PR の base は常に remote-tracking ref (pr-worktree.md「PR 解決」手順 3)
local BASE_FETCH = { 'git', 'fetch', 'origin', '+refs/heads/main:refs/remotes/origin/main' }
local HEAD_FETCH = { 'git', 'fetch', 'origin', 'refs/pull/7/head:review-nvim/pr-7' }
local BOTH_FETCH = {
  'git',
  'fetch',
  'origin',
  'refs/pull/7/head:review-nvim/pr-7',
  '+refs/heads/main:refs/remotes/origin/main',
}
local REV_PARSE_BASE = { 'git', 'rev-parse', '--verify', 'refs/remotes/origin/main' }
local REV_PARSE_HEAD = { 'git', 'rev-parse', '--verify', 'topic' }
local REV_PARSE_PR_REF = { 'git', 'rev-parse', '--verify', 'refs/heads/review-nvim/pr-7' }

local state = {}

local REAL_NOTIFY = vim.notify
local REAL_INPUT = vim.ui.input

local function install_git(responses)
  state.git_calls = {}
  state.git_opts = {}
  cli._set_system(function(cmd, opts, on_exit)
    -- gh api の REST (PR 開始時のコメント取り込み pr-comments)。引数組み立てを
    -- 対象とする本 spec では空応答で通し、call 記録・応答 index・通知に含めない。
    -- graphql は PR 解決そのものなので記録する。
    if cmd[1] == 'gh' and cmd[2] == 'api' and not vim.tbl_contains(cmd, 'graphql') then
      on_exit { code = 0, stdout = '[]', stderr = '' }
      return
    end
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    state.git_opts[idx] = opts
    if responses[idx] == nil then
      -- 3 窓開通の base scratch 充填 (git show) は窓の中身の契約として
      -- session_spec が pin 済み。本 spec の対象 (引数組み立て) でないので
      -- 既定応答で通す。それ以外の想定外実行は従来どおり error。
      if cmd[2] == 'show' then
        on_exit { code = 0, stdout = 'base content\n', stderr = '' }
        return
      end
      error('pr stub: 想定外の追加実行 ' .. table.concat(cmd, ' '), 0)
    end
    on_exit(responses[idx](cmd, opts))
  end)
  cli._set_executable(function()
    return 1
  end)
end

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, inputs = {}, input_answer = 'y', git_calls = {} }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    paths._set_data_dir(state.dir)
    store._set_now(function()
      return 4321
    end)
    store._set_notify(function() end)
    session_handler._set_now(function()
      return 4321
    end)
    session_handler._reset()
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    -- 段階別の過渡メッセージは notify とは別の出力先で順序ごと記録する
    -- (クリアは '<clear>')。
    progress._reset()
    state.progress = {}
    progress._set_sink(function(text)
      table.insert(state.progress, text == nil and '<clear>' or text)
    end)
    vim.ui.input = function(opts, cb)
      table.insert(state.inputs, opts)
      cb(state.input_answer)
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
    vim.notify = REAL_NOTIFY
    progress._set_sink(nil)
    progress._reset()
    vim.ui.input = REAL_INPUT
    paths._set_data_dir(nil)
    store._set_now(nil)
    store._set_notify(nil)
    session_handler._set_now(nil)
    session_handler._reset()
    config.reset()
    cli._set_system(nil)
    cli._set_executable(nil)
    vim.fn.delete(state.dir, 'rf')
  end)
end

describe('pr-handler 入力解析', function()
  use_env()

  it('番号でも URL でも PR 番号を取り出す (/pull/<n> 末尾)', function()
    assert.equals('7', pr_handler.extract_number '7')
    assert.equals('12', pr_handler.extract_number 'https://github.com/acme/demo/pull/12')
    assert.equals('3', pr_handler.extract_number 'https://github.com/a/b/pull/3/files')
  end)

  it('認識不能入力は同期 err (E_PR) + WARN で gh を起動しない', function()
    install_git {}
    local res = pr_handler.start 'not-a-pr'

    assert.equals(false, res.ok)
    assert.equals('E_PR', res.code)
    assert.equals(1, #state.notifications)
    assert.equals(vim.log.levels.WARN, state.notifications[1].level)
    assert.equals(0, #state.git_calls)
  end)

  it('nil 入力も同期 err (起動なし)', function()
    install_git {}
    assert.equals(false, pr_handler.start(nil).ok)
    assert.equals(0, #state.git_calls)
  end)
end)

describe('pr-handler fork PR 開始 (refs/pull 解決 + worktree 常時作成)', function()
  use_env()

  -- base / head とも手元が古い fork PR = fetch を 1 回にまとめる経路
  local function fork_seq(gh_stdout)
    return {
      top_ok, -- 1
      json_ok(gh_stdout), -- 2 gh api graphql
      function()
        return { code = 0, stdout = 'origin\nupstream\n', stderr = '' }
      end, -- 3 remotes
      base_stale, -- 4 rev-parse refs/remotes/origin/main (remote tip と不一致)
      not_a_branch, -- 5 rev-parse topic (fork)
      ref_missing, -- 6 rev-parse refs/heads/review-nvim/pr-7 (未取得)
      git_ok, -- 7 fetch pull ref + base を 1 回で
      git_ok, -- 8 worktree add (mode=pr は常時作成)
      diff_a, -- 9 diff <remote>/<base> (cwd=worktree、作業ツリー基準)
    }
  end

  it(
    'gh -> remote -> base/head の照合 -> 1 回の fetch -> add -> diff(cwd=wt) -> pr-7 開始 (INFO)',
    function()
      install_git(fork_seq(pr_json()))

      local res = pr_handler.start '7'
      assert.equals(true, res.ok)

      local wt = paths.worktree_path(REPO_TOP, 'pr-7')
      assert.same({ 'git', 'rev-parse', '--show-toplevel' }, state.git_calls[1])
      assert.same({ 'gh', 'api', 'graphql' }, vim.list_slice(state.git_calls[2], 1, 3))
      assert.same({
        { 'git', 'remote' },
        REV_PARSE_BASE,
        REV_PARSE_HEAD,
        REV_PARSE_PR_REF,
        BOTH_FETCH,
        { 'git', 'worktree', 'add', '--detach', wt, 'review-nvim/pr-7' },
        -- 作業ツリー基準: add した worktree の cwd で `git diff <base>` の単引数形
        { 'git', 'diff', 'origin/main' },
      }, vim.list_slice(state.git_calls, 3, 9))
      assert.equals(wt, state.git_opts[9].cwd)

      local saved = store.load(REPO_TOP, 'pr-7').data
      assert.same({
        version = 1,
        id = 'pr-7',
        repo = REPO_TOP,
        mode = 'pr',
        base = 'origin/main',
        head = 'review-nvim/pr-7',
        pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
        worktree = { path = wt, created_by_us = true },
        status = 'open',
        -- open_file はレビュー完了マークを変えない (開始 open でも false のまま、
        -- マークは panel の x でトグル)
        files = { ['a.lua'] = { viewed = false } },
        comments = {},
        general = {},
        created_at = 4321,
        updated_at = 4321,
      }, saved)
      assert.same(
        { msg = 'review.nvim: PR #7: Add widget', level = vim.log.levels.INFO },
        state.notifications[1]
      )
      assert.equals(1, #state.notifications)
      assert.equals('pr-7', session_handler.active().id)
    end
  )

  it(
    'worktree 作成中は過渡メッセージを出し、完了でクリアする (notify には残らない)',
    function()
      install_git(fork_seq(pr_json()))
      pr_handler.start '7'
      assert.same({ 'review.nvim: creating the review worktree...', '<clear>' }, state.progress)
      assert.same(
        { msg = 'review.nvim: PR #7: Add widget', level = vim.log.levels.INFO },
        state.notifications[1]
      )
      assert.equals(1, #state.notifications)
    end
  )

  it(
    'remote に origin が無い repo は最初の remote を採用する (default remote 無ければ origin で試す)',
    function()
      install_git {
        top_ok,
        json_ok(pr_json()),
        function()
          return { code = 0, stdout = 'gitlab\n', stderr = '' }
        end,
        base_stale,
        not_a_branch,
        ref_missing,
        git_ok, -- fetch
        git_ok, -- worktree add
        diff_a,
      }

      pr_handler.start '7'

      -- 照合する remote-tracking ref も fetch 先も同じ remote
      assert.same(
        { 'git', 'rev-parse', '--verify', 'refs/remotes/gitlab/main' },
        state.git_calls[4]
      )
      assert.same({
        'git',
        'fetch',
        'gitlab',
        'refs/pull/7/head:review-nvim/pr-7',
        '+refs/heads/main:refs/remotes/gitlab/main',
      }, state.git_calls[7])
      assert.same({ 'git', 'diff', 'gitlab/main' }, state.git_calls[9])
    end
  )

  it(
    'remote 0 件 (PR 番号のみで解決不能) は URL 入力を促す WARN。ref の照合も fetch も走らない',
    function()
      install_git {
        top_ok,
        json_ok(pr_json()),
        git_ok, -- git remote: 0 件
      }

      pr_handler.start '7'

      assert.same({
        msg = 'review.nvim: cannot resolve the git remote; run inside the PR target repository, '
          .. 'or identify the repository with :Review pr <URL>',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(3, #state.git_calls) -- top, gh, remotes
      assert.is_nil(session_handler.active())
    end
  )

  it(
    'pull ref と base をまとめた fetch の失敗は WARN で中断し、worktree を作らない',
    function()
      local seq = fork_seq(pr_json())
      seq[7] = function()
        return {
          code = 128,
          stdout = '',
          stderr = "fatal: couldn't find remote ref refs/pull/7/head\n",
        }
      end
      install_git { unpack(seq, 1, 7) }

      pr_handler.start '7'

      assert.same({
        msg = 'review.nvim: cannot fetch the head and base branch "main" of PR #7 from origin: '
          .. "fatal: couldn't find remote ref refs/pull/7/head",
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.equals(7, #state.git_calls)
      assert.is_nil(store.load(REPO_TOP, 'pr-7').data)
    end
  )
end)

-- fetch は手元の ref が remote tip と一致しないものだけを取る (pr-worktree.md
-- 「PR 解決」手順 2・3)。照合の結果ごとに、走る fetch (なし / どちらか / 両方を
-- 1 回で) と、その後 worktree add・diff まで進むことを pin する。
describe('pr-handler fetch は remote tip と違う ref だけ', function()
  use_env()

  for _, case in ipairs {
    {
      name = '同一 repo・base 最新なら fetch しない',
      refs = { base_fresh, sha_ok },
      fetch = nil,
      head = 'topic',
    },
    {
      name = '同一 repo・base が古ければ base だけ fetch する',
      refs = { base_stale, sha_ok },
      fetch = BASE_FETCH,
      head = 'topic',
    },
    {
      name = '同一 repo・remote-tracking ref が無ければ base を fetch する',
      refs = { ref_missing, sha_ok },
      fetch = BASE_FETCH,
      head = 'topic',
    },
    {
      name = 'fork・base も pull ref も最新なら fetch しない',
      refs = { base_fresh, not_a_branch, head_fresh },
      fetch = nil,
      head = 'review-nvim/pr-7',
    },
    {
      name = 'fork・pull ref だけ古ければ pull ref だけ fetch する',
      refs = { base_fresh, not_a_branch, ref_missing },
      fetch = HEAD_FETCH,
      head = 'review-nvim/pr-7',
    },
    {
      name = 'fork・base だけ古ければ base だけ fetch する',
      refs = { base_stale, not_a_branch, head_fresh },
      fetch = BASE_FETCH,
      head = 'review-nvim/pr-7',
    },
    {
      name = 'fork・両方古ければ 1 回の fetch で両方取る',
      refs = { base_stale, not_a_branch, ref_missing },
      fetch = BOTH_FETCH,
      head = 'review-nvim/pr-7',
    },
  } do
    it(case.name, function()
      local seq = { top_ok, json_ok(pr_json()), origin_ok }
      vim.list_extend(seq, case.refs)
      if case.fetch ~= nil then
        table.insert(seq, git_ok)
      end
      vim.list_extend(seq, { git_ok, diff_a }) -- worktree add, diff
      install_git(seq)

      pr_handler.start '7'

      local wt = paths.worktree_path(REPO_TOP, 'pr-7')
      local expected = { { 'git', 'remote' }, REV_PARSE_BASE, REV_PARSE_HEAD }
      if case.head ~= 'topic' then
        table.insert(expected, REV_PARSE_PR_REF)
      end
      if case.fetch ~= nil then
        table.insert(expected, case.fetch)
      end
      vim.list_extend(expected, {
        { 'git', 'worktree', 'add', '--detach', wt, case.head },
        { 'git', 'diff', 'origin/main' },
      })
      assert.same(expected, vim.list_slice(state.git_calls, 3, #seq))
      assert.equals('pr-7', session_handler.active().id)
    end)
  end

  it(
    'base ブランチが remote に無い (baseRef null) なら照合せずに fetch し、失敗は base 用 WARN',
    function()
      install_git {
        top_ok,
        json_ok(pr_json { baseRef = vim.NIL }),
        origin_ok,
        sha_ok, -- rev-parse topic (remote-tracking ref の照合は飛ばす)
        function()
          return {
            code = 128,
            stdout = '',
            stderr = "fatal: couldn't find remote ref refs/heads/main\n",
          }
        end,
      }

      pr_handler.start '7'

      assert.same({ { 'git', 'remote' }, REV_PARSE_HEAD, BASE_FETCH }, {
        state.git_calls[3],
        state.git_calls[4],
        state.git_calls[5],
      })
      assert.same({
        msg = 'review.nvim: cannot fetch the PR base branch "main" from origin: '
          .. "fatal: couldn't find remote ref refs/heads/main",
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(5, #state.git_calls)
      assert.is_nil(session_handler.active())
    end
  )

  it(
    'fork の pull ref だけの fetch 失敗は git の理由を WARN して中断する',
    function()
      install_git {
        top_ok,
        json_ok(pr_json()),
        origin_ok,
        base_fresh,
        not_a_branch,
        ref_missing,
        function()
          return {
            code = 128,
            stdout = '',
            stderr = "fatal: couldn't find remote ref refs/pull/7/head\n",
          }
        end,
      }

      pr_handler.start '7'

      assert.same({
        msg = "review.nvim: fatal: couldn't find remote ref refs/pull/7/head",
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(7, #state.git_calls)
      assert.is_nil(session_handler.active())
    end
  )
end)

describe('pr-handler 同一 repo branch / 失敗分岐', function()
  use_env()

  -- 同一 repo PR で base が古い = fetch 1 回の標準経路
  local function same_repo_seq(gh_stdout)
    return {
      top_ok,
      json_ok(gh_stdout),
      origin_ok, -- git remote
      base_stale, -- rev-parse refs/remotes/origin/main
      sha_ok, -- rev-parse topic ok
      git_ok, -- base fetch
      git_ok, -- worktree add
      diff_a, -- diff (cwd=worktree)
    }
  end

  it('gh の remote なし失敗は英語原文でなく日本語 + 対処を返す', function()
    install_git {
      top_ok,
      function()
        return { code = 1, stdout = '', stderr = 'no git remotes found\n' }
      end,
    }

    pr_handler.start '7'

    assert.same({
      msg = 'review.nvim: this repo has no git remote (e.g. origin); '
        .. ':Review pr only works against a GitHub remote',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(2, #state.git_calls) -- top, gh のみ
  end)

  it(
    '同一 repo の branch headRefName が解決できるなら refs/pull fetch なしで worktree 化 (mode=pr は常時作成)',
    function()
      install_git(same_repo_seq(pr_json()))

      pr_handler.start '7'

      local wt = paths.worktree_path(REPO_TOP, 'pr-7')
      assert.same({
        { 'git', 'remote' },
        REV_PARSE_BASE,
        REV_PARSE_HEAD,
        BASE_FETCH,
        { 'git', 'worktree', 'add', '--detach', wt, 'topic' },
        { 'git', 'diff', 'origin/main' },
        -- 初期開き (ui/windows + session.open_file) = base scratch 充填の git show。
        -- 引数・窓契約は session_spec が pin 済みなのでここでは発生のみ見る。
        { 'git', 'show', 'origin/main:a.lua' },
      }, vim.list_slice(state.git_calls, 3, 9))
      assert.equals(9, #state.git_calls)
      assert.equals(wt, state.git_opts[8].cwd)
      local saved = store.load(REPO_TOP, 'pr-7').data
      assert.equals('topic', saved.head)
      assert.equals('origin/main', saved.base)
    end
  )

  it('gh が E_GH を返す (未 auth) は WARN 通知で gh 以後を走らせない', function()
    install_git {
      top_ok,
      function()
        return {
          code = 1,
          stdout = '',
          stderr = 'To get started with GitHub, please run: gh auth login\n',
        }
      end,
    }

    pr_handler.start '7'

    assert.same({
      msg = 'review.nvim: gh is not logged in; run `gh auth login`',
      level = vim.log.levels.WARN,
    }, state.notifications[1])
    assert.equals(2, #state.git_calls)
  end)

  it(
    'worktree add 失敗 (衝突) は E_WORKTREE 案内で開始中断 (セッション save なし)',
    function()
      local seq = same_repo_seq(pr_json())
      seq[7] = function()
        return { code = 255, stdout = '', stderr = 'fatal: collision\n' }
      end -- add fail
      seq[8] = git_ok -- prune
      seq[9] = function()
        return { code = 255, stdout = '', stderr = 'fatal: collision\n' }
      end -- add retry fail
      install_git(seq)

      pr_handler.start '7'

      assert.equals(vim.log.levels.WARN, state.notifications[1].level)
      assert.matches('cannot create the worktree', state.notifications[1].msg)
      -- 作成に失敗したら diff は走らない (worktree 基準の単引数形は成立しないため)
      local has_diff = false
      for _, cmd in ipairs(state.git_calls) do
        if cmd[2] == 'diff' then
          has_diff = true
        end
      end
      assert.is_false(has_diff)
      assert.is_nil(store.load(REPO_TOP, 'pr-7').data)
      assert.is_nil(session_handler.active())
    end
  )

  it('closed PR もレビュー開始でき、INFO に状態を添える', function()
    install_git(same_repo_seq(pr_json { state = 'MERGED' }))

    pr_handler.start '7'

    assert.same({
      msg = 'review.nvim: PR #7: Add widget (MERGED)',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.equals('pr-7', session_handler.active().id)
  end)

  it(
    '既存 pr-7 (旧形式 base=baseRefName) は base を <remote>/<base> へ移し継承確認 -> 再開',
    function()
      store.save {
        version = 1,
        id = 'pr-7',
        repo = REPO_TOP,
        mode = 'pr',
        base = 'main',
        head = 'review-nvim/pr-7',
        pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
        worktree = vim.NIL,
        status = 'closed',
        files = {},
        comments = {
          {
            id = 'c1',
            file = 'a.lua',
            line = 2,
            end_line = 2,
            body = 'keep',
            anchor = { before = 'line1', line = 'line2', after = vim.NIL },
            state = 'active',
            created_at = 100,
          },
        },
        created_at = 1,
      }
      install_git {
        top_ok,
        json_ok(pr_json()),
        origin_ok,
        base_stale,
        not_a_branch,
        ref_missing,
        git_ok, -- fetch (pull ref + base)
        git_ok, -- worktree add (mode=pr)
        diff_a, -- diff (cwd=worktree)
      }

      pr_handler.start '7'

      assert.equals(1, #state.inputs)
      assert.equals(
        'review.nvim: the existing session pr-7 '
          .. '(origin/main..review-nvim/pr-7, 1 comments) shares the same refs as '
          .. 'this start '
          .. 'inherit its comments and open? [y/N]: ',
        state.inputs[1].prompt
      )
      local saved = store.load(REPO_TOP, 'pr-7').data
      assert.equals('keep', saved.comments[1].body)
      assert.equals('open', saved.status)
      assert.equals('origin/main', saved.base)
      -- slug 衝突 WARN を出していない (旧形式の base でも同じ PR として継承できる)
      for _, n in ipairs(state.notifications) do
        assert.are_not.equal(vim.log.levels.WARN, n.level)
      end
    end
  )

  it(
    'URL 入力では URL の owner/repo で PR を引き、番号は /pull/<n> から採る (pr-12)',
    function()
      install_git(
        same_repo_seq(pr_json { number = 12, url = 'https://github.com/acme/demo/pull/12' })
      )

      pr_handler.start 'https://github.com/acme/demo/pull/12'

      assert.same(
        { 'gh', 'api', '--hostname', 'github.com', 'graphql', '-f', 'owner=acme' },
        vim.list_slice(state.git_calls[2], 1, 7)
      )
      assert.same({ '-F', 'number=12' }, vim.list_slice(state.git_calls[2], 10, 11))
      local saved = store.load(REPO_TOP, 'pr-12').data
      assert.same({ number = 12, url = 'https://github.com/acme/demo/pull/12' }, saved.pr)
    end
  )

  it(
    'base の fetch 失敗は PR base 用の WARN で中断し、worktree を作らない',
    function()
      local seq = same_repo_seq(pr_json())
      seq[6] = function()
        return {
          code = 128,
          stdout = '',
          stderr = "fatal: couldn't find remote ref refs/heads/main\n",
        }
      end -- base fetch 失敗
      install_git { unpack(seq, 1, 6) }

      pr_handler.start '7'

      assert.same({
        msg = 'review.nvim: cannot fetch the PR base branch "main" from origin: '
          .. "fatal: couldn't find remote ref refs/heads/main",
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.equals(6, #state.git_calls) -- top, gh, remotes, rev-parse x2, base fetch (add なし)
      assert.is_nil(store.load(REPO_TOP, 'pr-7').data)
      assert.is_nil(session_handler.active())
    end
  )
end)

-- 旧形式 base の書き換えは「base が素の baseRefName」かつ「head 一致」のときだけ
-- (pr-worktree.md「PR 解決」3)。それ以外の既存は別の refs 組なので JSON を
-- 書き換えず、従来どおり slug 衝突 WARN を出す (同一 repo head = topic で開始)。
describe('pr-handler 旧形式 base の書き換え条件', function()
  use_env()

  local function saved_pr7(base, head)
    store.save {
      version = 1,
      id = 'pr-7',
      repo = REPO_TOP,
      mode = 'pr',
      base = base,
      head = head,
      pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
      worktree = vim.NIL,
      status = 'closed',
      files = {},
      comments = {},
      created_at = 1,
    }
    return store.load(REPO_TOP, 'pr-7').data
  end

  for _, case in ipairs {
    {
      name = '旧形式 base でも head が違えば書き換えず slug 衝突',
      base = 'main',
      head = 'review-nvim/pr-7',
    },
    {
      name = 'head が同じでも base が別ブランチ (PR の付け替え) なら書き換えず slug 衝突',
      base = 'develop',
      head = 'topic',
    },
  } do
    it(case.name, function()
      local before = saved_pr7(case.base, case.head)
      install_git {
        top_ok,
        json_ok(pr_json()),
        origin_ok,
        base_stale,
        sha_ok, -- rev-parse topic ok (同一 repo head)
        git_ok, -- base fetch
      }

      pr_handler.start '7'

      assert.same({
        msg = ('review.nvim: slug pr-7: an existing session (%s..%s) is registered. '):format(
          case.base,
          case.head
        ) .. 'delete it with :Review delete pr-7',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.same(before, store.load(REPO_TOP, 'pr-7').data)
      assert.equals(6, #state.git_calls) -- worktree add へ進まない
    end)
  end
end)
