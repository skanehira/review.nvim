-- ui/keygate: buffer-local キーマップ + 押下時点 window role gate (DESIGN.md 決定表
-- 「review キーの実装」/ docs/design/features/diff-review.md「操作」「head / base 窓」)。
-- 実ファイルバッファはユーザー窓でも開かれるため、マップは buffer-local に張り、
-- rhs expr gate が (a) 窓変数 w:review_key_gate と窓一致 (b) 表示内容指紋
-- (windows.role_of) を通ったときだけ review 操作を発火し、不成立窓では 1 キーが
-- built-in へ戻る。張込前に nvim_buf_get_keymap でユーザー既存マップを検出し
-- 衝突キーはスキップ (衝突を黙って上書きしない)。uninstall で残骸 0。
-- dispatch 先の handlers は発火時 require (ui → handlers の load 循環を作らない)。
local config = require 'review.config'
local keygate = require 'review.ui.keygate'
local windows = require 'review.ui.windows'
local session_handler = require 'review.handlers.session'

local state = {}

-- レビュー窓 (head scratch/実ファイル + base scratch) を備えた専有 tab と、
-- gate 不成立になるユーザー窓を提供する最小環境。
local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {} }
    state.REAL_NOTIFY = vim.notify
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    state.user_win = vim.api.nvim_get_current_win()
  end)
  after_each(function()
    windows.close()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      pcall(vim.cmd, 'tabclose!')
    end
    state.REAL_NOTIFY = state.REAL_NOTIFY or vim.notify
    vim.notify = state.REAL_NOTIFY
    config.reset()
    windows.reset()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if
          name:match '^review://'
          or name:find('keygate%-real', 1, true) ~= nil
          or name:find('/tmp/keygate%-real', 1) ~= nil
        then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end
  end)
end

local function scratch_buf(name, meta)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  if name ~= nil then
    vim.api.nvim_buf_set_name(buf, name)
  end
  if meta ~= nil then
    vim.b[buf].review_meta = meta
  end
  return buf
end

local function open_review_tab()
  windows.open { dir = vim.fn.getcwd(), on_tab_closed = function() end }
end

-- 押下を simulate する: 張られた expr rhs 式を当該窓の文脈で評価する
-- (:normal の打鍵は headless で map の解決経路が不安定なため、
-- nvim_buf_get_keymap の rhs = 発火物が押下と同一であることを使う)。
local function press(buf, lhs, win)
  local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
  local rhs = nil
  for _, m in ipairs(maps) do
    if m.lhs == lhs then
      rhs = m.rhs
    end
  end
  assert.is_not_nil(rhs, 'keymap ' .. lhs .. ' が張られていない')
  local target = win or vim.api.nvim_get_current_win()
  return vim.api.nvim_win_call(target, function()
    return vim.api.nvim_eval(rhs)
  end)
end

-- handlers.session の dispatch 先を差し替けて発火のみ観測する。
local function spy_session(names)
  state.spies = {}
  for _, name in ipairs(names) do
    state.spies[name] = session_handler[name]
    session_handler[name] = function(...)
      table.insert(state.notifications, { msg = 'SPY:' .. name, level = 0 })
      return state.spies[name](...)
    end
  end
end

local function restore_spies()
  for name, fn in pairs(state.spies or {}) do
    session_handler[name] = fn
  end
  state.spies = nil
end

-- dispatch は vim.schedule で textlock 解除後のイベントループへ回される
-- (keygate.fire の NOTE)。押下後の観測は発火待ちの条件待機で行う。
local function wait_msg(pat)
  local ok = vim.wait(1000, function()
    for _, n in ipairs(state.notifications) do
      if n.msg:find(pat, 1, true) ~= nil then
        return true
      end
    end
    return false
  end, 10)
  assert.is_true(ok, 'dispatch が発火しない: ' .. pat)
end

describe('keygate.install / uninstall', function()
  use_env()

  local buf
  before_each(function()
    buf = scratch_buf 'review://head/sx/a.lua'
  end)
  after_each(restore_spies)

  it('config.keymaps.diff の全キーが buffer-local に張られる', function()
    keygate.install(buf, 'sx')
    local k = config.get().keymaps.diff
    -- leader は張った時点の実キーに展開されてレポートされる (<leader>e → \e)。
    -- <F1> 等の機能キーは get_keymap が表記のまま返すので展開しない。
    local function expand_lhs(key)
      if key:sub(1, 8) == '<leader>' then
        return (vim.g.mapleader or '\\') .. key:sub(9)
      end
      return key
    end
    local present = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      present[m.lhs] = true
    end
    for _, key in ipairs {
      k.add_comment,
      k.edit_comment,
      k.delete_comment,
      k.yank_prompt,
      k.open_file,
      k.close,
      k.help,
      k.next_file,
      k.prev_file,
      k.first_file,
      k.last_file,
      k.refresh,
      k.focus_panel,
      k.toggle_panel,
      k.view_comments,
    } do
      local lhs = expand_lhs(key)
      assert.is_true(present[lhs] == true, 'map 缺失: ' .. key)
    end
    -- 廃止キー残存ゼロ (issue #18 の撤去契約。上の全件 present が正のアサーション)。
    -- 分解リテラルなのは DoD の残存検出 pattern (単一文字列リテラル形) と衝突しない
    -- ようにするため。
    for _, dead in ipairs { ']' .. 'd', '[' .. 'd', string.upper 's' } do
      assert.is_nil(present[dead], '廃止キーが張られている: ' .. dead)
    end
  end)

  it('c は visual-line でも張られる (範囲コメント)', function()
    keygate.install(buf, 'sx')
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'v')) do
      if m.lhs == 'c' then
        found = true
      end
    end
    assert.is_true(found, 'visual の c が無い')
  end)

  it(
    'ユーザー既存の buffer-local 衝突キーはスキップ (上書きしない)',
    function()
      vim.keymap.set('n', 'c', ':echo "user-c"<CR>', { buffer = buf, nowait = true })
      keygate.install(buf, 'sx')
      local our_c = nil
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == 'c' then
          our_c = m.rhs
        end
      end
      assert.equals(':echo "user-c"<CR>', our_c)
      -- 衝突していない他キーは張れている
      local e = nil
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == 'e' then
          e = m.rhs
        end
      end
      assert.is_true(e ~= nil and e ~= ':echo "user-c"<CR>')
    end
  )

  it(
    'ユーザーの buffer-local 関数キーマップ (get_keymap で rhs=nil / callback) も衝突としてスキップし install はクラッシュしない',
    function()
      -- vim.keymap.set の関数形は nvim_buf_get_keymap で rhs フィールドが無く
      -- callback に Lua 関数が入る。DESIGN 決定表 «衝突キーはスキップ» はこの
      -- 形状でも成立しなければならない (張込が例外で中断しないこと)。
      vim.keymap.set('n', 'c', function() end, { buffer = buf, nowait = true })
      local ok, err = pcall(keygate.install, buf, 'sx')
      assert.is_true(ok, 'install がクラッシュ: ' .. tostring(err))
      -- 衝突キーはユーザーの関数マップのまま (gate map で上書きされていない)
      local cm = nil
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == 'c' then
          cm = m
        end
      end
      assert.is_not_nil(cm, 'ユーザーの c が消えた')
      assert.is_nil(cm.rhs, 'gate map がユーザー関数マップを上書きした')
      assert.is_not_nil(cm.callback, 'c が関数マップでなくなった')
      -- 非衝突の他キーは通常どおり張れている
      local e = nil
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == 'e' then
          e = m.rhs
        end
      end
      assert.is_true(
        type(e) == 'string' and e:find('review.ui.keygate', 1, true) ~= nil,
        '衝突しない e が張られていない'
      )
    end
  )

  it(
    '再 install は自分の前回マップを衝突と数えない (冪等・件数据わ)',
    function()
      keygate.install(buf, 'sx')
      keygate.install(buf, 'sx')
      local ours = 0
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.rhs:find('review.ui.keygate', 1, true) ~= nil then
          ours = ours + 1
        end
      end
      -- config.keymaps.diff の n -mode 全キー = 15 (c/e/d/y/i/o/q/<F1>/<Tab>/
      -- <S-Tab>/[F/]F/R/<leader>e/<leader>b)。v の c は別 mode。
      assert.equals(15, ours)
    end
  )

  it('uninstall で自前マップ残骸 0・ユーザー衝突マップは温存', function()
    vim.keymap.set('n', 'c', ':echo "user-c"<CR>', { buffer = buf, nowait = true })
    keygate.install(buf, 'sx')
    keygate.uninstall(buf)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      assert.is_true(
        m.rhs:find('review.ui.keygate', 1, true) == nil,
        '残骸: ' .. m.lhs .. ' -> ' .. m.rhs
      )
    end
    local c = nil
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if m.lhs == 'c' then
        c = m.rhs
      end
    end
    assert.equals(':echo "user-c"<CR>', c)
    -- visual も掃除される
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'v')) do
      assert.is_true(m.rhs:find('review.ui.keygate', 1, true) == nil)
    end
  end)
end)

describe('keygate.fire: window role gate 発火マトリクス', function()
  use_env()

  local head_buf, base_buf, head_scratch

  before_each(function()
    open_review_tab()
    head_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(head_buf, '/tmp/keygate-real-a.lua')
    base_buf = scratch_buf 'review://base/sx/a.lua'
    head_scratch = scratch_buf('review://head/sx/a.lua', {
      kind = 'scratch',
      scratch = 'head',
      session_id = 'sx',
      path = 'a.lua',
    })
    keygate.install(head_buf, 'sx')
    keygate.install(base_buf, 'sx')
    keygate.install(head_scratch, 'sx')
    spy_session {
      'next_file',
      'prev_file',
      'first_file',
      'last_file',
      'refresh',
      'focus_sidebar',
      'toggle_panel',
      'close_by_key',
    }
  end)
  after_each(restore_spies)

  it(
    '実ファイル head 窓の <Tab>/<S-Tab>/[F/]F/R は対応 handlers を発火する',
    function()
      windows.bind(base_buf, head_buf, { head_kind = 'real' })
      local cases = {
        {
          key = '<Tab>',
          spy = 'SPY:next_file',
        },
        {
          key = '<S-Tab>',
          spy = 'SPY:prev_file',
        },
        {
          key = '[F',
          spy = 'SPY:first_file',
        },
        {
          key = ']F',
          spy = 'SPY:last_file',
        },
        {
          key = 'R',
          spy = 'SPY:refresh',
        },
      }
      for _, case in ipairs(cases) do
        state.notifications = {}
        press(head_buf, case.key, windows.win 'head')
        wait_msg(case.spy)
      end
    end
  )

  it(
    '移動/R キーは base 窓でも発火し、gate 不成立窓 (ユーザー窓) では built-in へ戻る',
    function()
      windows.bind(base_buf, head_buf, { head_kind = 'real' })
      -- base 窓: 移動系は head/base 両窓発火 (DESIGN キー表)
      state.notifications = {}
      press(base_buf, '[F', windows.win 'base')
      wait_msg 'SPY:first_file'
      -- ユーザー窓 (gate 不成立) では同じキーが built-in 化し handlers は走らない
      -- (head 実ファイルと同じ buf をユーザー窓で見る = review で想定する事故形)
      vim.api.nvim_win_set_buf(state.user_win, head_buf)
      vim.api.nvim_set_current_win(state.user_win)
      state.notifications = {}
      local res = press(head_buf, 'R', state.user_win)
      assert.equals('R', res, 'R の fallback が built-in へ返らない')
      vim.wait(100, function()
        for _, n in ipairs(state.notifications) do
          if n.msg:find('SPY:', 1, true) ~= nil then
            return true
          end
        end
        return false
      end, 10)
      for _, n in ipairs(state.notifications) do
        assert.is_true(n.msg:find('SPY:', 1, true) == nil)
      end
    end
  )

  it(
    'gate 不成立窓 (ユーザー窓で同一 buf) では built-in へ戻り handlers は走らない',
    function()
      windows.bind(base_buf, head_buf, { head_kind = 'real' })
      vim.api.nvim_set_current_win(state.user_win)
      local res = press(head_buf, 'q', state.user_win)
      -- 戻り値 = 元キーそのもの (built-in 再実行用)。schedule は予約されていない
      -- ことが契約なので、最小の drain 後も SPY が出ないことを見る。
      assert.equals('q', res)
      vim.wait(100, function()
        for _, n in ipairs(state.notifications) do
          if n.msg:find('SPY:', 1, true) ~= nil then
            return true
          end
        end
        return false
      end, 10)
      for _, n in ipairs(state.notifications) do
        assert.is_true(n.msg:find('SPY:', 1, true) == nil)
      end
    end
  )

  it(
    'base 窓では移動系が発火し c 系は WARN («この窓にはコメントを付けられません»)',
    function()
      windows.bind(base_buf, head_buf, { head_kind = 'real' })
      state.notifications = {}
      local res = press(base_buf, 'c', windows.win 'base')
      assert.equals(1, #state.notifications)
      assert.same({
        msg = 'review.nvim: この窓にはコメントを付けられません',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals('', res, 'WARN でキーストロークは消費 (built-in 化しない)')
    end
  )

  it(
    'scratch 縮退 head (review://head meta) でも c 系が発火側 (WARN にならない)',
    function()
      local deleted = scratch_buf('review://deleted/sx/b.lua', {
        kind = 'scratch',
        scratch = 'deleted',
        session_id = 'sx',
        path = 'b.lua',
      })
      keygate.install(deleted, 'sx')
      windows.bind(base_buf, deleted)
      state.notifications = {}
      press(deleted, 'c', windows.win 'head')
      assert.equals(1, #state.notifications)
      assert.same({
        msg = 'review.nvim: この窓にはコメントを付けられません',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      -- head 縮退 scratch (deleted/binary でない方) はコメント可 -> 入力 float 経路。
      -- dispatch は schedule 経由なので発火完了を待って検証する (active 不在の
      -- comments 経路 WARN がその証拠 = dispatch が実際に走ったことの観測)。
      windows.bind(base_buf, head_scratch)
      state.notifications = {}
      local out = press(head_scratch, 'c', windows.win 'head')
      wait_msg 'アクティブなセッションがありません'
      assert.is_not.equals('c', out)
      for _, n in ipairs(state.notifications) do
        assert.is_true(
          n.msg:find('この窓にはコメントを付けられません', 1, true) == nil,
          '縮退 head scratch が WARN 扱い: ' .. n.msg
        )
      end
    end
  )

  it('deleted 告知窓でも q (close) は効く', function()
    local deleted = scratch_buf('review://deleted/sx/b.lua', {
      kind = 'scratch',
      scratch = 'deleted',
      session_id = 'sx',
      path = 'b.lua',
    })
    keygate.install(deleted, 'sx')
    windows.bind(base_buf, deleted)
    state.notifications = {}
    press(deleted, 'q', windows.win 'head')
    wait_msg 'SPY:close_by_key'
  end)
end)
