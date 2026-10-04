-- ui/list: :Review list セッション一覧の描画 (persistence-restore.md「:Review
-- list」。file panel は ui/filepanel / ui/treelist が持つ)。行フォーマットと
-- row->データ 引き渡し、repo 消失の grey 表示を検証する。
local list = require 'review.ui.list'
local chrome = require 'review.ui.chrome'
local windows = require 'review.ui.windows'
local nvim_env = require 'helpers.nvim_env'
local fixtures = require 'helpers.fixtures'

local function session_stub(overrides)
  return fixtures.session_stub(vim.tbl_extend('force', {
    updated_at = 1725843600, -- 2024-09-09 09:00:00 (UTC+9 で表示される…は環境 TZ 依存)
  }, overrides or {}))
end

local state = {}

local function use_env()
  before_each(function()
    nvim_env.isolate_tab(state)
    state.win = vim.api.nvim_get_current_win()
  end)
  after_each(function()
    nvim_env.close_tab(state.tab)
  end)
end

describe('list.render_sessionlist', function()
  use_env()

  it('セッション一覧 buf に winbar 文字列 (N sessions) が入る', function()
    local buf = list.render_sessionlist {
      session_stub { id = 'a--b', base = 'a', head = 'b', updated_at = 1 },
      session_stub { id = 'c--d', base = 'c', head = 'd', updated_at = 1 },
    }
    assert.equals('review.nvim · 2 sessions', list.sessionlist_winbar { 1, 2 })
    assert.is_nil(vim.b[buf].review_winbar)
  end)

  it(
    'slug / status / mode / base..head / コメント数 / 更新時刻の行を slug 昇順で並べる',
    function()
      local sessions = {
        session_stub {
          id = 'z--y',
          base = 'z',
          head = 'y',
          comments = { {}, {} },
          updated_at = 1725843600,
        },
        session_stub { id = 'a--b', base = 'a', head = 'b', updated_at = 1 },
      }
      local buf = list.render_sessionlist(sessions)
      -- 更新時刻はローカル時刻 + tz 表記 (UX review F17: tz 表記なしの UTC が誤読を
      -- 招いた)。TZ の絶対値は実行環境依存なので、期待値も同じ os.date (%Z 込み) で
      -- 組んで行全体を一致させる (TZ に依らず、tz 表記を外す変異でも落ちる)。
      assert.same({
        'a--b  open  branch  a..b  0 comments  ' .. os.date('%Y-%m-%d %H:%M %Z', 1),
        'z--y  open  branch  z..y  2 comments  ' .. os.date('%Y-%m-%d %H:%M %Z', 1725843600),
      }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.equals('review-list', vim.bo[buf].filetype)
    end
  )

  it(
    'repo 消失セッションは grey hl  extmark が付き open 対象から外れる',
    function()
      local dead = session_stub { id = 'd--d', repo = '/gone' }
      local alive = session_stub { id = 'a--b', repo = vim.fn.getcwd() }
      local buf = list.render_sessionlist({ dead, alive }, {
        is_grey = function(sess)
          return sess.repo == '/gone'
        end,
      })
      local ns = vim.api.nvim_get_namespaces()['review_list_grey']
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      assert.equals(1, #marks)
      assert.equals(1, marks[1][2]) -- slug 昇順 2 行目 (d--d) が grey
      assert.equals('ReviewPanelMeta', marks[1][4].hl_group)
      -- row_session は grey 行では nil (= <Enter> 不可)。生存行は session を返す。
      assert.equals('a--b', (list.row_session(buf, 1) or {}).id)
      assert.is_nil(list.row_session(buf, 2))
    end
  )

  it('sessionlist キー (<CR>/q) が付く', function()
    local buf = list.render_sessionlist {}
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      lhs[m.lhs] = true
    end
    assert.is_true(lhs['<CR>'])
    assert.is_true(lhs['q'])
  end)

  -- rhs は発火時に解決される文字列 (ui -> handlers の module-load 循環回避)。
  -- 張付 existence だけでなく実 require 解決を検査し、未実装関数の dangling rhs を
  -- 検出する (file panel 側は ui/filepanel_spec が同一強度の検査を持つ)。
  it('sessionlist の全 keymap rhs は実関数として解決できる', function()
    local buf = list.render_sessionlist {}
    for _, key in ipairs { '<CR>', 'q' } do
      local rhs
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == key then
          rhs = m.rhs
        end
      end
      assert.is_not_nil(rhs, 'missing mapping: ' .. key)
      local mod_path, func_name = rhs:match "require%('([^']+)'%)%.([%w_]+)%("
      assert.is_not_nil(
        mod_path,
        ('rhs が require 呼び出し形でない: %s -> %s'):format(key, tostring(rhs))
      )
      local ok_mod, mod = pcall(require, mod_path)
      assert.is_true(ok_mod, 'rhs の require が解決できない: ' .. mod_path)
      assert.equals(
        'function',
        type(mod[func_name]),
        ('%s.%s が関数として解決できない (key=%s)'):format(mod_path, func_name, key)
      )
    end
  end)
end)

-- `:Review list` は review tab 外 (current tab の vsplit) に開くため、一覧窓の閉鎖は
-- tab 消滅経路 (windows.close / TabClosed) に乗らない。バッファが閉じた時点で
-- review セッションが無ければ global winbar 式と窓変数を戻す (diff-review
-- 「窓装飾 (chrome)」)。セッション開中でも現在の tab に w:review_winbar の窓が
-- 無ければ式を戻す (式が空評価でも 1 行確保されるため。review tab へ戻ると
-- TabEnter が再適用する)。
describe('sessionlist の winbar 後片付け', function()
  local PLUGIN_WINBAR = '%{get(w:,"review_winbar","")}'
  local env = {}

  before_each(function()
    env.global = vim.api.nvim_get_option_value('winbar', { scope = 'global' })
    vim.api.nvim_set_option_value('winbar', '', { scope = 'global' })
    vim.cmd 'tabnew'
    env.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if windows.state() ~= nil then
      windows.close()
    end
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if vim.api.nvim_tabpage_is_valid(tab) and tab ~= env.tab then
        vim.api.nvim_set_current_tabpage(tab)
        pcall(vim.cmd, 'tabclose!')
      end
    end
    if vim.api.nvim_tabpage_is_valid(env.tab) then
      vim.api.nvim_set_current_tabpage(env.tab)
      pcall(vim.cmd, 'tabclose!')
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.api.nvim_set_option_value('winbar', env.global, { scope = 'global' })
    windows.reset()
  end)

  it(
    'review セッションが無いとき、一覧窓を閉じると global 式を空へ戻す',
    function()
      vim.cmd 'vsplit'
      local w = vim.api.nvim_get_current_win()
      chrome.window(w)
      assert.equals(PLUGIN_WINBAR, vim.api.nvim_get_option_value('winbar', { scope = 'global' }))
      local buf = list.render_sessionlist { session_stub {} }
      vim.api.nvim_win_set_buf(w, buf)
      chrome.winbar(w, list.sessionlist_winbar { session_stub {} })

      vim.api.nvim_win_close(w, true)

      assert.equals('', vim.api.nvim_get_option_value('winbar', { scope = 'global' }))
    end
  )

  it(
    'review セッションが開中でも現在 tab にバーの窓が無ければ一覧窓の閉鎖で式を戻す',
    function()
      -- review tab 外 (ユーザー tab) の一覧窓が閉じたあと、現在 tab (review tab) に
      -- w:review_winbar の窓が無ければ式は不要 (戻ったとき TabEnter が再適用する)。
      vim.cmd 'vsplit'
      local w = vim.api.nvim_get_current_win()
      chrome.window(w)
      windows.open {}
      assert.is_not_nil(windows.state())
      local buf = list.render_sessionlist { session_stub {} }
      vim.api.nvim_win_set_buf(w, buf)
      chrome.winbar(w, list.sessionlist_winbar { session_stub {} })

      vim.api.nvim_win_close(w, true)

      assert.equals('', vim.api.nvim_get_option_value('winbar', { scope = 'global' }))
    end
  )

  it(
    'review セッション開中で現在 tab にバーの窓があれば一覧窓を閉じても式を維持する',
    function()
      vim.cmd 'vsplit'
      local w = vim.api.nvim_get_current_win()
      chrome.window(w)
      windows.open {}
      assert.is_not_nil(windows.state())
      -- review tab 側の chrome 適用済み状態 (現在 tab にバーの窓がある)
      chrome.winbar(windows.win 'head', 'main..feature · a.lua')
      local buf = list.render_sessionlist { session_stub {} }
      vim.api.nvim_win_set_buf(w, buf)
      chrome.winbar(w, list.sessionlist_winbar { session_stub {} })

      vim.api.nvim_win_close(w, true)

      assert.equals(PLUGIN_WINBAR, vim.api.nvim_get_option_value('winbar', { scope = 'global' }))
    end
  )

  it(
    '一覧 buffer を :buffer で差し替えると窓の review_winbar を残さない',
    function()
      local w = vim.api.nvim_get_current_win()
      local buf = list.render_sessionlist { session_stub {} }
      vim.api.nvim_win_set_buf(w, buf)
      chrome.winbar(w, list.sessionlist_winbar { session_stub {} })
      assert.equals('review.nvim · 1 session', vim.w[w].review_winbar)

      vim.cmd 'enew'

      assert.is_nil(vim.w[w].review_winbar)
    end
  )
end)
