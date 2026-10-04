-- handlers/pr_chat: PR 一般コメント (conversation) の開閉・返信・追随。
-- 検証: (1) open が pr-chat 窓を開き session.general を表示、(2) r で local
-- pending の一般コメントが追加され save (INV-4)、(3) branch は WARN、q で閉じる。
local cli = require 'review.git.cli'
local config = require 'review.config'
local paths = require 'review.store.paths'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local pr_chat = require 'review.handlers.pr_chat'
local prchat = require 'review.ui.prchat'
local ui_windows = require 'review.ui.windows'

local SLUG = 'main--feature'

local HEAD_TEXT = table.concat({ 'one', 'two', 'three', 'four', 'six' }, '\n') .. '\n'

local RAW_DIFF = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1,3 +1,5 @@',
  ' one',
  '+two',
  '+three',
  ' four',
  '-five',
  ' six',
  '',
}, '\n')

local REAL_INPUT = vim.ui.input
local REAL_NOTIFY = vim.notify

local state = {}

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {} }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    state.repo = vim.fs.joinpath(state.dir, 'repo')
    vim.fn.mkdir(state.repo, 'p')
    state.repo = vim.uv.fs_realpath(state.repo) or state.repo
    local f = io.open(vim.fs.joinpath(state.repo, 'a.lua'), 'w')
    f:write(HEAD_TEXT)
    f:close()
    paths._set_data_dir(state.dir)
    store._set_now(function()
      return 4321
    end)
    store._set_notify(function() end)
    session_handler._set_now(function()
      return 4321
    end)
    session_handler._reset()
    cli._set_system(function(cmd, _opts, on_exit)
      if cmd[1] == 'gh' and cmd[2] == 'api' then
        on_exit { code = 0, stdout = '[]', stderr = '' }
        return
      end
      if cmd[2] == 'rev-parse' then
        on_exit { code = 0, stdout = state.repo .. '\n', stderr = '' }
      elseif cmd[2] == 'show' then
        on_exit { code = 0, stdout = 'one\nfive deleted\nsix\n', stderr = '' }
      else
        on_exit { code = 0, stdout = RAW_DIFF, stderr = '' }
      end
    end)
    cli._set_executable(function()
      return 1
    end)
    state.tab = vim.api.nvim_get_current_tabpage()
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    session_handler.start { base = 'main', head = 'feature' }
    local sess = session_handler.active()
    sess.mode = 'pr'
    sess.pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' }
    sess.general = {
      {
        id = 'g1',
        origin = 'gh',
        gh_id = 5,
        gh_user = 'octocat',
        body = 'overall lgtm',
        created_at = 1,
      },
    }
    state.session = sess
  end)
  after_each(function()
    vim.ui.input = function(_, cb)
      cb 'y'
    end
    session_handler.close()
    vim.ui.input = REAL_INPUT
    if ui_windows.state() ~= nil then
      ui_windows.close()
    end
    ui_windows.reset()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      pcall(vim.cmd, 'tabclose!')
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.notify = REAL_NOTIFY
    paths._set_data_dir(nil)
    store._set_now(nil)
    store._set_notify(nil)
    session_handler._set_now(nil)
    session_handler._reset()
    config.reset()
    cli._set_system(nil)
    cli._set_executable(nil)
    vim.fn.delete(state.dir, 'rf')
  end)
end

describe('handlers/pr_chat open / reply / refresh', function()
  use_env()

  it(
    'open は pr-chat 窓を開き、一般コメントを [作者] 付きで表示する',
    function()
      pr_chat.open()
      local win = prchat.find_window(state.session.id)
      assert.is_not_nil(win)
      local buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local joined = table.concat(lines, '\n')
      assert.is_true(joined:find('[octocat] overall lgtm', 1, true) ~= nil, joined)
      -- winbar に件数
      assert.is_true((vim.w[win].review_winbar or ''):find('PR #7', 1, true) ~= nil)
    end
  )

  it('r は local pending の一般コメントを追加し save する (INV-4)', function()
    pr_chat.open()
    local win = prchat.find_window(state.session.id)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    pr_chat.reply_current()
    vim.cmd(
      'normal ialso update README' .. vim.api.nvim_replace_termcodes('<C-y>', true, false, true)
    )

    local saved = store.load(state.repo, SLUG).data
    assert.equals(2, #saved.general)
    local g = saved.general[2]
    assert.equals('local', g.origin)
    assert.equals('also update README', g.body)
    assert.is_nil(g.gh_id)
  end)

  it('branch モードは WARN で開かない', function()
    state.session.mode = 'branch'
    pr_chat.open()
    assert.is_true(
      state.notifications[1].msg:find('only available for PR sessions', 1, true) ~= nil
    )
  end)

  it('q で閉じる (セッション状態は変えない)', function()
    pr_chat.open()
    local win = prchat.find_window(state.session.id)
    assert.is_not_nil(win)
    vim.api.nvim_set_current_win(win)
    pr_chat.close_current()
    assert.is_nil(prchat.find_window(state.session.id))
  end)
end)
