-- plugin/review.lua の登録機構を検証する spec。
-- plugin/ 直下に置くと rtp 自動 source の対象になってしまい
-- busted 子プロセス以外でも実行されるため、lua/review/ 配下に置く
-- (plenary の再帰 spec 発見に載る位置)。

local review = require 'review'

local function plugin_path()
  return vim.fn.getcwd() .. '/plugin/review.lua'
end

local function reset_plugin()
  vim.g.loaded_review_nvim = nil
  pcall(vim.api.nvim_del_user_command, 'Review')
end

describe('plugin/review.lua', function()
  local real_notify
  local notifications

  before_each(function()
    reset_plugin()
    real_notify = vim.notify
    notifications = {}
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = real_notify
    review.cmd_start = nil
    reset_plugin()
  end)

  it('source すると :Review が定義される', function()
    dofile(plugin_path())
    assert.equals(2, vim.fn.exists ':Review')
  end)

  it('2 回 source してもvim.g ガードで再登録せずエラーにならない', function()
    dofile(plugin_path())
    local ok = pcall(dofile, plugin_path())
    assert.is_true(ok)
    assert.equals(2, vim.fn.exists ':Review')
    assert.is_true(vim.g.loaded_review_nvim)
  end)

  it(':Review start は登録済みハンドラまで実経路で届く', function()
    dofile(plugin_path())
    local received
    review.cmd_start = function(args)
      received = args
      return { ok = true }
    end

    vim.cmd 'Review start main feature'
    assert.same({ 'start', 'main', 'feature' }, received)
  end)

  it(
    ':Review <未知> は WARN + usage を通知する (コマンド実行の実経路)',
    function()
      dofile(plugin_path())
      vim.cmd 'Review bogus'
      assert.same({
        msg = 'review.nvim: unknown subcommand: bogus. '
          .. 'usage: :Review [start <base> [head] | pr <number|url> | list | '
          .. 'close | delete <id> | prompt [file]]',
        level = vim.log.levels.WARN,
      }, notifications[1])
      assert.equals(1, #notifications)
    end
  )

  it('Tab 補完はサブコマンド 6 種を返す (complete=customlist の結線)', function()
    dofile(plugin_path())
    assert.same(
      { 'start', 'pr', 'list', 'close', 'delete', 'prompt' },
      vim.fn.getcompletion('Review ', 'cmdline')
    )
    assert.same({ 'prompt' }, vim.fn.getcompletion('Review pro', 'cmdline'))
  end)
end)

-- 起動スキャンは plugin (rtp source 時点) の登録。setup 省略インストールでも
-- 永続化通知と worktree 残骸掃除が走る (README「setup() は省略可能」の実体 —
-- UX review F3)。
describe('plugin/review.lua VimEnter 起動スキャン', function()
  local cli = require 'review.git.cli'
  local config = require 'review.config'
  local paths = require 'review.store.paths'
  local store = require 'review.store.session'
  local hook_notifications, hook_dir

  local function write_open_session()
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
  end

  before_each(function()
    config.reset()
    hook_notifications = {}
    vim.notify = function(msg, level)
      table.insert(hook_notifications, { msg = msg, level = level })
    end
    hook_dir = vim.fn.tempname()
    vim.fn.mkdir(hook_dir, 'p')
    paths._set_data_dir(hook_dir)
    store._set_notify(function() end)
    cli._set_system(function(_cmd, _opts, on_exit)
      on_exit { code = 0, stdout = '/hook/repo\n', stderr = '' }
    end)
    cli._set_executable(function()
      return 1
    end)
    write_open_session()
  end)
  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
    paths._set_data_dir(nil)
    store._set_notify(nil)
    vim.fn.delete(hook_dir, 'rf')
    config.reset()
  end)

  it(
    'setup せず plugin を source するだけでも VimEnter で継続通知が走る',
    function()
      dofile(plugin_path())
      vim.api.nvim_exec_autocmds('VimEnter', {
        group = vim.api.nvim_create_augroup('review_nvim', { clear = false }),
        modeline = false,
      })
      assert.same({
        msg = 'review.nvim: main--feature のレビューが続けられます (:Review で復元)',
        level = vim.log.levels.INFO,
      }, hook_notifications[1])
    end
  )

  it(
    'setup で auto_notify_resume=false を後に渡すと通知しない (config 実行時読取)',
    function()
      dofile(plugin_path())
      review.setup { auto_notify_resume = false }
      vim.api.nvim_exec_autocmds('VimEnter', {
        group = vim.api.nvim_create_augroup('review_nvim', { clear = false }),
        modeline = false,
      })
      assert.equals(0, #hook_notifications)
    end
  )

  it('plugin source + setup 双方でも VimEnter ハンドルは重複しない', function()
    dofile(plugin_path())
    review.setup {}
    local ids = vim.api.nvim_get_autocmds {
      group = 'review_nvim',
      event = 'VimEnter',
    }
    assert.equals(1, #ids)
  end)
end)
