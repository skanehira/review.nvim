local review = require 'review'
local result = require 'review.core.result'
local config = require 'review.config'

local USAGE = 'usage: :Review [start <base> [head] | pr <number|url> | list | '
  .. 'close | delete <id> | prompt [file]]'

-- describe 間で共有する spy 復元先と一時 dir (file scope の local を明示する。
-- 無宣言代入はグローバルになり lint / 他 spec の汚染になる)。
local real_notify
local real_input
local state_dir

-- plenary busted は describe 外のフックを持たないため、notify スパイと
-- cmd_* ハンドラの掃除を各 describe 先で registered する helper。
local notifications

local function mock_notify_and_handlers()
  local saved_handlers
  before_each(function()
    config.reset()
    notifications = {}
    -- 実装済みの cmd_* を消すと後続 describe (実 handlers) が壊れるため、
    -- テスト前の値を捕捉して戻す (nil だったものだけ nil に戻す)。
    saved_handlers = {}
    for _, name in ipairs {
      'cmd_start',
      'cmd_pr',
      'cmd_list',
      'cmd_close',
      'cmd_delete',
      'cmd_prompt',
      'cmd_resume',
    } do
      saved_handlers[name] = review[name]
    end
    real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = real_notify
    for name, handler in pairs(saved_handlers) do
      review[name] = handler
    end
  end)
end

describe('review.command 委譲', function()
  mock_notify_and_handlers()

  it('既知サブコマンドのハンドラに args をそのまま渡す', function()
    local received
    review.cmd_start = function(args)
      received = args
      return result.ok 'start-called'
    end

    local res = review.command { 'start', 'main', 'feature' }

    assert.same({ 'start', 'main', 'feature' }, received)
    assert.same({ __class = 'review.Result', ok = true, data = 'start-called' }, res)
  end)

  it(':Review 無印は cmd_resume に委譲する (args は空)', function()
    local called = 0
    review.cmd_start = nil
    review.cmd_resume = function(args)
      called = called + 1
      assert.same({}, args)
      return result.ok 'resumed'
    end

    local res = review.command {}
    assert.equals(1, called)
    assert.same({ __class = 'review.Result', ok = true, data = 'resumed' }, res)
  end)

  it('未知サブコマンドは WARN + usage 1 行の通知と err 結果を返す', function()
    local res = review.command { 'bogus', 'x' }

    assert.same({
      msg = 'review.nvim: unknown subcommand: bogus. ' .. USAGE,
      level = vim.log.levels.WARN,
    }, notifications[1])
    assert.equals(1, #notifications)
    assert.same({
      __class = 'review.Result',
      ok = false,
      error = 'review.nvim: unknown subcommand: bogus',
      code = nil,
    }, res)
  end)

  it(
    '未実装サブコマンド (prompt は ai-prompt issue) は unknown として扱う',
    function()
      local res = review.command { 'prompt', 'a.lua' }

      assert.same({
        msg = 'review.nvim: unknown subcommand: prompt. ' .. USAGE,
        level = vim.log.levels.WARN,
      }, notifications[1])
      assert.equals(false, res.ok)
    end
  )

  it(
    'ハンドラが err を返した場合 command もその err をそのまま返す',
    function()
      review.cmd_close = function()
        return result.err('review.nvim: no active session', result.codes.E_NOT_ACTIVE)
      end

      assert.same({
        __class = 'review.Result',
        ok = false,
        error = 'review.nvim: no active session',
        code = 'E_NOT_ACTIVE',
      }, review.command { 'close' })
    end
  )
end)

describe('サブコマンド結線 (#5 で実装された start/close/delete/...)', function()
  local paths = require 'review.store.paths'
  local cli = require 'review.git.cli'

  before_each(function()
    config.reset()
    notifications = {}
    real_notify = vim.notify
    real_input = vim.ui.input
    vim.ui.input = function(_opts, cb)
      cb(nil)
    end
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)
  after_each(function()
    vim.notify = real_notify
    vim.ui.input = real_input
    cli._set_system(nil)
    cli._set_executable(nil)
    paths._set_data_dir(nil)
  end)

  it(':Review start の 0 引目は usage 通知で受けつけない', function()
    local res = review.command { 'start' }
    assert.equals(false, res.ok)
    assert.same({
      msg = 'review.nvim: :Review start <base> [head] の形式で指定してください',
      level = vim.log.levels.WARN,
    }, notifications[1])
  end)

  it(':Review pr の 0 引目は usage 通知 (ハンドラを発火しない)', function()
    local res = review.command { 'pr' }
    assert.equals(false, res.ok)
    assert.same({
      msg = 'review.nvim: :Review pr <number|url> の形式で指定してください',
      level = vim.log.levels.WARN,
    }, notifications[1])
  end)

  it(
    'complete は pr / prompt を prefix 一致で返す (サブコマンド表と結線の一致)',
    function()
      assert.same({ 'pr', 'prompt' }, review.complete('pr', '', 0))
    end
  )

  it(':Review delete の 0 引目は usage 通知', function()
    local res = review.command { 'delete' }
    assert.equals(false, res.ok)
    assert.same(1, #notifications)
    assert.equals(vim.log.levels.WARN, notifications[1].level)
  end)

  it(':Review close は active 不在で E_NOT_ACTIVE を同期で返す', function()
    require('review.handlers.session')._reset()
    local res = review.command { 'close' }
    assert.same({
      __class = 'review.Result',
      ok = false,
      error = 'review.nvim: アクティブなセッションがありません',
      code = 'E_NOT_ACTIVE',
    }, res)
  end)

  it('start はディスパッチ受理を返し、list/resume は err を返さない', function()
    -- git 本体の成否は非同期。同期戻りは受理のみ (DESIGN.md API 一覧)。
    cli._set_system(function(_cmd, _opts, on_exit)
      on_exit { code = 128, stdout = '', stderr = 'fatal: not a git repository\n' }
    end)
    cli._set_executable(function()
      return 1
    end)
    assert.same(
      { __class = 'review.Result', ok = true, data = nil },
      review.command { 'start', 'main', 'feature' }
    )
    assert.same({ __class = 'review.Result', ok = true, data = nil }, review.command {})
    assert.same({ __class = 'review.Result', ok = true, data = nil }, review.command { 'list' })
  end)

  it('Lua API: 結果型 passthrough (start/close/delete)', function()
    assert.equals('review.Result', review.start({}).__class)
    assert.equals(false, review.start({}).ok)
    assert.equals('E_NOT_ACTIVE', review.close().code)
    assert.equals(result.class, review.delete({}).__class)
  end)
end)

describe('Lua API resume({id}) 直接復元 (DESIGN.md「API 一覧」)', function()
  local cli = require 'review.git.cli'
  local paths = require 'review.store.paths'
  local store = require 'review.store.session'
  local session_handler = require 'review.handlers.session'

  local RAW = table.concat({
    'diff --git a/a.lua b/a.lua',
    'index 1..2 100644',
    '--- a/a.lua',
    '+++ b/a.lua',
    '@@ -1 +1,2 @@',
    ' one',
    '+two',
    '',
  }, '\n')

  local RESUME_REPO = vim.fn.tempname()
  vim.fn.mkdir(RESUME_REPO, 'p')

  local function save(id, status)
    store.save {
      version = 1,
      id = id,
      repo = RESUME_REPO,
      mode = 'branch',
      base = id:match '^(.-)--' or id,
      head = id:match '--(.*)$' or id,
      pr = vim.NIL,
      worktree = vim.NIL,
      status = status,
      files = {},
      comments = {},
      created_at = 1,
      updated_at = 1,
    }
  end

  before_each(function()
    config.reset()
    notifications = {}
    real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
    state_dir = vim.fn.tempname()
    vim.fn.mkdir(state_dir, 'p')
    paths._set_data_dir(state_dir)
    store._set_notify(function() end)
    store._set_now(function()
      return 4321
    end)
    session_handler._reset()
    session_handler._set_now(function()
      return 4321
    end)
    cli._set_system(function(cmd, _opts, on_exit)
      if cmd[2] == 'rev-parse' then
        on_exit { code = 0, stdout = RESUME_REPO .. '\n', stderr = '' }
      elseif cmd[2] == 'diff' then
        on_exit { code = 0, stdout = RAW, stderr = '' }
      else
        on_exit { code = 0, stdout = '', stderr = '' }
      end
    end)
    cli._set_executable(function()
      return 1
    end)
    vim.cmd 'tabnew'
  end)
  after_each(function()
    vim.notify = real_notify
    paths._set_data_dir(nil)
    store._set_notify(nil)
    store._set_now(nil)
    session_handler._reset()
    session_handler._set_now(nil)
    cli._set_system(nil)
    cli._set_executable(nil)
    vim.cmd 'tabclose!'
    vim.fn.delete(state_dir, 'rf')
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  it(
    'open が複数あっても vim.ui.select を通らず id のセッションが即開始する',
    function()
      save('main--feature', 'open')
      save('x--y', 'closed') -- id 指定は status を問わない
      local selected = 0
      local real_select = vim.ui.select
      vim.ui.select = function(_items, _opts, on_choice)
        selected = selected + 1
        on_choice(nil)
      end

      local res = review.resume { id = 'x--y' }

      vim.ui.select = real_select
      assert.equals(true, res.ok)
      assert.equals(0, selected)
      assert.equals('x--y', session_handler.active().id)
      assert.equals('open', store.load(RESUME_REPO, 'x--y').data.status)
    end
  )

  it(
    'unknown id は WARN 通知で開始しない (無言の無印フォールバック不做)',
    function()
      save('main--feature', 'open')

      assert.equals(true, review.resume({ id = 'no--pe' }).ok) -- ディスパッチ受理

      assert.same({
        msg = 'review.nvim: セッション no--pe が見つかりません',
        level = vim.log.levels.WARN,
      }, notifications[1])
      assert.is_nil(session_handler.active())
      -- 無印 (選択 UI / 即復元) にはフォールバックしない
      assert.are_not.equals('main--feature', (session_handler.active() or {}).id)
    end
  )

  it('id 無しの resume は従来どおり無印復元 (open 1 件 = 即復元)', function()
    save('main--feature', 'open')

    assert.equals(true, review.resume().ok)

    assert.equals('main--feature', session_handler.active().id)
  end)
end)

describe('VimEnter 継続通知フック (setup で登録)', function()
  local cli = require 'review.git.cli'
  local paths = require 'review.store.paths'
  local store = require 'review.store.session'

  before_each(function()
    config.reset()
    notifications = {}
    real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
    state_dir = vim.fn.tempname()
    vim.fn.mkdir(state_dir, 'p')
    paths._set_data_dir(state_dir)
    store._set_notify(function() end)
    cli._set_system(function(_cmd, _opts, on_exit)
      on_exit { code = 0, stdout = '/hook/repo\n', stderr = '' }
    end)
    cli._set_executable(function()
      return 1
    end)
  end)
  after_each(function()
    vim.notify = real_notify
    cli._set_system(nil)
    cli._set_executable(nil)
    paths._set_data_dir(nil)
    store._set_notify(nil)
    vim.fn.delete(state_dir, 'rf')
  end)

  it('auto_notify_resume=true では open セッションを VimEnter で通知する', function()
    store.save {
      version = 1,
      id = 'main--feature',
      repo = '/hook/repo',
      mode = 'branch',
      base = 'main',
      head = 'feature',
      pr = vim.NIL,
      worktree = vim.NIL,
      status = 'open',
      files = {},
      comments = {},
      created_at = 1,
      updated_at = 1,
    }
    review.setup {}
    assert.equals(0, #notifications)
    vim.api.nvim_exec_autocmds('VimEnter', {
      group = vim.api.nvim_create_augroup('review_nvim', { clear = false }),
      modeline = false,
    })
    assert.same({
      msg = 'review.nvim: main--feature のレビューが続けられます (:Review で復元)',
      level = vim.log.levels.INFO,
    }, notifications[1])
  end)

  it('auto_notify_resume=false では通知しない', function()
    store.save {
      version = 1,
      id = 'main--feature',
      repo = '/hook/repo',
      mode = 'branch',
      base = 'main',
      head = 'feature',
      pr = vim.NIL,
      worktree = vim.NIL,
      status = 'open',
      files = {},
      comments = {},
      created_at = 1,
      updated_at = 1,
    }
    review.setup { auto_notify_resume = false }
    vim.api.nvim_exec_autocmds('VimEnter', {
      group = vim.api.nvim_create_augroup('review_nvim', { clear = false }),
      modeline = false,
    })
    assert.equals(0, #notifications)
  end)
end)

describe('review.complete', function()
  mock_notify_and_handlers()

  it(
    '空 arglead では DESIGN.md「API 一覧」のサブコマンドを宣言順で返す',
    function()
      assert.same(
        { 'start', 'pr', 'list', 'close', 'delete', 'prompt' },
        review.complete('', '', 0)
      )
    end
  )

  it('prefix 一致に絞り込む', function()
    assert.same({ 'close' }, review.complete('cl', '', 0))
    assert.same({ 'pr', 'prompt' }, review.complete('p', '', 0))
  end)

  it('一致なしは空リスト (Tab 補完候補が出ない)', function()
    assert.same({}, review.complete('zzz', '', 0))
    -- 絞り込み動作自体は上の test で正アサーション済み (リトマス B 対応)
  end)
end)
