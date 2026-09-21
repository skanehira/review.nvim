-- handlers/sessions_list: :Review list 操作 (open_current は restore_spec 側で
-- flow 検証済みのため、ここでは一覧行 -> handler 接続と d 削除の契約のみ pin する)。
-- 追随 (d 完了後の行減少 / winbar 件数 / 削除済み行の <CR> 二重ガード) は spy を
-- 使わない実 delete 経路で別 describe に pin する (issue #41)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local paths = require 'review.store.paths'
local session_handler = require 'review.handlers.session'
local sessions_list = require 'review.handlers.sessions_list'
local store = require 'review.store.session'
local ui_list = require 'review.ui.list'

local REAL_NOTIFY = vim.notify
local state = {}

local function session_stub(id, overrides)
  local s = {
    version = 1,
    id = id,
    repo = '/spec/repo',
    mode = 'branch',
    base = id:match '^(.-)%-%-' or id,
    head = id:match '%-%-(.*)$' or id,
    pr = vim.NIL,
    worktree = vim.NIL,
    status = 'closed',
    files = {},
    comments = {},
    created_at = 1,
    updated_at = 1,
  }
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

describe('sessions_list.delete_current (一覧 d)', function()
  local list_buf

  before_each(function()
    config.reset()
    state = { notifications = {}, deleted = {} }
    paths._set_data_dir(vim.fn.tempname())
    store._set_notify(function() end)
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    -- delete 本体 ([y/N] -> 掃除) は delete_spec 側で検証済み。spy で接続を pin。
    state.real_delete = session_handler.delete
    session_handler.delete = function(id)
      table.insert(state.deleted, id)
      return { ok = true }
    end
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    list_buf = ui_list.render_sessionlist({
      session_stub 'b--b',
      session_stub 'a--a',
      session_stub('gone--gone', { repo = '/gone' }),
    }, {
      is_grey = function(s)
        return s.repo == '/gone'
      end,
    })
    vim.api.nvim_win_set_buf(0, list_buf)
  end)
  after_each(function()
    session_handler.delete = state.real_delete
    vim.notify = REAL_NOTIFY
    paths._set_data_dir(nil)
    store._set_notify(nil)
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
  end)

  it('d でカーソル行セッションの id を :Review delete 経路へ渡す', function()
    assert.equals('sessionlist', vim.b[list_buf].review_meta.kind)
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- 昇順 2 行目 = b--b

    sessions_list.delete_current()

    assert.same({ 'b--b' }, state.deleted)
  end)

  it('grey 行 (repo path 消失) は WARN で delete を呼ばない', function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- gone--gone (grey)

    sessions_list.delete_current()

    assert.same({}, state.deleted)
    assert.equals(vim.log.levels.WARN, state.notifications[1].level)
  end)

  it('sessionlist 以外のバッファでは無動作', function()
    vim.cmd 'enew'
    sessions_list.delete_current()
    assert.same({}, state.deleted)
    assert.equals(0, #state.notifications)
  end)

  it('一覧窓の keymap に d が貼られ delete_current 経路を指す', function()
    local rhs
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(list_buf, 'n')) do
      if m.lhs == 'd' then
        rhs = m.rhs
      end
    end
    assert.is_not_nil(rhs, 'd がマップされていない')
    assert.is_true(rhs:find('delete_current', 1, true) ~= nil, rhs)
  end)
end)

describe('sessions_list 追随 (実 delete / refresh / 複数窓 winbar)', function()
  local list_buf

  before_each(function()
    config.reset()
    state = { notifications = {}, inputs = {}, git_calls = {}, input_answer = 'y' }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    -- repo path が実在する仮 repo (grey 判定を通す) + 一時 store (実 delete を通す)
    local raw = vim.fs.joinpath(state.dir, 'repo')
    vim.fn.mkdir(raw, 'p')
    state.repo = vim.uv.fs_realpath(raw) or raw
    paths._set_data_dir(state.dir)
    store._set_notify(function() end)
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    vim.ui.input = function(opts, cb)
      table.insert(state.inputs, opts)
      cb(state.input_answer)
    end
    -- with_repo_top / M.open の rev-parse --show-toplevel と、b--b の worktree
    -- 掃除 (status / remove) を応答する。他は想定外 = error (resume が進んだら
    -- この error で落ちる = 二重ガード検証の RED になる)。
    cli._set_system(function(cmd, _opts, on_exit)
      table.insert(state.git_calls, cmd)
      local joined = table.concat(cmd, ' ')
      if cmd[2] == 'rev-parse' and cmd[3] == '--show-toplevel' then
        on_exit { code = 0, stdout = state.repo .. '\n', stderr = '' }
        return
      end
      if cmd[2] == '-C' and cmd[4] == 'status' then
        on_exit { code = 0, stdout = '', stderr = '' }
        return
      end
      if cmd[2] == 'worktree' and cmd[3] == 'remove' then
        on_exit { code = 0, stdout = '', stderr = '' }
        return
      end
      error('git stub: 想定外の追加実行 ' .. joined, 0)
    end)
    cli._set_executable(function()
      return 1
    end)
    -- セッション 2 件をディスクへ保存。b--b は created_by_us の worktree 記録
    -- (実 dir も作る) = 実 delete 経路が status -> remove -> finalize を通る。
    store.save(session_stub('a--a', { repo = state.repo }))
    local wt = paths.worktree_path(state.repo, 'b--b')
    vim.fn.mkdir(wt, 'p')
    store.save(
      session_stub('b--b', { repo = state.repo, worktree = { path = wt, created_by_us = true } })
    )
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    sessions_list.open()
    list_buf = vim.fn.bufnr 'review://sessions'
    assert.is_true(list_buf ~= -1, 'open 後に一覧バッファが無い')
  end)
  after_each(function()
    vim.notify = REAL_NOTIFY
    vim.ui.input = function(_opts, cb)
      cb(nil)
    end
    paths._set_data_dir(nil)
    store._set_notify(nil)
    cli._set_system(nil)
    cli._set_executable(nil)
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
    vim.fn.delete(state.dir, 'rf')
  end)

  it(
    'd で削除が完了したあと一覧のバッファ行が 1 行減り、winbar の件数も減る',
    function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- 昇順 2 行目 = b--b (worktree 記録あり)

      sessions_list.delete_current()

      local lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
      assert.equals(
        1,
        #lines,
        '削除後に一覧が再 render されていない: ' .. vim.inspect(lines)
      )
      assert.is_truthy(lines[1]:find('a--a', 1, true), lines[1])
      assert.equals('review.nvim · 1 session', vim.w[vim.api.nvim_get_current_win()].review_winbar)
      -- 実 delete: メモリでなくディスクの JSON が消えている (INV 判定)
      assert.is_true(vim.uv.fs_stat(paths.session_file(state.repo, 'b--b')) == nil)
    end
  )

  it('d のあと、複数窓で開いた一覧の winbar が全窓で追随する', function()
    vim.cmd 'vsplit' -- 同じ一覧バッファを 2 窓で表示
    local wins = vim.fn.win_findbuf(list_buf)
    assert.equals(2, #wins)
    vim.api.nvim_set_current_win(wins[1])
    vim.api.nvim_win_set_cursor(wins[1], { 2, 0 })

    sessions_list.delete_current()

    local lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
    assert.equals(1, #lines)
    for _, w in ipairs(wins) do
      assert.equals('review.nvim · 1 session', vim.w[w].review_winbar)
    end
  end)

  it(
    '行データがディスクと乖離した行へ <CR> しても削除済み JSON が復活しない',
    function()
      -- d 完了後の旧行 (旧実装の残行状態) と同型の乖離を再現する: b--b の JSON を
      -- handler を通さず消す (一覧は再 render されない = 旧行が残る)。
      store.delete(state.repo, 'b--b')
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      local git_before = #state.git_calls

      sessions_list.open_current()

      -- 開始 (resume) に進まない = git 呼び出しが増えず、JSON も復活しない
      assert.equals(
        git_before,
        #state.git_calls,
        '削除済み行の <CR> で resume 経路が動いた'
      )
      local warned = false
      for _, n in ipairs(state.notifications) do
        if
          n.level == vim.log.levels.WARN
          and n.msg:find('it was already deleted', 1, true) ~= nil
          and n.msg:find('b--b', 1, true) ~= nil
        then
          warned = true
        end
      end
      assert.is_true(
        warned,
        '削除済みの旨 WARN が出ていない: ' .. vim.inspect(state.notifications)
      )
      assert.is_true(vim.uv.fs_stat(paths.session_file(state.repo, 'b--b')) == nil)
    end
  )

  it(
    '既に一覧が開いているときは窓を増やさずその窓へ focus する',
    function()
      local wins_before = #vim.api.nvim_tabpage_list_wins(0)

      sessions_list.open()

      assert.equals(wins_before, #vim.api.nvim_tabpage_list_wins(0))
      assert.equals(list_buf, vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()))
    end
  )
end)
