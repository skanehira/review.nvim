-- git/gh: `gh pr view <n|url> --json ...` の PR 解決アダプタ
-- (pr-worktree.md「PR 解決」手順 1、DESIGN.md「アーキテクチャと技術選定」gh 注入行)。
-- 実 GitHub には触れない (issue 非スコープ)。注入 system スタブで
-- 引数組み立て・JSON 変換・E_GH / E_PR の結果型分岐を検証する。
local gh = require 'review.git.gh'
local cli = require 'review.git.cli'
local config = require 'review.config'

local REAL_NOTIFY = vim.notify

local PR_JSON = vim.json.encode {
  number = 7,
  title = 'Add widget',
  baseRefName = 'main',
  headRefName = 'topic',
  headRepositoryOwner = { login = 'forkguy' },
  url = 'https://github.com/acme/demo/pull/7',
  state = 'OPEN',
}

local state = {}

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {} }
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    cli._set_executable(function()
      return 1
    end)
  end)
  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
    config.reset()
    vim.notify = REAL_NOTIFY
  end)
end

local function stub_exit(out)
  state.calls = {}
  cli._set_system(function(cmd, opts, on_exit)
    table.insert(state.calls, { cmd = cmd, opts = opts })
    on_exit(out)
  end)
end

describe('git/gh pr_view 引数組み立て', function()
  use_env()

  it(
    'pr view <target> --json number,...,url,state を gh cwd=repo で実行し JSON を data に返す',
    function()
      stub_exit { code = 0, stdout = PR_JSON, stderr = '' }

      local received
      gh.pr_view({ target = '7', cwd = '/repo' }, function(res)
        received = res
      end)

      assert.same({
        'gh',
        'pr',
        'view',
        '7',
        '--json',
        'number,title,baseRefName,headRefName,headRepositoryOwner,url,state',
      }, state.calls[1].cmd)
      assert.equals('/repo', state.calls[1].opts.cwd)
      assert.same({
        __class = 'review.Result',
        ok = true,
        data = {
          number = 7,
          title = 'Add widget',
          baseRefName = 'main',
          headRefName = 'topic',
          headRepositoryOwner = { login = 'forkguy' },
          url = 'https://github.com/acme/demo/pull/7',
          state = 'OPEN',
        },
      }, received)
    end
  )

  it('URL ターゲットは gh へそのまま渡す (gh が URL も解ける)', function()
    stub_exit { code = 0, stdout = PR_JSON, stderr = '' }
    gh.pr_view({ target = 'https://github.com/acme/demo/pull/7' }, function() end)
    assert.equals('https://github.com/acme/demo/pull/7', state.calls[1].cmd[4])
  end)

  it('config.gh_bin の注入が実行バイナリ名に効く', function()
    config.setup { gh_bin = '/stub/gh' }
    stub_exit { code = 0, stdout = PR_JSON, stderr = '' }
    gh.pr_view({ target = '7' }, function() end)
    assert.equals('/stub/gh', state.calls[1].cmd[1])
  end)
end)

describe('git/gh pr_view 結果型分岐 (E_GH / E_PR)', function()
  use_env()

  it(
    'gh 不在 (実行不能) は E_GH「gh not found」で cb に返す (system を起動しない)',
    function()
      cli._set_executable(function()
        return 0
      end)
      local launched = false
      cli._set_system(function()
        launched = true
      end)

      local received
      gh.pr_view({ target = '7', cwd = '/repo' }, function(res)
        received = res
      end)

      assert.equals(false, launched)
      assert.same({
        __class = 'review.Result',
        ok = false,
        error = 'gh not found',
        code = 'E_GH',
      }, received)
    end
  )

  it(
    '未 auth (stderr に gh auth login を含む失敗) は E_GH + 「gh auth login を実行してください」に変換する',
    function()
      stub_exit {
        code = 1,
        stdout = '',
        stderr = 'To get started with GitHub, please run: gh auth login\n',
      }

      local received
      gh.pr_view({ target = '7' }, function(res)
        received = res
      end)

      assert.same({
        __class = 'review.Result',
        ok = false,
        data = { stdout = '', code = 1 },
        error = 'gh is not logged in; run `gh auth login`',
        code = 'E_GH',
      }, received)
    end
  )

  it(
    'PR 非存在 (auth を含まない失敗) は E_PR + gh stderr 末尾 1 行をそのまま返す',
    function()
      stub_exit { code = 1, stdout = '', stderr = 'could not resolve PR # 999\n' }

      local received
      gh.pr_view({ target = '999' }, function(res)
        received = res
      end)

      assert.same({
        __class = 'review.Result',
        ok = false,
        data = { stdout = '', code = 1 },
        error = 'could not resolve PR # 999',
        code = 'E_PR',
      }, received)
    end
  )

  it(
    'JSON デコード不能 (stdout が不正) は E_GH で例外化せず cb に返す',
    function()
      stub_exit { code = 0, stdout = 'not json', stderr = '' }

      local received
      gh.pr_view({ target = '7' }, function(res)
        received = res
      end)

      assert.same({
        __class = 'review.Result',
        ok = false,
        error = 'failed to parse the output of gh pr view',
        code = 'E_GH',
      }, received)
    end
  )
end)

local REPO = { owner = 'acme', repo = 'demo' }

describe('git/gh repo_from_url', function()
  it('PR url から owner/repo を取り出す', function()
    assert.same(
      { owner = 'acme', repo = 'demo' },
      gh.repo_from_url 'https://github.com/acme/demo/pull/7'
    )
  end)

  it('URL でない / nil は nil を返す', function()
    local cases = {
      -- 対照: URL なら owner/repo が取れる (常に nil を返す実装をここで落とす)
      { input = 'https://github.com/acme/demo/pull/7', want = { owner = 'acme', repo = 'demo' } },
      { input = nil, want = nil },
      { input = '7', want = nil },
    }
    for _, case in ipairs(cases) do
      assert.same(case.want, gh.repo_from_url(case.input), tostring(case.input))
    end
  end)
end)

describe('git/gh api 一覧系 (引数組み立て + JSON 変換)', function()
  use_env()

  it('list_review_comments は --paginate 付きで GET し配列を data に返す', function()
    stub_exit { code = 0, stdout = '[{"id":10,"path":"a.lua","body":"hi"}]', stderr = '' }
    local received
    gh.list_review_comments({ repo = REPO, number = 7 }, function(res)
      received = res
    end)
    assert.same(
      { 'gh', 'api', 'repos/acme/demo/pulls/7/comments', '--paginate' },
      state.calls[1].cmd
    )
    assert.same({
      __class = 'review.Result',
      ok = true,
      data = { { id = 10, path = 'a.lua', body = 'hi' } },
    }, received)
  end)

  it('list_reviews は pulls/{n}/reviews を GET する', function()
    stub_exit { code = 0, stdout = '[{"state":"PENDING","id":3}]', stderr = '' }
    local received
    gh.list_reviews({ repo = REPO, number = 7 }, function(res)
      received = res
    end)
    assert.same(
      { 'gh', 'api', 'repos/acme/demo/pulls/7/reviews', '--paginate' },
      state.calls[1].cmd
    )
    assert.equals('PENDING', received.data[1].state)
  end)

  it('list_issue_comments は issues/{n}/comments を GET する', function()
    stub_exit { code = 0, stdout = '[{"body":"general"}]', stderr = '' }
    local received
    gh.list_issue_comments({ repo = REPO, number = 7 }, function(res)
      received = res
    end)
    assert.same(
      { 'gh', 'api', 'repos/acme/demo/issues/7/comments', '--paginate' },
      state.calls[1].cmd
    )
    assert.equals('general', received.data[1].body)
  end)
end)

describe('git/gh api 書き込み系 (JSON body を --input で渡す)', function()
  use_env()

  -- 書き込み系は gh api の -f/-F フォームが整数を文字列化して 422 になる実測のため、
  -- JSON body を一時ファイルに書いて --input で渡す。ここではファイル内容を読んで
  -- (cmd, payload) を記録し、応答を返す。
  local function install_write(response_stdout)
    state.calls = {}
    cli._set_system(function(cmd, _opts, on_exit)
      local payload = nil
      -- argv は --input の一時ファイル名 (実行ごとに変わる) を '<input>' に置き換えた写し
      local argv = vim.deepcopy(cmd)
      for i = 1, #cmd - 1 do
        if cmd[i] == '--input' then
          local f = io.open(cmd[i + 1], 'r')
          if f ~= nil then
            payload = vim.json.decode(f:read '*a')
            f:close()
          end
          argv[i + 1] = '<input>'
        end
      end
      table.insert(state.calls, { cmd = cmd, argv = argv, payload = payload })
      on_exit { code = 0, stdout = response_stdout, stderr = '' }
    end)
  end

  it('create_review_comment は新規行コメントを JSON で POST (body/path/line)', function()
    install_write '{"id":50,"body":"ok"}'
    local received
    gh.create_review_comment({
      repo = REPO,
      number = 7,
      path = 'src/a.lua',
      line = 12,
      body = 'use insert',
    }, function(res)
      received = res
    end)
    local c = state.calls[1]
    assert.same({
      'gh',
      'api',
      '--method',
      'POST',
      'repos/acme/demo/pulls/7/comments',
      '--input',
      '<input>',
    }, c.argv)
    assert.same({ body = 'use insert', path = 'src/a.lua', line = 12 }, c.payload)
    assert.equals(50, received.data.id)
  end)

  it('create_review_comment は in_reply_to 指定で返信 POST (他 params 無し)', function()
    install_write '{"id":51}'
    gh.create_review_comment({
      repo = REPO,
      number = 7,
      body = 'reply text',
      in_reply_to = 101,
    }, function() end)
    assert.same({ body = 'reply text', in_reply_to = 101 }, state.calls[1].payload)
    assert.same(
      { 'gh', 'api', '--method', 'POST', 'repos/acme/demo/pulls/7/comments', '--input', '<input>' },
      state.calls[1].argv
    )
  end)

  it('create_review_comment は subject_type=file でファイルレベルを POST', function()
    install_write '{"id":52}'
    gh.create_review_comment({
      repo = REPO,
      number = 7,
      path = 'src/a.lua',
      subject_type = 'file',
      body = 'file note',
    }, function() end)
    assert.same(
      { body = 'file note', path = 'src/a.lua', subject_type = 'file' },
      state.calls[1].payload
    )
  end)

  it('create_review は event (+body) を JSON で POST', function()
    install_write '{"id":9,"state":"APPROVED"}'
    local received
    gh.create_review({ repo = REPO, number = 7, event = 'APPROVE', body = 'lgtm' }, function(res)
      received = res
    end)
    assert.same({ event = 'APPROVE', body = 'lgtm' }, state.calls[1].payload)
    assert.same(
      { 'gh', 'api', '--method', 'POST', 'repos/acme/demo/pulls/7/reviews', '--input', '<input>' },
      state.calls[1].argv
    )
    assert.equals('APPROVED', received.data.state)
  end)

  it('create_review は body 省略時 body キーを載せない', function()
    install_write '{}'
    gh.create_review({ repo = REPO, number = 7, event = 'COMMENT' }, function() end)
    assert.same({ event = 'COMMENT' }, state.calls[1].payload)
  end)

  it('create_review は comments 配列 (行コメント) を JSON に載せる', function()
    install_write '{"id":9,"state":"COMMENTED"}'
    gh.create_review({
      repo = REPO,
      number = 7,
      event = 'COMMENT',
      body = 'summary',
      comments = { { path = 'a.lua', line = 12, body = 'note' } },
    }, function() end)
    assert.same({
      event = 'COMMENT',
      body = 'summary',
      comments = { { path = 'a.lua', line = 12, body = 'note' } },
    }, state.calls[1].payload)
    assert.same(
      { 'gh', 'api', '--method', 'POST', 'repos/acme/demo/pulls/7/reviews', '--input', '<input>' },
      state.calls[1].argv
    )
  end)

  it('list_review_comments_by_review は GET /reviews/{id}/comments', function()
    stub_exit {
      code = 0,
      stdout = '[{"id":61,"path":"a.lua","line":12,"body":"note"}]',
      stderr = '',
    }
    local received
    gh.list_review_comments_by_review({ repo = REPO, number = 7, review_id = 9 }, function(res)
      received = res
    end)
    assert.same(
      { 'gh', 'api', 'repos/acme/demo/pulls/7/reviews/9/comments', '--paginate' },
      state.calls[1].cmd
    )
    assert.equals(61, received.data[1].id)
  end)

  it('api 書き込みの未 auth 失敗は E_GH に変換する', function()
    stub_exit { code = 1, stdout = '', stderr = 'please run: gh auth login\n' }
    local received
    gh.create_review_comment(
      { repo = REPO, number = 7, path = 'a', line = 1, body = 'x' },
      function(res)
        received = res
      end
    )
    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 1 },
      error = 'gh is not logged in; run `gh auth login`',
      code = 'E_GH',
    }, received)
  end)

  it('api の 404 失敗は E_PR に変換する', function()
    stub_exit { code = 1, stdout = '', stderr = 'gh: Not Found (HTTP 404)\n' }
    local received
    gh.list_review_comments({ repo = REPO, number = 999 }, function(res)
      received = res
    end)
    assert.same({
      __class = 'review.Result',
      ok = false,
      data = { stdout = '', code = 1 },
      error = 'gh: Not Found (HTTP 404)',
      code = 'E_PR',
    }, received)
  end)
end)
