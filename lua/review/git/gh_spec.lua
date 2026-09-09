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
    'gh 不在 (実行不能) は E_GH「gh が見つかりません」で cb に返す (system を起動しない)',
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
        error = 'gh が見つかりません',
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
        error = 'gh 未ログインです。`gh auth login` を実行してください',
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
        error = 'gh pr view の出力を解析できませんでした',
        code = 'E_GH',
      }, received)
    end
  )
end)
