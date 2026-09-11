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

  -- unknown 経路を通過するのは subcommands 表に無い語だけ (登録済みは handler へ
  -- 委譲され cmd_* の結果が返る)。prompt も実装済みで handler 経路のため、
  -- 「未登録語 = unknown」は実際に未登録の語で検証する。
  it(
    '未登録サブコマンド (subcommands 表に無い語) は unknown として扱う',
    function()
      local res = review.command { 'zzz', 'a.lua' }

      assert.same({
        msg = 'review.nvim: unknown subcommand: zzz. ' .. USAGE,
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

describe(
  ':Review prompt 結線と prompt_* / file 補完 (ai-prompt.md「実装の配置」facade)',
  function()
    local cli = require 'review.git.cli'
    local paths = require 'review.store.paths'
    local store = require 'review.store.session'
    local session_handler = require 'review.handlers.session'
    local prompt_handler = require 'review.handlers.prompt'

    local PROMPT_REPO = vim.fn.tempname()
    vim.fn.mkdir(PROMPT_REPO, 'p')

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
          on_exit { code = 0, stdout = PROMPT_REPO .. '\n', stderr = '' }
        else
          on_exit { code = 0, stdout = RAW, stderr = '' }
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
      ':Review prompt (引数なし) は handlers.prompt.all に委譲し結果型を返す',
      function()
        local called_with_opts = 'unset'
        local real_all = prompt_handler.all
        prompt_handler.all = function(opts)
          called_with_opts = opts
          return result.ok 'from-all'
        end

        local res = review.command { 'prompt' }

        prompt_handler.all = real_all
        assert.equals(nil, called_with_opts)
        assert.same({ __class = 'review.Result', ok = true, data = 'from-all' }, res)
      end
    )

    it(':Review prompt <file> は handlers.prompt.for_file に path を渡す', function()
      local seen_path
      local real_for_file = prompt_handler.for_file
      prompt_handler.for_file = function(path, opts)
        seen_path = path
        assert.equals(nil, opts)
        return result.ok 'from-file'
      end

      local res = review.command { 'prompt', 'lua/review/diff.lua' }

      prompt_handler.for_file = real_for_file
      assert.equals('lua/review/diff.lua', seen_path)
      assert.same({ __class = 'review.Result', ok = true, data = 'from-file' }, res)
    end)

    it(
      'Lua API prompt_all / prompt_for_file は active 不在で E_NOT_ACTIVE を同期で返す',
      function()
        assert.same({
          __class = 'review.Result',
          ok = false,
          error = 'review.nvim: レビュー進行中セッションがありません',
          code = 'E_NOT_ACTIVE',
        }, review.prompt_all())
        assert.same({
          __class = 'review.Result',
          ok = false,
          error = 'review.nvim: レビュー進行中セッションがありません',
          code = 'E_NOT_ACTIVE',
        }, review.prompt_for_file('a.lua', { copy = false }))
      end
    )

    it(
      'prompt_all({copy=false}) は実セッションの全コメントを整形して返す (facade->core 結線)',
      function()
        session_handler.start { base = 'main', head = 'feature' }
        -- handlers/prompt_spec と同じ理由: git stub の porcelain 非空で worktree 作成判断が
        -- 必要に転ぶと @path が絶対 path 分岐へ入り、facade->core の整形 pin が観測できない。
        -- worktree 無し (作成判断 skip) の shape に揃える。
        session_handler.active().worktree = vim.NIL
        table.insert(session_handler.active().comments, {
          id = 'c1',
          file = 'a.lua',
          line = 2,
          end_line = 2,
          body = 'use map',
          anchor = vim.NIL,
          state = 'active',
          created_at = 4321,
        })

        local res = review.prompt_all { copy = false }

        assert.same({
          __class = 'review.Result',
          ok = true,
          data = {
            text = table.concat({
              'Review the changes in main..feature. Please address the comments below.',
              '',
              '@a.lua#L2',
              'use map',
            }, '\n'),
            count = 1,
          },
        }, res)
      end
    )

    it(
      '`prompt` の file 引数補完は active セッションの diff ファイル一覧 (customlist)',
      function()
        session_handler.start { base = 'main', head = 'feature' }

        assert.same({ 'a.lua' }, review.complete('a', ':Review prompt a', 18))
        assert.same({ 'a.lua' }, review.complete('', ':Review prompt ', 15))
      end
    )

    it(
      'file 補完は active 不在では空、2 引目ではサブコマンド補完を維持する',
      function()
        assert.same({}, review.complete('a', ':Review prompt a', 18))
        assert.same({ 'pr', 'prompt' }, review.complete('p', ':Review p', 9))
      end
    )
  end
)

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

describe(':Review start の base/head ref 補完 (cmdline)', function()
  mock_notify_and_handlers()

  local cli = require 'review.git.cli'

  -- for-each-ref の同期 handle を模す。lists は namespace -> stdout。
  -- fail=true は両系統の wait timeout (返り値 nil)。
  local function stub_refs(lists, fail)
    local captured = { calls = 0 }
    cli._set_system(function(cmd)
      captured.calls = captured.calls + 1
      local ns = cmd[#cmd]
      return {
        wait = function()
          if fail then
            return nil
          end
          return { code = 0, stdout = lists[ns] or '', stderr = '' }
        end,
        kill = function() end,
      }
    end)
    cli._set_executable(function()
      return 1
    end)
    return captured
  end

  local REFS = { ['refs/heads/'] = 'alpha\nfeature\nmain\n', ['refs/tags/'] = 'v1.0\n' }

  before_each(function()
    review._reset_ref_completion_cache()
    review._set_now(nil)
  end)
  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
    review._set_now(nil)
  end)

  it('start pos3 lead 空: branches -> tags 順の全候補', function()
    stub_refs(REFS)
    assert.same({ 'alpha', 'feature', 'main', 'v1.0' }, review.complete('', 'Review start ', 0))
  end)

  it('lead prefix 一致に絞る', function()
    stub_refs(REFS)
    assert.same({ 'feature' }, review.complete('fe', 'Review start fe', 0))
  end)

  it('pos4 (head 位置) も同じ候補源 (base を打った後 continue)', function()
    stub_refs(REFS)
    assert.same({ 'v1.0' }, review.complete('v', 'Review start main v', 0))
  end)

  it('2 回目は cache が効き git を再取得しない', function()
    local captured = stub_refs(REFS)
    assert.same({ 'alpha', 'feature', 'main', 'v1.0' }, review.complete('', 'Review start ', 0))
    assert.equals(2, captured.calls)
    assert.same({ 'alpha' }, review.complete('al', 'Review start al', 0))
    assert.equals(2, captured.calls)
  end)

  it('TTL 経過後は再取得する (針は _set_now 注入)', function()
    local captured = stub_refs(REFS)
    local t = 1000.0
    review._set_now(function()
      return t
    end)
    review.complete('', 'Review start ', 0)
    assert.equals(2, captured.calls)
    t = t + 31.0
    review.complete('', 'Review start ', 0)
    assert.equals(4, captured.calls)
  end)

  it(
    '取得失敗は候補 0 件・無通知、失敗 TTL (5s) 中は再取得せず、失効後に再取得',
    function()
      local captured = { calls = 0 }
      local fail = true
      cli._set_system(function(_)
        captured.calls = captured.calls + 1
        return {
          wait = function()
            if fail then
              return nil
            end
            return { code = 0, stdout = '', stderr = '' }
          end,
          kill = function() end,
        }
      end)
      cli._set_executable(function()
        return 1
      end)
      local t = 1000.0
      review._set_now(function()
        return t
      end)

      assert.same({}, review.complete('', 'Review start ', 0))
      assert.same({}, notifications)
      assert.equals(2, captured.calls)

      t = t + 4.0
      assert.same({}, review.complete('', 'Review start ', 0))
      assert.equals(2, captured.calls)

      t = t + 2.0
      -- heads / tags の見分けは namespace で行う (上のスタブを差し替えて成功経路へ)
      fail = false
      cli._set_system(function(cmd)
        captured.calls = captured.calls + 1
        local ns = cmd[#cmd]
        return {
          wait = function()
            return {
              code = 0,
              stdout = (ns == 'refs/heads/') and 'alpha\nfeature\nmain\n' or 'v1.0\n',
              stderr = '',
            }
          end,
          kill = function() end,
        }
      end)
      assert.same({ 'alpha', 'feature', 'main', 'v1.0' }, review.complete('', 'Review start ', 0))
      assert.equals(4, captured.calls)
    end
  )

  it('サブコマンド位置では refs を引かない (start 候補だけ)', function()
    local captured = stub_refs(REFS)
    assert.same({ 'start' }, review.complete('s', 'Review s', 0))
    assert.equals(0, captured.calls)
  end)
end)

describe(':Review delete <id> と :Review pr <number> の補完', function()
  mock_notify_and_handlers()

  local cli = require 'review.git.cli'
  local store = require 'review.store.session'
  local paths = require 'review.store.paths'

  local data_dir
  before_each(function()
    data_dir = vim.fn.tempname()
    vim.fn.mkdir(data_dir, 'p')
    paths._set_data_dir(data_dir)
    store._set_notify(function() end)
    cli._set_executable(function()
      return 1
    end)
  end)
  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
    paths._set_data_dir(nil)
    store._set_notify(nil)
    vim.fn.delete(data_dir, 'rf')
  end)

  -- run_sync 経路の handle を模す。cmd 結合文字列 -> {code, stdout}。
  local function stub(responses)
    cli._set_system(function(cmd)
      local key = table.concat(cmd, ' ')
      for pattern, r in pairs(responses) do
        if key:match(pattern) then
          return {
            wait = function()
              return { code = r.code or 0, stdout = r.stdout or '', stderr = '' }
            end,
            kill = function() end,
          }
        end
      end
      return {
        wait = function()
          return nil
        end,
        kill = function() end,
      }
    end)
  end

  local function seed(ids)
    for _, id in ipairs(ids) do
      assert.is_true(store.save({
        repo = '/repo/top',
        id = id,
        base = 'main',
        head = id,
        mode = 'branch',
        state = 'closed',
        comments = {},
      }).ok)
    end
  end

  it('delete 3 引目は store のセッション id (lead prefix 一致)', function()
    seed { 'main--a', 'main--ab', 'pr-7' }
    stub { ['rev%-parse'] = { stdout = '/repo/top\n' } }

    assert.same({ 'main--a', 'main--ab' }, review.complete('main--a', ':Review delete main--a', 20))
    assert.same({ 'main--a', 'main--ab', 'pr-7' }, review.complete('', ':Review delete ', 16))
    assert.same({ 'pr%-7' and 'pr-7' or 'pr-7' }, review.complete('pr', ':Review delete pr', 17))
  end)

  it('delete 補完は repo 解決不能・store 空で空候補 (通知しない)', function()
    stub {}
    assert.same({}, review.complete('', ':Review delete ', 16))

    stub { ['rev%-parse'] = { stdout = '/no/such/repo\n' } }
    assert.same({}, review.complete('', ':Review delete ', 16))
    assert.equals(0, #notifications)
  end)

  it('delete 2 引目従来 (サブコマンド候補) は維持', function()
    assert.same({ 'delete' }, review.complete('delete', ':Review delete', 14))
  end)

  it('pr 3 引目は gh open PR の番号 (lead prefix 一致)', function()
    stub {
      ['gh.*pr'] = {
        stdout = ' [{"number":41},{"number":7}] ',
      },
    }
    assert.same({ '41', '7' }, review.complete('', ':Review pr ', 11))
    assert.same({ '41' }, review.complete('4', ':Review pr 4', 12))
  end)

  it('pr 補完は gh 失敗・gh 不在で空候補 (通知しない)', function()
    stub { ['gh.*pr'] = { code = 1, stdout = '' } }
    assert.same({}, review.complete('', ':Review pr ', 11))
    assert.equals(0, #notifications)

    cli._set_system(nil)
    cli._set_executable(function()
      return 0
    end)
    assert.same({}, review.complete('', ':Review pr ', 11))
  end)

  it('pr 2 引目従来 (サブコマンド候補) は維持', function()
    assert.same({ 'pr', 'prompt' }, review.complete('pr', ':Review pr', 10))
  end)
end)
