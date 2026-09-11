-- ui/chrome: GitHub 風窓装飾 (winbar グローバル式 + 窓 number)。仕様は chrome.lua
-- のコメントと diff-review / review.txt の既定値どおりを pin する。
local chrome = require 'review.ui.chrome'
local config = require 'review.config'

local PLUGIN_WINBAR = '%{get(b:,"review_winbar","")}'

describe('ui/chrome winbar グローバル式', function()
  local global_before
  before_each(function()
    config.reset()
    global_before = vim.o.winbar
    vim.o.winbar = ''
    vim.cmd 'tabnew'
  end)
  after_each(function()
    vim.cmd 'tabclose!'
    vim.o.winbar = global_before
    config.reset()
  end)

  it(
    '既定 (winbar=true) で review UI 窓を開くとグローバル winbar に自前式が入る',
    function()
      chrome.window(vim.api.nvim_get_current_win())
      assert.equals(PLUGIN_WINBAR, vim.o.winbar)
    end
  )

  it('ユーザーが既に winbar を設定している場合は触らない', function()
    vim.o.winbar = '%f my own'
    chrome.window(vim.api.nvim_get_current_win())
    assert.equals('%f my own', vim.o.winbar)
  end)

  it('config.winbar=false では設定しない', function()
    config.setup { winbar = false }
    chrome.window(vim.api.nvim_get_current_win())
    assert.equals('', vim.o.winbar)
  end)

  it(
    'window の winbar 適用は window-local set をしない (global 漏れの実測教訓)',
    function()
      -- window-local set は初回代入で global を書き換えるため chrome.window は
      -- 使わない設計。b:review_winbar 経由のみが winbar 内容の契約。
      chrome.window(vim.api.nvim_get_current_win())
      assert.equals(PLUGIN_WINBAR, vim.o.winbar)
      local w = vim.api.nvim_get_current_win()
      assert.is_true(
        vim.api.nvim_get_option_value('winbar', { win = w }):find('review_winbar', 1, true) ~= nil
      )
    end
  )
end)

describe('ui/chrome number', function()
  local tab
  before_each(function()
    config.reset()
    tab = vim.api.nvim_get_current_tabpage()
    vim.cmd 'tabnew'
    tab = vim.api.nvim_get_current_tabpage()
    vim.o.number = true
    vim.o.relativenumber = true
  end)
  after_each(function()
    vim.o.number = true
    vim.o.relativenumber = false
    config.reset()
    if vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd 'tabclose!'
    end
  end)

  it(
    '既定 (number=false) はレビュー窓だけ行番号 off (他窓/global は触らない)',
    function()
      local w = vim.api.nvim_get_current_win()
      vim.cmd 'vsplit'
      local other = vim.api.nvim_get_current_win()
      chrome.window(w)
      assert.equals(false, vim.api.nvim_get_option_value('number', { win = w }))
      assert.equals(false, vim.api.nvim_get_option_value('relativenumber', { win = w }))
      -- 対象外窓の値は chrome.window の適用前から不変 = 窓ローカル操作の契約
      assert.equals(true, vim.api.nvim_get_option_value('number', { win = other }))
    end
  )

  it(
    'config.number=true では窓が global 設定を引き継ぐ (chrome は write しない)',
    function()
      config.setup { number = true }
      local w = vim.api.nvim_get_current_win()
      vim.cmd 'set number'
      chrome.window(w)
      assert.equals(true, vim.api.nvim_get_option_value('number', { win = w }))
    end
  )

  it(
    '直前に number=true を明示した窓でも off になる (set! ではなく value& で落とす)',
    function()
      local w = vim.api.nvim_get_current_win()
      vim.cmd 'setl number'
      chrome.window(w)
      assert.equals(false, vim.api.nvim_get_option_value('number', { win = w }))
    end
  )
end)

describe('ui/chrome.bar', function()
  before_each(function()
    config.reset()
  end)
  it('% を含むパスも winbar 式で壊れないよう %% に逃がす', function()
    local buf = vim.api.nvim_create_buf(false, true)
    chrome.bar(buf, 'a%b.lua · +1 -0 · 2 comments')
    assert.equals('a%%b.lua · +1 -0 · 2 comments', vim.b[buf].review_winbar)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
