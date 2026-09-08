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
