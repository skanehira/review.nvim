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
  it('help float が開き、既定キーバインドの行が揃う', function()
    help.open()
    assert.equals(2, tab_wins())
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_true(has_line(lines, 'c 作成コメント (visual-line で範囲指定)'))
    assert.is_true(has_line(lines, 'e カーソル行のコメントを編集'))
    assert.is_true(
      has_line(
        lines,
        'd カーソル行のコメントを削除 (arming: 同じ行でもう一度 d)'
      )
    )
    assert.is_true(has_line(lines, ']d 次のファイルへ (端では無動作)'))
    assert.is_true(has_line(lines, '[d 前のファイルへ (端では無動作)'))
    assert.is_true(has_line(lines, 'S sidebar (変更ファイル一覧) へ移動'))
    assert.is_true(has_line(lines, 'i カーソル行のコメントを閲覧 (read-only)'))
    assert.is_true(has_line(lines, 'y カーソル行のコメントのプロンプトを yank'))
    assert.is_true(has_line(lines, 'o その行の実ファイルを開く'))
    assert.is_true(has_line(lines, 'q セッションを閉じる'))
    assert.is_true(has_line(lines, '<F1> このヘルプ'))
    assert.is_true(has_line(lines, '<CR> そのファイルの diff へ移動'))
    assert.is_true(has_line(lines, '/ 一覧を絞り込む (空入力で解除)'))
    assert.is_true(has_line(lines, 'x viewed 切替'))
    -- コメント入力 float の操作 (ui/input.lua の契約と同一文言。確定/閉じるの
    -- discoverability を help 側でも保証する)
    assert.is_true(has_line(lines, '[コメント入力 (c/e で開く)]'))
    assert.is_true(has_line(lines, '<CR> 確定 (Normal)。insert 中の <CR> は改行'))
    assert.is_true(
      has_line(
        lines,
        'q 閉じる。本文なし=キャンセル / 本文ありは閉じず、続けて q で破棄'
      )
    )
    assert.is_true(has_line(lines, '<C-y> 確定 (insert)'))
    assert.is_true(has_line(lines, '<Esc> Normal へ戻るだけ (窓は閉じない)'))
    assert.is_true(
      has_line(lines, 'd 選択セッションを削除 (:Review delete と同じ確認)')
    )
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
    assert.is_true(has_line(lines, 'gc 作成コメント (visual-line で範囲指定)'))
    assert.is_false(has_line(lines, 'c 作成コメント (visual-line で範囲指定)'))
    vim.cmd 'normal q'
  end)
end)
