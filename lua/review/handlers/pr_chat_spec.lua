-- handlers/pr_chat: PR 一般コメント (conversation) の開閉・返信・追随。
-- 検証: (1) open が pr-chat 窓を開き session.general を表示、(2) r で local
-- pending の一般コメントが追加され save (INV-4)、(3) branch は WARN、q で閉じる。
local cli = require 'review.git.cli'
local config = require 'review.config'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local pr_chat = require 'review.handlers.pr_chat'
local prchat = require 'review.ui.prchat'
local fixtures = require 'helpers.fixtures'
local git_env = require 'helpers.git_env'
local nvim_env = require 'helpers.nvim_env'
local session_env = require 'helpers.session_env'

local SLUG = 'main--feature'

local HEAD_TEXT = fixtures.HEAD_TEXT_ONE_SIX

local RAW_DIFF = fixtures.RAW_DIFF_ONE_SIX

local state = {}

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {} }
    session_env.make_dirs(state, { ['a.lua'] = HEAD_TEXT })
    session_env.inject_store(state)
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
    git_env.executable_ok()
    state.tab = vim.api.nvim_get_current_tabpage()
    session_env.capture_notify(state)
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
    session_env.close_session()
    session_env.reset_windows()
    nvim_env.close_tab(state.tab)
    nvim_env.wipe_review_buffers()
    session_env.release(state)
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
    assert.same({
      {
        msg = 'review.nvim: PR conversation is only available for PR sessions (:Review pr)',
        level = vim.log.levels.WARN,
      },
    }, state.notifications)
  end)

  it('q で閉じる (セッション状態は変えない)', function()
    pr_chat.open()
    local win = prchat.find_window(state.session.id)
    assert.is_not_nil(win)
    vim.api.nvim_set_current_win(win)
    local wins_before = #vim.api.nvim_tabpage_list_wins(0)
    local session_before = vim.deepcopy(session_handler.active())
    local saved_before = store.load(state.repo, state.session.id).data
    pr_chat.close_current()
    assert.is_nil(prchat.find_window(state.session.id))
    assert.equals(wins_before - 1, #vim.api.nvim_tabpage_list_wins(0))
    -- セッション状態はメモリもディスク (INV-4) も変わらない
    assert.same(session_before, session_handler.active())
    assert.same(saved_before, store.load(state.repo, state.session.id).data)
  end)
end)
