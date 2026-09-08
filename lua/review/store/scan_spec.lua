-- 起動時 open scan の検証 (persistence-restore.md「入出力と振る舞い」起動時、
-- 「実装の配置」: notify と worktree 掃除兼用の store 層スキャン)。
-- 退避・tmpdir 注入の土台は store.session と共通 (session_spec と同じ境界 DI)。

local paths = require 'review.store.paths'
local scan = require 'review.store.scan'
local session = require 'review.store.session'

local REPO = '/repo-x'
local REPO_HASH = 'f90cc21f45278cc2' -- shasum 実測値 sha1('/repo-x') 先頭 16 桁
local OTHER_REPO = '/repo-y'
local OTHER_HASH = 'dfcd58d3c11bac7d' -- shasum 実測値 sha1('/repo-y') 先頭 16 桁
local FIXED_NOW = 1234

local function sample(overrides)
  local s = {
    version = 1,
    id = 'main--feature',
    repo = REPO,
    mode = 'branch',
    base = 'main',
    head = 'feature',
    pr = vim.NIL,
    worktree = { path = '/tmp/wt', created_by_us = true },
    status = 'open',
    files = {},
    comments = {},
    created_at = 900,
    updated_at = FIXED_NOW,
  }
  for key, value in pairs(overrides or {}) do
    s[key] = value
  end
  return s
end

local function isolate_store()
  local state = {}
  before_each(function()
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    state.notices = {}
    paths._set_data_dir(state.dir)
    session._set_now(function()
      return FIXED_NOW
    end)
    session._set_notify(function(msg, level)
      table.insert(state.notices, { msg = msg, level = level })
    end)
  end)
  after_each(function()
    paths._set_data_dir(nil)
    session._set_now(nil)
    session._set_notify(nil)
    vim.fn.delete(state.dir, 'rf')
  end)
  return state
end

describe('scan.open_sessions', function()
  local state = isolate_store()

  it(
    'status=open のセッションのみ返す (closed は除外、ファイルはそのまま)',
    function()
      local open = sample()
      session.save(open)
      local closed = vim.deepcopy(sample())
      closed.id = 'main--bugfix'
      closed.head = 'bugfix'
      closed.status = 'closed'
      session.save(closed)

      local res = scan.open_sessions(REPO)
      assert.same({ __class = 'review.Result', ok = true, data = { open } }, res)
      -- closed は「返らない」だけ。ディスクからも消えていない (list は全件返す)
      local all = {}
      for _, s in ipairs(session.list(REPO).data) do
        all[s.id] = s
      end
      assert.same({ ['main--feature'] = open, ['main--bugfix'] = closed }, all)
    end
  )

  it(
    'open が無い repo の scan は空配列を返す (閉じたレビューを再通知しない)',
    function()
      local closed = vim.deepcopy(sample())
      closed.status = 'closed'
      session.save(closed)
      assert.same({ __class = 'review.Result', ok = true, data = {} }, scan.open_sessions(REPO))
    end
  )

  it('保存実績がゼロの repo (ディレクトリ未作成) も空配列', function()
    assert.same({ __class = 'review.Result', ok = true, data = {} }, scan.open_sessions(REPO))
  end)

  it(
    '他 repo のセッションは走査しない (repo-hash ディレクトリで隔離)',
    function()
      local mine = sample()
      session.save(mine)
      session.save(sample { repo = OTHER_REPO, worktree = vim.NIL })

      assert.same(
        { __class = 'review.Result', ok = true, data = { mine } },
        scan.open_sessions(REPO)
      )
      assert.is_true(vim.fn.isdirectory(state.dir .. '/review.nvim/sessions/' .. OTHER_HASH) == 1)
    end
  )

  it(
    'scan 中の破損ファイルは load と同じ退避経路を通り結果から外れる',
    function()
      session.save(sample())
      local dir = state.dir .. '/review.nvim/sessions/' .. REPO_HASH
      vim.fn.mkdir(dir, 'p')
      vim.fn.writefile({ '{ oops' }, dir .. '/stale.json')

      local res = scan.open_sessions(REPO)
      assert.same({ __class = 'review.Result', ok = true, data = { sample() } }, res)
      assert.same({ '{ oops' }, vim.fn.readfile(dir .. '/stale.json.corrupt'))
      assert.equals(1, #state.notices)
    end
  )
end)
