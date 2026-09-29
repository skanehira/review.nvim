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
      assert.equals(true, received.ok)
      assert.equals('Add widget', received.data.title)
      assert.equals(7, received.data.number)
      assert.equals('main', received.data.baseRefName)
      assert.equals('topic', received.data.headRefName)
      assert.equals('OPEN', received.data.state)
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
    assert.is_nil(gh.repo_from_url(nil))
    assert.is_nil(gh.repo_from_url '7')
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
    assert.equals(true, received.ok)
    assert.equals(10, received.data[1].id)
    assert.equals('hi', received.data[1].body)
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

describe('git/gh api 書き込み系 (引数組み立て)', function()
  use_env()

  it('create_review_comment は新規行コメントを POST (body/path/line)', function()
    stub_exit { code = 0, stdout = '{"id":50,"body":"ok"}', stderr = '' }
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
    assert.same({
      'gh',
      'api',
      '--method',
      'POST',
      'repos/acme/demo/pulls/7/comments',
      '-F',
      'body=use insert',
      '-F',
      'path=src/a.lua',
      '-f',
      'line=12',
    }, state.calls[1].cmd)
    assert.equals(50, received.data.id)
  end)

  it('create_review_comment は in_reply_to 指定で返信 POST (他 params 無し)', function()
    stub_exit { code = 0, stdout = '{"id":51}', stderr = '' }
    gh.create_review_comment({
      repo = REPO,
      number = 7,
      body = 'reply text',
      in_reply_to = 101,
    }, function() end)
    assert.same({
      'gh',
      'api',
      '--method',
      'POST',
      'repos/acme/demo/pulls/7/comments',
      '-F',
      'body=reply text',
      '-f',
      'in_reply_to=101',
    }, state.calls[1].cmd)
  end)

  it('create_review_comment は subject_type=file でファイルレベルを POST', function()
    stub_exit { code = 0, stdout = '{"id":52}', stderr = '' }
    gh.create_review_comment({
      repo = REPO,
      number = 7,
      path = 'src/a.lua',
      subject_type = 'file',
      body = 'file note',
    }, function() end)
    assert.same({
      'gh',
      'api',
      '--method',
      'POST',
      'repos/acme/demo/pulls/7/comments',
      '-F',
      'body=file note',
      '-F',
      'path=src/a.lua',
      '-f',
      'subject_type=file',
    }, state.calls[1].cmd)
  end)

  it('create_review は event (+body) を POST', function()
    stub_exit { code = 0, stdout = '{"id":9,"state":"APPROVED"}', stderr = '' }
    local received
    gh.create_review({ repo = REPO, number = 7, event = 'APPROVE', body = 'lgtm' }, function(res)
      received = res
    end)
    assert.same({
      'gh',
      'api',
      '--method',
      'POST',
      'repos/acme/demo/pulls/7/reviews',
      '-f',
      'event=APPROVE',
      '-F',
      'body=lgtm',
    }, state.calls[1].cmd)
    assert.equals('APPROVED', received.data.state)
  end)

  it('create_review は body 省略時 body フラグを付けない', function()
    stub_exit { code = 0, stdout = '{}', stderr = '' }
    gh.create_review({ repo = REPO, number = 7, event = 'COMMENT' }, function() end)
    assert.same({
      'gh',
      'api',
      '--method',
      'POST',
      'repos/acme/demo/pulls/7/reviews',
      '-f',
      'event=COMMENT',
    }, state.calls[1].cmd)
  end)

  it('submit_review は PUT pulls/{n}/reviews/{id}', function()
    stub_exit { code = 0, stdout = '{"state":"APPROVED"}', stderr = '' }
    gh.submit_review({ repo = REPO, number = 7, review_id = 3, event = 'APPROVE' }, function() end)
    assert.same({
      'gh',
      'api',
      '--method',
      'PUT',
      'repos/acme/demo/pulls/7/reviews/3',
      '-f',
      'event=APPROVE',
    }, state.calls[1].cmd)
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
    assert.same('E_GH', received.code)
    assert.equals('gh is not logged in; run `gh auth login`', received.error)
  end)

  it('api の 404 失敗は E_PR に変換する', function()
    stub_exit { code = 1, stdout = '', stderr = 'gh: Not Found (HTTP 404)\n' }
    local received
    gh.list_review_comments({ repo = REPO, number = 999 }, function(res)
      received = res
    end)
    assert.same('E_PR', received.code)
    assert.matches('Not Found', received.error)
  end)
end)
