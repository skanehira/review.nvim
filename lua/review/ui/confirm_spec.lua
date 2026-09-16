-- ui/confirm: [y/N] の単キー確認 float。契約は confirm.lua のコメントと
-- diff-review / DESIGN の UI 節どおりを pin する (vim.ui.input の Enter 必須 +
-- cmdline 残留を避ける F15 対策)。
local confirm = require 'review.ui.confirm'

local state = {}

local function use_isolated_tabpage()
  before_each(function()
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    state.wins = #vim.api.nvim_tabpage_list_wins(state.tab)
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
  end)
end

local function float_wins()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      out[#out + 1] = w
    end
  end
  return out
end

describe('ui/confirm 単キー確認 float', function()
  use_isolated_tabpage()

  it(
    'prompt を float に出し、y で即確定して cb(true)・cmdline は空のまま',
    function()
      local answers = {}
      confirm.open('review.nvim: 開始しますか？ [y/N]: ', function(yes)
        answers[#answers + 1] = yes
      end)
      local fr = float_wins()
      assert.equals(1, #fr)
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(fr[1]), 0, -1, false)
      assert.equals('review.nvim: 開始しますか？', lines[1]) -- 末尾 [y/N]: は落とす
      assert.equals('y = はい / n・Esc = いいえ', lines[#lines])

      vim.cmd 'normal y'
      assert.same({ true }, answers)
      assert.equals(0, #float_wins())
      assert.equals('', vim.fn.getcmdline()) -- cmdline を使わない = 残留しない
    end
  )

  it('n / <Esc> / <CR> は cb(false) (既定 N)', function()
    local answers = {}
    local function run(key)
      confirm.open('確認 [y/N]: ', function(yes)
        answers[#answers + 1] = yes
      end)
      vim.cmd('normal ' .. key)
    end
    run 'n'
    run(vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
    run 'N'
    run(vim.api.nvim_replace_termcodes('<CR>', true, false, true))
    assert.same({ false, false, false, false }, answers)
    assert.equals(0, #float_wins())
  end)

  it('長い prompt は折り返して float 幅に収まる (高さも切らない)', function()
    local long = 'review.nvim: ' .. string.rep('とても長い説明文 ', 20) .. '[y/N]: '
    confirm.open(long, function() end)
    local fr = float_wins()
    assert.equals(1, #fr)
    local cfg = vim.api.nvim_win_get_config(fr[1])
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(fr[1]), 0, -1, false)
    assert.is_true(#lines > 2)
    for _, l in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(l) <= cfg.width, '折返し漏れ: ' .. l)
    end
    assert.is_true(#lines + 2 <= cfg.height)
    vim.cmd 'normal q' -- q はキャンセル扱いで閉じる
    assert.equals(0, #float_wins())
  end)

  it('二重応答しない (1 回目のキーだけで確定)', function()
    local answers = {}
    confirm.open('確認 [y/N]: ', function(yes)
      answers[#answers + 1] = yes
    end)
    vim.cmd 'normal y'
    vim.cmd 'normal j' -- 既に閉じている = 後続キーは通常モードで消費され cb は増えない
    assert.same({ true }, answers)
  end)
end)
