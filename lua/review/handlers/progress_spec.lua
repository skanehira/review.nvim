-- handlers/progress: 開始フローの段階別過渡メッセージ (pr-worktree.md
-- 「段階別の過渡 notify」)。並行する段階は開始順に併記し、全段階が終わったら
-- メッセージエリアをクリアする。
local progress = require 'review.handlers.progress'

local REAL_NOTIFY = vim.notify
local REAL_ECHO = vim.api.nvim_echo

describe('progress', function()
  local shown

  before_each(function()
    progress._reset()
    shown = {}
    progress._set_sink(function(text)
      -- nil (クリア) も順序の一部なので sentinel で記録する
      table.insert(shown, text == nil and '<clear>' or text)
    end)
  end)

  after_each(function()
    progress._set_sink(nil)
    progress._reset()
    vim.notify = REAL_NOTIFY
    vim.api.nvim_echo = REAL_ECHO
  end)

  it('並行する段階を開始順に併記し、全段階の終了でクリアする', function()
    local a = progress.start 'resolving PR #7'
    local b = progress.start 'fetching origin/main'
    progress.stop(a)
    progress.stop(b)

    assert.same({
      'review.nvim: resolving PR #7...',
      'review.nvim: resolving PR #7, fetching origin/main...',
      'review.nvim: fetching origin/main...',
      '<clear>',
    }, shown)
  end)

  it('終了済みの handle を再度 stop しても表示を変えない', function()
    local a = progress.start 'loading the diff'
    progress.stop(a)
    progress.stop(a)

    assert.same({ 'review.nvim: loading the diff...', '<clear>' }, shown)
  end)

  it(
    '既定の出力先は INFO の vim.notify で表示し、空 echo でクリアする',
    function()
      progress._set_sink(nil)
      local notified, echoed = {}, {}
      vim.notify = function(msg, level)
        table.insert(notified, { msg = msg, level = level })
      end
      vim.api.nvim_echo = function(chunks, history, opts)
        table.insert(echoed, { chunks, history, opts })
      end

      local a = progress.start 'creating the review worktree'
      progress.stop(a)

      assert.same(
        { { msg = 'review.nvim: creating the review worktree...', level = vim.log.levels.INFO } },
        notified
      )
      assert.same({ { {}, false, {} } }, echoed)
    end
  )
end)
