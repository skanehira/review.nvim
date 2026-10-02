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
    assert.equals(
      'Normal',
      vim.api.nvim_get_hl(0, { name = 'ReviewCommentBody', link = true }).link
    )
    assert.equals('DiffAdd', vim.api.nvim_get_hl(0, { name = 'ReviewDiffAdd', link = true }).link)
    assert.equals(
      'DiffDelete',
      vim.api.nvim_get_hl(0, { name = 'ReviewDiffDelete', link = true }).link
    )
    assert.equals('diffLine', vim.api.nvim_get_hl(0, { name = 'ReviewDiffHunk', link = true }).link)
    -- 行下スレッドの罫線の箱 (既存 float の border="rounded" と同系の枠色)
    assert.equals(
      'FloatBorder',
      vim.api.nvim_get_hl(0, { name = 'ReviewCommentBorder', link = true }).link
    )
    -- 全文閲覧 float (`i`) の背景は透過 (bg NONE = nvim_get_hl では bg が nil)。
    -- 他グループへ link していないことも確認 (Normal へ link すると背景を継承する)。
    local view = vim.api.nvim_get_hl(0, { name = 'ReviewCommentView' })
    assert.is_nil(view.link, 'ReviewCommentView が他グループへ link してはいけない')
    assert.is_nil(view.bg, 'ReviewCommentView の背景が透過 (NONE) でない')
    assert.equals(
      'DiagnosticWarn',
      vim.api.nvim_get_hl(0, { name = 'ReviewCommentOutdated', link = true }).link
    )
    -- file panel の 4 グループ (DESIGN「命名」。旧 ReviewSidebar* は panel 側へ統合)
    assert.equals('Normal', vim.api.nvim_get_hl(0, { name = 'ReviewPanelFile', link = true }).link)
    assert.equals(
      'Directory',
      vim.api.nvim_get_hl(0, { name = 'ReviewPanelDir', link = true }).link
    )
    assert.equals(
      'Comment',
      vim.api.nvim_get_hl(0, { name = 'ReviewPanelStatus', link = true }).link
    )
    assert.equals(
      'Comment',
      vim.api.nvim_get_hl(0, { name = 'ReviewPanelComment', link = true }).link
    )
    assert.equals('Added', vim.api.nvim_get_hl(0, { name = 'ReviewPanelAdd', link = true }).link)
    assert.equals(
      'Removed',
      vim.api.nvim_get_hl(0, { name = 'ReviewPanelRemove', link = true }).link
    )
    assert.equals('Comment', vim.api.nvim_get_hl(0, { name = 'ReviewPanelMeta', link = true }).link)
    -- 選択行 hl (file panel のカーソル行 = CursorLine link。背景を持つ
    -- ReviewPanelFile を選択行に張ると cursorline 背景が打ち消される)
    assert.equals(
      'CursorLine',
      vim.api.nvim_get_hl(0, { name = 'ReviewPanelSelection', link = true }).link
    )
    -- 現在開いているファイルの basename (diffview FilePanelSelected = Type と同系)
    assert.equals('Type', vim.api.nvim_get_hl(0, { name = 'ReviewPanelActive', link = true }).link)
    assert.is_nil(next(vim.api.nvim_get_hl(0, { name = 'ReviewSidebarFile' })))
  end)

  it(
    'GitHub 風配色の 3 グループが link で定義される (diffview enhanced_diff_hl 方式)',
    function()
      highlight.setup()
      -- base 窓の「この側にしか無い行 = 削除」は削除色、filler は両窓で dim
      assert.equals(
        'DiffDelete',
        vim.api.nvim_get_hl(0, { name = 'ReviewDiffAddAsDelete', link = true }).link
      )
      assert.equals(
        'Comment',
        vim.api.nvim_get_hl(0, { name = 'ReviewDiffDeleteDim', link = true }).link
      )
      assert.equals(
        'DiffChange',
        vim.api.nvim_get_hl(0, { name = 'ReviewDiffChange', link = true }).link
      )
    end
  )

  it(
    '行内 span 色 (ReviewDiffText*) が背景色付きで定義され、override できる',
    function()
      highlight.setup()
      local add = vim.api.nvim_get_hl(0, { name = 'ReviewDiffTextAdd' })
      local del = vim.api.nvim_get_hl(0, { name = 'ReviewDiffTextDelete' })
      assert.is_true(
        add.bg ~= nil,
        'ReviewDiffTextAdd に行内ハイライトの背景色が無い'
      )
      assert.is_true(
        del.bg ~= nil,
        'ReviewDiffTextDelete に行内ハイライトの背景色が無い'
      )
      assert.not_equals(
        add.bg,
        del.bg,
        '追加側と削除側の span 背景が同一 (赤緑の区別が付かない)'
      )
      config.setup { highlight = { ReviewDiffTextAdd = { bg = '#123456' } } }
      highlight.setup()
      assert.equals(0x123456, vim.api.nvim_get_hl(0, { name = 'ReviewDiffTextAdd' }).bg)
    end
  )

  it('config.highlight の file panel group override が既定定義に勝つ', function()
    config.setup { highlight = { ReviewPanelDir = { link = 'Question', bold = true } } }
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = 'ReviewPanelDir', link = true })
    assert.equals('Question', hl.link)
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
