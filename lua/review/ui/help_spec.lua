-- ui/help: <F1> help float (diff-review.md「操作」)。キー一覧の表示と
-- <Esc>/q で閉じることを、実キーシーケンス (:normal 駆動) で検証する。
-- 表示行は `<key> <説明>` の 1 行フォーマット (詳細は help.lua)。
local config = require 'review.config'
local help = require 'review.ui.help'

local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)

local state = {}

-- plenary busted は describe 外のフックを持たない (init_spec.lua と同じ helper 方式)。
local function use_isolated_tabpage()
  before_each(function()
    config.reset()
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
  end)
end

local function tab_wins()
  return #vim.api.nvim_tabpage_list_wins(state.tab)
end

local function has_line(lines, expected)
  for _, line in ipairs(lines) do
    if line == expected then
      return true
    end
  end
  return false
end

describe('help.open', function()
  use_isolated_tabpage()
  it('help float が開き、既定キーバインドの行が揃う (markdown)', function()
    help.open()
    assert.equals(2, tab_wins())
    assert.equals('markdown', vim.bo[0].filetype)
    assert.equals(3, vim.wo.conceallevel)
    assert.equals('n', vim.wo.concealcursor)
    assert.is_true(vim.wo.wrap)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_true(has_line(lines, '# review.nvim keymap'))
    assert.is_true(has_line(lines, '## review windows (head / base)'))
    assert.is_true(has_line(lines, '## file panel (changed files)'))
    assert.is_true(
      has_line(lines, '- **c** create a comment (visual-line for range; head window only)')
    )
    assert.is_true(
      has_line(lines, '- **e** edit the comment on the cursor line (head window only)')
    )
    assert.is_true(
      has_line(
        lines,
        '- **d** delete the comment on the cursor line (arming: press d again on the same line)'
      )
    )
    assert.is_true(
      has_line(
        lines,
        '- **D** delete all comments at once (arming: press again; same as :Review clear)'
      )
    )
    assert.is_true(
      has_line(
        lines,
        '- **<Esc>** cancel d / D arming (falls back to built-in <Esc> when not armed)'
      )
    )
    assert.is_true(has_line(lines, '- **y** yank the prompt of the comment on the cursor line'))
    assert.is_true(has_line(lines, '- **<Tab>** next file (no-op at the edges)'))
    assert.is_true(has_line(lines, '- **<S-Tab>** previous file (no-op at the edges)'))
    assert.is_true(has_line(lines, '- **[F** first file'))
    assert.is_true(has_line(lines, '- **]F** last file'))
    assert.is_true(has_line(lines, '- **R** refresh the diff'))
    assert.is_true(has_line(lines, '- **<F1>** this help (also opens with g?)'))
    assert.is_true(has_line(lines, '- **<leader>e** go to the file panel (changed files)'))
    assert.is_true(
      has_line(
        lines,
        '- **<leader>b** toggle the file panel (closing keeps the tab and review windows)'
      )
    )
    assert.is_true(
      has_line(
        lines,
        '- **<leader>c** open the comments list (cross-file) full-width at the bottom '
          .. 'of the review tab (same as :Review comments; focuses the '
          .. 'window if already open)'
      )
    )
    assert.is_true(has_line(lines, '- **i** view the comment on the cursor line (read-only)'))
    assert.is_true(
      has_line(
        lines,
        '- **<CR>** open the file in the head/base windows (cursor '
          .. 'stays in the panel; dir rows toggle fold)'
      )
    )
    assert.is_true(has_line(lines, '- **o** same as <CR> (panel o opens the entry)'))
    assert.is_true(has_line(lines, '- **l** same as <CR> (open the entry)'))
    -- file panel 節の移動系・refresh (review-18-r1 high 対策)。diff 節と同一文だと
    -- has_line 全文一致が節を区別できず、panel 側の 5 行を消しても緑になる
    -- (検出能力ゼロ)。doc/review.txt sidebar 節の文案で文言を一意化している。
    assert.is_true(
      has_line(
        lines,
        '- **<Tab>** next file (panel display order = same handling as '
          .. '<CR>; focus stays in panel; no-op at edges)'
      )
    )
    assert.is_true(has_line(lines, '- **<S-Tab>** previous file (same rule as above)'))
    assert.is_true(has_line(lines, '- **[F** first file (same rule as above)'))
    assert.is_true(has_line(lines, '- **]F** last file (same rule as above)'))
    assert.is_true(has_line(lines, '- **R** refresh the diff (same as R in review windows)'))
    assert.is_true(has_line(lines, '- **i** toggle list view (full path 1 line) / tree view'))
    assert.is_true(has_line(lines, '- **/** filter the list (empty input clears)'))
    assert.is_true(has_line(lines, '- **<F1>** this help (g? also works in the panel)'))
    assert.is_true(has_line(lines, '- **x** toggle review-done mark [✓] (open never sets it)'))
    -- コメント一覧への導線は diff 節と同一文にすると has_line が節を区別できず
    -- (検出能力ゼロ)、文言を一意化している。
    assert.is_true(
      has_line(lines, '- **<leader>c** open the comments list (same as the diff windows)')
    )
    -- gate 不成立窓の 1 keystroke built-in 副作用の help 明記契約 (DESIGN 決定表
    -- 「review キーの実装」)。文案の正本はこの行。
    assert.is_true(
      has_line(
        lines,
        '- **note:** review keys are buffer-local with a window role gate at press time. windows'
          .. ' that fail the gate (e.g. the same real file opened in your own window) fall back 1'
          .. ' keystroke to built-in behavior'
      )
    )
    -- コメント入力 float の操作 (ui/input.lua の契約と同一文言。確定/閉じるの
    -- discoverability を help 側でも保証する)
    assert.is_true(has_line(lines, '## comment input (opened by c/e)'))
    assert.is_true(has_line(lines, '- **<CR>** confirm (Normal). <CR> in insert is a newline'))
    assert.is_true(
      has_line(
        lines,
        '- **q** close. empty body cancels; with body it stays open, press q again to discard'
      )
    )
    assert.is_true(has_line(lines, '- **<C-y>** confirm (insert)'))
    assert.is_true(has_line(lines, '- **<Esc>** return to Normal only (does not close)'))
    assert.is_true(has_line(lines, '## sessions list (:Review list)'))
    assert.is_true(
      has_line(lines, '- **d** delete the selected session (same confirm as :Review delete)')
    )
    assert.is_true(has_line(lines, '## comments list (cross-file)'))
    assert.is_true(has_line(lines, '- **<CR>** jump to the comment on the cursor line'))
    assert.is_true(
      has_line(
        lines,
        '- **d** delete the comment on the cursor line (list-only '
          .. 'arming: press d again on the same line)'
      )
    )
    assert.is_true(
      has_line(
        lines,
        '- **D** delete all comments at once (list-only arming: press again; same as :Review clear)'
      )
    )
    assert.is_true(
      has_line(lines, '- **<Esc>** cancel list d / D arming (no-op when nothing is armed)')
    )
    assert.is_true(has_line(lines, '- **e** edit the comment on the cursor line'))
    assert.is_true(has_line(lines, '- **y** yank the prompt of the comment on the cursor line'))
    assert.is_true(has_line(lines, '- **q** close the list (leaves the session state unchanged)'))
    vim.cmd 'normal q'
  end)

  it('q で閉じる', function()
    help.open()
    vim.cmd 'normal q'
    assert.equals(1, tab_wins())
  end)

  it('<Esc> で閉じる (DoD の <F1> help float 経路)', function()
    help.open()
    vim.cmd('normal ' .. ESC)
    assert.equals(1, tab_wins())
  end)

  it('keymaps override では表示キーが override 後の値に従う', function()
    config.setup { keymaps = { diff = { add_comment = 'gc' } } }
    help.open()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_true(
      has_line(lines, '- **gc** create a comment (visual-line for range; head window only)')
    )
    assert.is_false(has_line(lines, 'c create a comment (visual-line for range; head window only)'))
    vim.cmd 'normal q'
  end)
end)
