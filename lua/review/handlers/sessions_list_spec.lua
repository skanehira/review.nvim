-- handlers/sessions_list: :Review list 操作 (open_current は restore_spec 側で
-- flow 検証済みのため、ここでは一覧行 -> handler 接続と d 削除の契約のみ pin する)。
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
