-- handlers/pr: `:Review pr <number|url>` の PR 解決 (gh) -> head ref 解決
-- (同一 repo branch / fork は refs/pull 一時 ref) -> 開始フロー委譲
-- (pr-worktree.md「入出力と振る舞い」PR 解決 + worktree 作成判断 mode=pr)。
-- gh / git は同一の cli 注入スタブで引数組み立てと応答を制御する。
local config = require 'review.config'
local paths = require 'review.store.paths'
local pr_handler = require 'review.handlers.pr'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local git_stub = require 'helpers.git_stub'
local nvim_env = require 'helpers.nvim_env'
local session_env = require 'helpers.session_env'

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

local function pr_json(overrides)
  local meta = {
    number = 7,
    title = 'Add widget',
    baseRefName = 'main',
    headRefName = 'topic',
    headRepositoryOwner = { login = 'forkguy' },
    url = 'https://github.com/acme/demo/pull/7',
    state = 'OPEN',
  }
  for k, v in pairs(overrides or {}) do
    meta[k] = v
  end
  return vim.json.encode(meta)
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

local git_ok = function()
  return { code = 0, stdout = '', stderr = '' }
end

local state = {}

-- gh api (PR 開始時のコメント取り込み pr-comments) は引数組み立てを対象とする
-- 本 spec では空応答で通し、call 記録・応答 index・通知に含めない。3 窓開通の
-- base scratch 充填 (git show) は窓の中身の契約として session_spec が pin 済みなので
-- 既定応答で通す。それ以外の想定外実行は error。
local function install_git(responses)
  git_stub.install_queue(state, responses, { gh_api_empty = true })
end

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, inputs = {}, input_answer = 'y', git_calls = {} }
    session_env.make_dirs(state)
    session_env.inject_store(state)
    session_env.capture_notify(state, true)
    session_env.answer_input(state)
    nvim_env.wipe_review_buffers()
    nvim_env.isolate_tab(state)
  end)
  after_each(function()
    nvim_env.close_tab(state.tab)
    session_env.release(state)
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

  local function fork_seq(gh_stdout)
    return {
      top_ok, -- 1
      json_ok(gh_stdout), -- 2 gh pr view
      function()
        return { code = 128, stdout = '', stderr = "fatal: ambiguous argument 'topic'\n" }
      end, -- 3 rev-parse topic (同一 repo branch 無し = fork)
      function()
        return { code = 0, stdout = 'origin\nupstream\n', stderr = '' }
      end, -- 4 remotes
      git_ok, -- 5 fetch refs/pull/7/head:review-nvim/pr-7
      git_ok, -- 6 worktree add (mode=pr は常時作成)
      function()
        return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
      end, -- 7 diff <base> (cwd=worktree、作業ツリー基準)
    }
  end

  it(
    'gh -> rev-parse 失敗 -> fetch -> worktree add -> diff(cwd=wt) -> pr-7 開始 (INFO: PR タイトル)',
    function()
      install_git(fork_seq(pr_json()))

      local res = pr_handler.start '7'
      assert.equals(true, res.ok)

      assert.same({ 'git', 'rev-parse', '--show-toplevel' }, state.git_calls[1])
      assert.equals('gh', state.git_calls[2][1])
      assert.same({ 'git', 'rev-parse', '--verify', 'topic' }, state.git_calls[3])
      assert.same({ 'git', 'remote' }, state.git_calls[4])
      assert.same(
        { 'git', 'fetch', 'origin', 'refs/pull/7/head:review-nvim/pr-7' },
        state.git_calls[5]
      )
      local wt = paths.worktree_path(REPO_TOP, 'pr-7')
      assert.same(
        { 'git', 'worktree', 'add', '--detach', wt, 'review-nvim/pr-7' },
        state.git_calls[6]
      )
      -- 作業ツリー基準: add した worktree の cwd で `git diff <base>` の単引数形
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[7])
      assert.equals(wt, state.git_opts[7].cwd)

      local saved = store.load(REPO_TOP, 'pr-7').data
      assert.same({
        version = 1,
        id = 'pr-7',
        repo = REPO_TOP,
        mode = 'pr',
        base = 'main',
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
    'worktree 作成中は過渡 notify を出し、完了後は notifications に残らない',
    function()
      install_git(fork_seq(pr_json()))
      pr_handler.start '7'
      -- shown: 作成中に vim.notify が発行された (stub がフラグ記録)
      assert.is_true(state.worktree_notify_shown)
      -- hidden: 完了時に nvim_echo クリアで消えるため最終リストには残らない
      for _, n in ipairs(state.notifications) do
        if type(n.msg) == 'string' then
          assert.is_nil(n.msg:find('creating the review worktree', 1, true))
        end
      end
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
          return { code = 128, stdout = '', stderr = "fatal: ambiguous argument 'topic'\n" }
        end,
        function()
          return { code = 0, stdout = 'gitlab\n', stderr = '' }
        end,
        git_ok, -- fetch
        git_ok, -- worktree add
        function()
          return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
        end, -- diff
      }

      pr_handler.start '7'

      assert.same(
        { 'git', 'fetch', 'gitlab', 'refs/pull/7/head:review-nvim/pr-7' },
        state.git_calls[5]
      )
    end
  )

  it(
    'remote 0 件 (PR 番号のみで解決不能) は URL 入力を促す WARN。fetch は走らない',
    function()
      install_git {
        top_ok,
        json_ok(pr_json()),
        function()
          return { code = 128, stdout = '', stderr = "fatal: ambiguous argument 'topic'\n" }
        end,
        function()
          return { code = 0, stdout = '', stderr = '' }
        end,
      }

      pr_handler.start '7'

      assert.same({
        msg = 'review.nvim: cannot resolve the git remote; run inside the PR target repository, '
          .. 'or identify the repository with :Review pr <URL>',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(4, #state.git_calls) -- top, gh, rev-parse, remotes (fetch なし)
      assert.is_nil(session_handler.active())
    end
  )
end)

describe('pr-handler 同一 repo branch / 失敗分岐', function()
  use_env()

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
    assert.equals(2, #state.git_calls) -- top, gh pr_view のみ
  end)

  it(
    '同一 repo の branch headRefName が解決できるなら refs/pull fetch なしで worktree 化 (mode=pr は常時作成)',
    function()
      install_git {
        top_ok,
        json_ok(pr_json()),
        sha_ok, -- rev-parse topic ok
        git_ok, -- worktree add
        function()
          return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
        end, -- diff (cwd=worktree)
      }

      pr_handler.start '7'

      local wt = paths.worktree_path(REPO_TOP, 'pr-7')
      assert.same({ 'git', 'worktree', 'add', '--detach', wt, 'topic' }, state.git_calls[4])
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[5])
      assert.equals(wt, state.git_opts[5].cwd)
      -- 初期開き (ui/windows + session.open_file) = base scratch 充填の git show。
      -- 引数・窓契約は session_spec が pin 済みなのでここでは発生のみ見る。
      assert.same({ 'git', 'show', 'main:a.lua' }, state.git_calls[6])
      assert.equals(6, #state.git_calls)
      assert.equals('topic', store.load(REPO_TOP, 'pr-7').data.head)
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
      install_git {
        top_ok,
        json_ok(pr_json()),
        sha_ok,
        function()
          return { code = 255, stdout = '', stderr = 'fatal: collision\n' }
        end, -- add fail
        git_ok, -- prune
        function()
          return { code = 255, stdout = '', stderr = 'fatal: collision\n' }
        end, -- add retry fail
      }

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
    install_git {
      top_ok,
      json_ok(pr_json { state = 'MERGED' }),
      sha_ok,
      git_ok, -- worktree add
      function()
        return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
      end, -- diff
    }

    pr_handler.start '7'

    assert.same({
      msg = 'review.nvim: PR #7: Add widget (MERGED)',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.equals('pr-7', session_handler.active().id)
  end)

  it('既存 pr-7 セッションの開始は継承確認 -> comments 保持で再開', function()
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
      function()
        return { code = 128, stdout = '', stderr = "fatal: ambiguous argument 'topic'\n" }
      end,
      function()
        return { code = 0, stdout = 'origin\n', stderr = '' }
      end,
      git_ok, -- fetch
      git_ok, -- worktree add (mode=pr)
      function()
        return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
      end, -- diff (cwd=worktree)
    }

    pr_handler.start '7'

    assert.equals(1, #state.inputs)
    assert.equals(
      'review.nvim: the existing session pr-7 '
        .. '(main..review-nvim/pr-7, 1 comments) shares the same refs as '
        .. 'this start '
        .. 'inherit its comments and open? [y/N]: ',
      state.inputs[1].prompt
    )
    local saved = store.load(REPO_TOP, 'pr-7').data
    assert.equals('keep', saved.comments[1].body)
    assert.equals('open', saved.status)
  end)

  it(
    'URL 入力では gh へ URL をそのまま渡し、番号は /pull/<n> から採る (pr-12)',
    function()
      install_git {
        top_ok,
        json_ok(pr_json { number = 12, url = 'https://github.com/acme/demo/pull/12' }),
        sha_ok,
        git_ok, -- worktree add
        function()
          return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
        end, -- diff
      }

      pr_handler.start 'https://github.com/acme/demo/pull/12'

      assert.equals('https://github.com/acme/demo/pull/12', state.git_calls[2][4])
      local saved = store.load(REPO_TOP, 'pr-12').data
      assert.same({ number = 12, url = 'https://github.com/acme/demo/pull/12' }, saved.pr)
    end
  )
end)
