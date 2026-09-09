-- handlers/pr: `:Review pr <number|url>` の PR 解決 (gh) -> head ref 解決
-- (同一 repo branch / fork は refs/pull 一時 ref) -> 開始フロー委譲
-- (pr-worktree.md「入出力と振る舞い」PR 解決 + worktree 作成判断 mode=pr)。
-- gh / git は同一の cli 注入スタブで引数組み立てと応答を制御する。
local cli = require 'review.git.cli'
local config = require 'review.config'
local paths = require 'review.store.paths'
local pr_handler = require 'review.handlers.pr'
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

local REAL_NOTIFY = vim.notify
local REAL_INPUT = vim.ui.input

local function install_git(responses)
  state.git_calls = {}
  cli._set_system(function(cmd, opts, on_exit)
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    if responses[idx] == nil then
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
      function()
        return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
      end, -- 6 diff main..review-nvim/pr-7
      git_ok, -- 7 worktree add (mode=pr は常時作成)
    }
  end

  it(
    'gh -> rev-parse 失敗 -> origin で fetch -> diff -> worktree add -> pr-7 セッション開始 (INFO: PR タイトル)',
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
      assert.same({ 'git', 'diff', 'main', 'review-nvim/pr-7' }, state.git_calls[6])
      local wt = paths.worktree_path(REPO_TOP, 'pr-7')
      assert.same(
        { 'git', 'worktree', 'add', '--detach', wt, 'review-nvim/pr-7' },
        state.git_calls[7]
      )

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
        files = { ['a.lua'] = { viewed = false } },
        comments = {},
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
        git_ok,
        function()
          return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
        end,
        git_ok,
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
        msg = 'review.nvim: git remote が解決できません。PR のターゲットリポジトリ内で実行するか、'
          .. ':Review pr <URL> でリポジトリを特定してください',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(4, #state.git_calls) -- top, gh, rev-parse, remotes (fetch なし)
      assert.is_nil(session_handler.active())
    end
  )
end)

describe('pr-handler 同一 repo branch / 失敗分岐', function()
  use_env()

  it(
    '同一 repo の branch headRefName が解決できるなら refs/pull fetch なしで worktree 化 (mode=pr は常時作成)',
    function()
      install_git {
        top_ok,
        json_ok(pr_json()),
        sha_ok, -- rev-parse topic ok
        function()
          return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
        end, -- diff
        git_ok, -- worktree add
      }

      pr_handler.start '7'

      assert.same({ 'git', 'diff', 'main', 'topic' }, state.git_calls[4])
      local wt = paths.worktree_path(REPO_TOP, 'pr-7')
      assert.same({ 'git', 'worktree', 'add', '--detach', wt, 'topic' }, state.git_calls[5])
      assert.equals(5, #state.git_calls)
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
      msg = 'review.nvim: gh 未ログインです。`gh auth login` を実行してください',
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
          return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
        end, -- diff
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
      assert.matches('worktree を作成できません', state.notifications[1].msg)
      assert.is_nil(store.load(REPO_TOP, 'pr-7').data)
      assert.is_nil(session_handler.active())
    end
  )

  it('closed PR もレビュー開始でき、INFO に状態を添える', function()
    install_git {
      top_ok,
      json_ok(pr_json { state = 'MERGED' }),
      sha_ok,
      function()
        return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
      end,
      git_ok,
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
      git_ok,
      function()
        return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
      end,
      git_ok,
    }

    pr_handler.start '7'

    assert.equals(1, #state.inputs)
    assert.equals(
      'review.nvim: 既存セッション pr-7 (main..review-nvim/pr-7, コメント 1 件) に同じ '
        .. 'refs 組の開始です。コメント内容を継承して開きますか？ [y/N]: ',
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
        function()
          return { code = 0, stdout = RAW_DIFF_A, stderr = '' }
        end,
        git_ok,
      }

      pr_handler.start 'https://github.com/acme/demo/pull/12'

      assert.equals('https://github.com/acme/demo/pull/12', state.git_calls[2][4])
      local saved = store.load(REPO_TOP, 'pr-12').data
      assert.same({ number = 12, url = 'https://github.com/acme/demo/pull/12' }, saved.pr)
    end
  )
end)
