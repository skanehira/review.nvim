local review = require 'review'
local result = require 'review.core.result'
local config = require 'review.config'

local USAGE = 'usage: :Review [start <base> [head] | pr <number|url> | list | '
  .. 'close | delete <id> | prompt [file]]'

-- plenary busted は describe 外のフックを持たないため、notify スパイと
-- cmd_* ハンドラの掃除を各 describe 先で registered する helper。
local notifications

local function mock_notify_and_handlers()
  local real_notify
  before_each(function()
    config.reset()
    notifications = {}
    real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = real_notify
    -- テストが injection した cmd_* ハンドラを後続に残さない
    for _, name in ipairs {
      'cmd_start',
      'cmd_pr',
      'cmd_list',
      'cmd_close',
      'cmd_delete',
      'cmd_prompt',
      'cmd_resume',
    } do
      review[name] = nil
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
    '未登録サブコマンドも unknown として扱う (基盤では start 等も未実装)',
    function()
      local res = review.command { 'pr', '42' }

      assert.same({
        msg = 'review.nvim: unknown subcommand: pr. ' .. USAGE,
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

describe('review.setup', function()
  mock_notify_and_handlers()

  it('opts を config 合成して保存する', function()
    review.setup { git_bin = '/usr/bin/git' }
    assert.equals('/usr/bin/git', config.get().git_bin)
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
