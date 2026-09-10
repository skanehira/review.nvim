-- ui/input: マルチラインコメント入力 float (diff-review.md「操作」c / e)。
-- 操作契約: insert の <CR> は改行、Normal の <CR> で確定、q で閉じる
-- (本文ありのときは閉じず、破棄するには 2 秒以内にもう一度 q)、<C-y> は確定の
-- エイリアス、<Esc> は Normal へ戻るだけで窓を閉じない。
-- 仕様駆動は :normal 経由の実キーシーケンスで行う (keymap 登録の assert だけでは
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
    state.notifications = {}
    state.real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    input._set_now(nil)
  end)
  after_each(function()
    vim.notify = state.real_notify
    input._set_now(nil)
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
  end)
end

local function tab_wins()
  return #vim.api.nvim_tabpage_list_wins(state.tab)
end

local function title_text()
  -- 0.10 では文字列、0.13 では { { str }, ... } の table で返る (両対応)。
  local t = vim.api.nvim_win_get_config(0).title
  return type(t) == 'table' and (type(t[1]) == 'table' and t[1][1] or t[1]) or (t or '')
end

-- on_confirm を記録して float を開く (Act の第一歩。以降のキー投入はテスト本体)。
local function open(opts)
  opts = opts or {}
  input.open {
    value = opts.value,
    hint = opts.hint,
    on_confirm = function(body)
      table.insert(state.confirmed, body)
    end,
  }
end

describe('input.open 確定', function()
  use_isolated_tabpage()
  it(
    'insert 入力 -> <Esc> (Normal へ) -> <CR> で確定すると on_confirm に本文が届き float が閉じる (主経路)',
    function()
      open()
      local wins_with_float = tab_wins()
      -- :normal はキー列を続けて解釈するので insert 終了 (<Esc>) と Normal <CR>
      -- 確定は 1 シーケンスで投入する (E2E と同じ契約)。
      vim.cmd('normal ' .. 'iuse a map here' .. ESC .. CR)

      assert.same({ 'use a map here' }, state.confirmed)
      assert.equals(wins_with_float - 1, tab_wins())
    end
  )

  it('insert-mode <C-y> は確定のエイリアスとして維持される', function()
    open()
    vim.cmd 'normal iuse map here'
    vim.cmd('normal ' .. CY)
    assert.same({ 'use map here' }, state.confirmed)
  end)

  -- 確定後に insert が残留すると焦点が戻った diff バッファが insert-mode になり
  -- 誤打鍵で review:// buffer を傷つける (UX review F8)。
  it('<C-y> 確定後は insert モードに残留しない', function()
    open()
    vim.cmd 'normal idraft text'
    vim.cmd('normal ' .. CY)
    assert.is_true(vim.fn.mode() ~= 'i')
  end)

  it(
    'insert の <CR> は改行で、Normal <CR> 確定で \\n 連結の 1 body になる',
    function()
      open()
      vim.cmd('normal ' .. 'iline1' .. CR .. 'line2' .. ESC .. CR)
      assert.same({ 'line1\nline2' }, state.confirmed)
    end
  )

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

describe('input.open 閉じる / 破棄', function()
  use_isolated_tabpage()

  it('<Esc> は窓を閉じない (本文保持のまま Normal へ戻るだけ)', function()
    open()
    vim.cmd('normal ' .. 'iunsent' .. ESC)
    assert.equals(2, tab_wins())
    assert.same({}, state.confirmed)
    -- 閉じないので本文は残り、そこから確定できる
    vim.cmd('normal ' .. CR)
    assert.same({ 'unsent' }, state.confirmed)
  end)

  it('本文なしの q は即閉じる (キャンセル・無通知)', function()
    open()
    assert.is_true(tab_wins() == 2)
    vim.cmd 'normal q'
    assert.equals(1, tab_wins())
    assert.same({}, state.confirmed)
    assert.same({}, state.notifications)
  end)

  it(
    '本文ありの q は閉じず WARN、2 秒以内にもう一度 q で入力を破棄して閉じる (on_confirm なし)',
    function()
      open()
      vim.cmd('normal ' .. 'idraft' .. ESC)
      state.now = 1000.0
      input._set_now(function()
        return state.now
      end)

      vim.cmd 'normal q'
      assert.equals(2, tab_wins())
      assert.same({}, state.confirmed)
      assert.equals(1, #state.notifications)
      assert.is_true(state.notifications[1].msg:find('確定', 1, true) ~= nil)
      assert.is_true(state.notifications[1].level == vim.log.levels.WARN)

      state.now = state.now + 1.5
      vim.cmd 'normal q'
      assert.equals(1, tab_wins())
      assert.same({}, state.confirmed)
    end
  )

  it(
    'q の arming は本文編集で解除される (arming -> 編集 -> q は WARN が積み直すだけで閉じない)',
    function()
      open()
      vim.cmd('normal ' .. 'idraft' .. ESC)
      state.now = 1000.0
      input._set_now(function()
        return state.now
      end)

      vim.cmd 'normal q'
      assert.equals(1, #state.notifications)
      -- 本文を変えて (q 押下時点の本文比較 = disarm 相当) discard window 内に
      -- q しても「2 度押し」にならず WARN が積み直されるだけで閉じないこと。
      -- 比較方式でなければ +1.5s は window 内なのでここで閉じて (= win 1)
      -- このテストが落ちる = 編集による arming 解除のリトマス。
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'draft edited' })
      state.now = state.now + 1.5
      assert.equals(2, tab_wins())
      vim.cmd 'normal q'
      assert.equals(2, tab_wins())
      assert.same({}, state.confirmed)
      assert.equals(2, #state.notifications)
    end
  )

  it('discard window 超後の q は再び WARN (閉じない)', function()
    open()
    vim.cmd('normal ' .. 'idraft' .. ESC)
    state.now = 1000.0
    input._set_now(function()
      return state.now
    end)

    vim.cmd 'normal q'
    state.now = state.now + 3.0
    vim.cmd 'normal q'
    assert.equals(2, tab_wins())
    assert.same({}, state.confirmed)
    assert.equals(2, #state.notifications)
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
    local wins_here = tab_wins()
    -- nvim_win_get_config の border は指定文字列でなく枠文字の table で返る。
    -- rounded 枠の代表文字で判定する。
    local cfg = vim.api.nvim_win_get_config(0)
    assert.equals('╭', cfg.border[1])
    assert.is_true(cfg.relative ~= '')
    vim.cmd('normal ' .. ESC)
    assert.equals(wins_here, tab_wins())
  end)

  it('窓 title に確定/閉じる的操作ヒントが表示される', function()
    open()
    local text = title_text()
    assert.is_true(text:find('<CR> 確定', 1, true) ~= nil)
    assert.is_true(text:find('q 閉じる', 1, true) ~= nil)
  end)

  it('opts.hint (対象行の示唆) が title に載る', function()
    open { hint = 'a.lua:4-5' }
    assert.is_true(title_text():find('a.lua:4-5', 1, true) ~= nil)
  end)
end)
