-- ui/highlight: DESIGN.md「命名」の highlight グループ定義と config.highlight override。
-- 検証対象は最終的な highlight 定義 (画面の着色そのもの)。下線の有無と link 先が
-- 壊れればコメント行の下線や diff の配色が消える = ユーザーに見える壊れ方。
local config = require 'review.config'
local highlight = require 'review.ui.highlight'

describe('highlight.setup', function()
  after_each(function()
    config.reset()
  end)
  it('既定では DESIGN.md「命名」の全グループが定義される', function()
    highlight.setup()
    assert.equals(true, vim.api.nvim_get_hl(0, { name = 'ReviewCommentLine' }).underline)
    assert.equals('DiffAdd', vim.api.nvim_get_hl(0, { name = 'ReviewDiffAdd', link = true }).link)
    assert.equals(
      'DiffDelete',
      vim.api.nvim_get_hl(0, { name = 'ReviewDiffDelete', link = true }).link
    )
    assert.equals('diffLine', vim.api.nvim_get_hl(0, { name = 'ReviewDiffHunk', link = true }).link)
    assert.equals(
      'Directory',
      vim.api.nvim_get_hl(0, { name = 'ReviewSidebarFile', link = true }).link
    )
    assert.equals(
      'Comment',
      vim.api.nvim_get_hl(0, { name = 'ReviewSidebarStatus', link = true }).link
    )
  end)

  it('config.highlight の override が既定定義に勝つ', function()
    config.setup { highlight = { ReviewCommentLine = { sp = 'red', underline = true } } }
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = 'ReviewCommentLine' })
    assert.equals(true, hl.underline)
    assert.is_true(hl.sp ~= nil and hl.sp ~= 0)
  end)

  it('既定定義は default=true なのでユーザーの明示定義が勝つ', function()
    highlight.setup()
    vim.api.nvim_set_hl(0, 'ReviewDiffAdd', { link = 'Normal', default = false })
    assert.equals('Normal', vim.api.nvim_get_hl(0, { name = 'ReviewDiffAdd', link = true }).link)
    -- 再 setup でもユーザーの明示定義を踏み潰さない (既定の提供であって強制ではない)
    highlight.setup()
    assert.equals('Normal', vim.api.nvim_get_hl(0, { name = 'ReviewDiffAdd', link = true }).link)
  end)
end)
