local config = require 'review.config'

-- 期待値は常に default の深コピーから組み立てる (全体比較)。
local function expected_from(f)
  local exp = vim.deepcopy(config.defaults)
  f(exp)
  return exp
end

describe('config.get', function()
  it('setup 無しでも DESIGN.md「API 一覧」の既定値を返す', function()
    config.reset()
    assert.same({
      git_bin = 'git',
      gh_bin = 'gh',
      auto_notify_resume = true,
      keymaps = {
        diff = {
          add_comment = 'c',
          edit_comment = 'e',
          delete_comment = 'd',
          yank_prompt = 'y',
          open_file = 'o',
          close = 'q',
          help = '<F1>',
          next_file = ']d',
          prev_file = '[d',
          focus_sidebar = 'S',
          view_comments = 'i',
        },
        sidebar = {
          open_diff = '<CR>',
          open_file = 'o',
          toggle_viewed = 'x',
          close = 'q',
        },
        sessionlist = {
          open = '<CR>',
          close = 'q',
          delete = 'd',
        },
      },
      highlight = {},
    }, config.get())
  end)

  -- 回帰保護 (characterization test): 他のテストの expected_from は
  -- config.defaults を基準に組み立てるため、setup が defaults を恒久破壊すると
  -- 検証基部ずれで緑化する。リテラル基準でここを固定する。
  it('setup は M.defaults を変更しない (テストの検証基盤の保護)', function()
    config.setup { git_bin = 'x', keymaps = { diff = { close = 'X' } }, highlight = { A = 1 } }
    assert.same({
      git_bin = 'git',
      gh_bin = 'gh',
      auto_notify_resume = true,
      keymaps = {
        diff = {
          add_comment = 'c',
          edit_comment = 'e',
          delete_comment = 'd',
          yank_prompt = 'y',
          open_file = 'o',
          close = 'q',
          help = '<F1>',
          next_file = ']d',
          prev_file = '[d',
          focus_sidebar = 'S',
          view_comments = 'i',
        },
        sidebar = {
          open_diff = '<CR>',
          open_file = 'o',
          toggle_viewed = 'x',
          close = 'q',
        },
        sessionlist = {
          open = '<CR>',
          close = 'q',
          delete = 'd',
        },
      },
      highlight = {},
    }, config.defaults)
    config.reset()
  end)
end)

describe('config.setup', function()
  before_each(function()
    config.reset()
  end)

  it('渡したキーだけ既定値に打ち勝ち、他は既定値が勝つ', function()
    config.setup { git_bin = '/opt/bin/git', auto_notify_resume = false }
    assert.same(
      expected_from(function(exp)
        exp.git_bin = '/opt/bin/git'
        exp.auto_notify_resume = false
      end),
      config.get()
    )
  end)

  it('テーブルは深く合成し、同一階層の既定キーは保持する', function()
    config.setup { keymaps = { diff = { close = 'Q' } } }
    assert.same(
      expected_from(function(exp)
        exp.keymaps.diff.close = 'Q'
      end),
      config.get()
    )
  end)

  it('同じ opts での 2 回目の setup は 1 回目と同一結果 (冪等)', function()
    local opts = { keymaps = { diff = { close = 'Q' }, sidebar = { close = 'X' } } }
    config.setup(opts)
    local first = vim.deepcopy(config.get())
    config.setup(opts)
    assert.same(first, config.get())
  end)
  it(
    'opts 引用を保持せず、setup 後の opts 編集は config に影響しない',
    function()
      local opts = { keymaps = { diff = { close = 'Q' } } }
      config.setup(opts)
      opts.keymaps.diff.close = 'ZZZ'
      opts.git_bin = 'mutated'
      local expected = expected_from(function(exp)
        exp.keymaps.diff.close = 'Q'
      end)
      assert.same(expected, config.get())
    end
  )

  it('空 setup は既定値へ戻す (前回の opts を引き継がない)', function()
    config.setup { git_bin = 'custom-git' }
    config.setup()
    assert.same(config.defaults, config.get())
  end)

  it('highlight をグループ別に override できる', function()
    config.setup { highlight = { ReviewDiffAdd = { link = 'DiffAdd' } } }
    assert.same(
      expected_from(function(exp)
        exp.highlight = { ReviewDiffAdd = { link = 'DiffAdd' } }
      end),
      config.get()
    )
  end)

  it(
    'diff_context は override すると保存され、未指定では nil のまま (git 既定の 3 に従う)',
    function()
      assert.is_nil(config.get().diff_context)
      config.setup { diff_context = 5 }
      assert.equals(5, config.get().diff_context)
      config.setup()
      assert.is_nil(config.get().diff_context)
    end
  )
end)
