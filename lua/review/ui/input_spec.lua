-- ui/input: マルチラインコメント入力 float (diff-review.md「操作」c / e)。
-- 仕様駆動は :normal 経由の実キーシーケンスで行う (keymap 注册の assert だけでは
-- 「確定で callback に body が届く」契約を検証できない)。headless では
-- nvim_input/feedkeys の typeahead が消費されないため :normal が唯一の投入経路
-- (DESIGN.md「既知の制約」)。
local input = require 'review.ui.input'

local CY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)
local CR = vim.api.nvim_replace_termcodes('<CR>', true, true, true)
local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)

-- 各テストを専用 tabpage で走らせ、窓数は自 tabpage 基準で数える
-- (他の spec/テストの窓と干渉しないための独立性)。
local state = {}

-- plenary busted は describe 外のフックを持たない (init_spec.lua と同じ helper 方式)。
local function use_isolated_tabpage()
  before_each(function()
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    state.confirmed = {}
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

-- on_confirm を記録して float を開く (Act の第一歩。以降のキー投入はテスト本体)。
local function open(opts)
  opts = opts or {}
  input.open {
    value = opts.value,
    on_confirm = function(body)
      table.insert(state.confirmed, body)
    end,
  }
end

describe('input.open 確定', function()
  use_isolated_tabpage()
  it(
    'insert 入力して <C-y> で確定すると on_confirm に本文が届き float が閉じる',
    function()
      open()
      local wins_with_float = tab_wins()
      vim.cmd 'normal iuse map here'
      vim.cmd('normal ' .. CY)

      assert.same({ 'use map here' }, state.confirmed)
      assert.equals(wins_with_float - 1, tab_wins())
    end
  )

  it('<CR> で作った複数行は \\n 連結の 1 body になる', function()
    open()
    vim.cmd('normal iline1' .. CR .. 'line2')
    vim.cmd('normal ' .. CY)
    assert.same({ 'line1\nline2' }, state.confirmed)
  end)

  it(
    'value の事前入力が buffer に入り、編集確定では編集後本文が返る',
    function()
      open { value = 'draft body' }
      assert.same({ 'draft body' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      vim.cmd 'normal 0d$'
      vim.cmd 'normal inew body'
      vim.cmd('normal ' .. CY)
      assert.same({ 'new body' }, state.confirmed)
    end
  )

  it('空 body の確定は取り消し扱いで on_confirm は呼ばれない', function()
    open()
    vim.cmd('normal i' .. CY)
    assert.same({}, state.confirmed)
    assert.equals(1, tab_wins())
  end)
end)

describe('input.open キャンセル', function()
  use_isolated_tabpage()
  it('<Esc> では on_confirm を呼ばずに float を閉じる', function()
    open()
    vim.cmd 'normal iunsent'
    vim.cmd('normal ' .. ESC)
    assert.same({}, state.confirmed)
    assert.equals(1, tab_wins())
  end)

  it(
    '<Esc> 以外での離脱 (:q) もキャンセル扱いし、状態を変えない (エッジケース)',
    function()
      open()
      assert.equals(2, tab_wins())
      vim.cmd 'quit'
      assert.same({}, state.confirmed)
      assert.equals(1, tab_wins())
    end
  )
end)

describe('input.open 表示契約', function()
  use_isolated_tabpage()
  it('float は border=rounded で開く (DESIGN.md 横断規約 UI)', function()
    open()
    -- nvim_win_get_config の border は指定文字列でなく枠文字の table で返る。
    -- rounded 枠の代表文字で判定する。
    local cfg = vim.api.nvim_win_get_config(0)
    assert.equals('╭', cfg.border[1])
    assert.is_true(cfg.relative ~= '')
    vim.cmd('normal ' .. ESC)
  end)
end)
