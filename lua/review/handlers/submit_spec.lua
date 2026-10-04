-- handlers/submit: レビュー submit (pr-comments「submit フロー」)。
-- 検証の中心は (1) pending の push 順 (roots -> replies -> general -> submit)、
-- (2) push 成功で gh_id が記録される、(3) event/body が渡る、(4) 完了で
-- refresh (差分 + gh 再取り込み) が走る、(5) 失敗は WARN で pending 保持。
-- gh api は cli スタブの応答キューで駆動する (git/gh の引数組み立ては gh_spec が pin)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local session_handler = require 'review.handlers.session'
local submit_handler = require 'review.handlers.submit'
local fixtures = require 'helpers.fixtures'
local git_env = require 'helpers.git_env'
local nvim_env = require 'helpers.nvim_env'
local session_env = require 'helpers.session_env'

local HEAD_TEXT = fixtures.HEAD_TEXT_ONE_SIX

local RAW_DIFF = fixtures.RAW_DIFF_ONE_SIX

local state = {}

-- gh api 書き込み (JSON body を --input で渡す POST) の argv。一時ファイル名は stub が
-- '<input>' に置き換えて記録する。
local function post_argv(path)
  return { 'gh', 'api', '--method', 'POST', 'repos/acme/demo/' .. path, '--input', '<input>' }
end

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, gh_calls = {} }
    session_env.make_dirs(state, { ['a.lua'] = HEAD_TEXT })
    session_env.inject_store(state)
    -- git は branch セッション開始に必要な最小応答
    cli._set_system(function(cmd, _opts, on_exit)
      if cmd[1] == 'gh' and cmd[2] == 'api' then
        local line = table.concat(cmd, ' ')
        local payload = nil
        -- argv は --input の一時ファイル名 (実行ごとに変わる) を '<input>' に置き換えた写し
        local argv = vim.deepcopy(cmd)
        for i = 1, #cmd - 1 do
          if cmd[i] == '--input' then
            local fh = io.open(cmd[i + 1], 'r')
            if fh ~= nil then
              payload = vim.json.decode(fh:read '*a')
              fh:close()
            end
            argv[i + 1] = '<input>'
          end
        end
        table.insert(state.gh_calls, { cmd = cmd, argv = argv, payload = payload })
        if line:find('/comments', 1, true) and cmd[3] == '--method' and cmd[4] == 'POST' then
          if line:find('/issues/', 1, true) then
            on_exit { code = 0, stdout = '{"id":300}', stderr = '' }
          else
            on_exit { code = 0, stdout = '{"id":201,"pull_request_review_id":9}', stderr = '' }
          end
        elseif line:find('reviews/9/comments', 1, true) then
          on_exit {
            code = 0,
            stdout = '[{"id":200,"path":"a.lua","line":2,"body":"new note"}]',
            stderr = '',
          }
        elseif line:find('/reviews', 1, true) and cmd[3] == '--method' and cmd[4] == 'POST' then
          on_exit { code = 0, stdout = '{"id":9,"state":"APPROVED"}', stderr = '' }
        else
          on_exit { code = 0, stdout = '[]', stderr = '' }
        end
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
    -- branch セッションを PR セッションに見立てる (submit は mode=pr のみ)
    sess.mode = 'pr'
    sess.pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' }
    sess.general = {}
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

describe('handlers/submit submit_review', function()
  use_env()

  it(
    'root -> reply -> general -> submit の順に push し gh_id を記録して refresh',
    function()
      state.session.comments = {
        {
          id = 'c1',
          file = 'a.lua',
          line = 2,
          end_line = 2,
          body = 'new note',
          origin = 'local',
        },
        {
          id = 'c2',
          file = 'a.lua',
          line = 2,
          end_line = 2,
          body = 'reply to gh',
          origin = 'local',
          in_reply_to = 101,
        },
      }
      state.session.general = { { id = 'g1', origin = 'local', body = 'general reply' } }
      local refreshed = 0
      session_handler.refresh = function()
        refreshed = refreshed + 1
      end
      vim.ui.select = function(_items, _opts, cb)
        cb 'APPROVE'
      end
      vim.ui.input = function(_opts, cb)
        cb 'lgtm'
      end

      submit_handler.submit_review()

      -- 順序: 1) create_review (行 root を comments で 1 レビュー submit)
      --       2) GET /reviews/9/comments (gh_id 対応付け)
      --       3) reply を POST /comments (in_reply_to)
      --       4) general を POST /issues/comments
      local calls = state.gh_calls
      assert.equals(4, #calls)
      assert.same(post_argv 'pulls/7/reviews', calls[1].argv)
      assert.equals('APPROVE', calls[1].payload.event)
      assert.equals('lgtm', calls[1].payload.body)
      assert.same({ { path = 'a.lua', line = 2, body = 'new note' } }, calls[1].payload.comments)
      assert.same(
        { 'gh', 'api', 'repos/acme/demo/pulls/7/reviews/9/comments', '--paginate' },
        calls[2].argv
      )
      assert.same(post_argv 'pulls/7/comments', calls[3].argv)
      assert.equals(101, calls[3].payload.in_reply_to) -- 返信は in_reply_to (数値)
      assert.same(post_argv 'issues/7/comments', calls[4].argv)
      -- gh_id が記録される (root は review comments の対応付け / reply・general は応答)
      assert.equals(200, state.session.comments[1].gh_id)
      assert.equals(201, state.session.comments[2].gh_id)
      assert.equals(300, state.session.general[1].gh_id)
      assert.equals(1, refreshed)
      assert.is_true(
        state.notifications[#state.notifications].msg:find('review submitted', 1, true) ~= nil
      )
    end
  )

  it('mode=pr でないセッションは WARN で何も push しない', function()
    state.session.mode = 'branch'
    local before = #state.gh_calls
    submit_handler.submit_review()
    assert.equals(before, #state.gh_calls)
    assert.is_true(
      state.notifications[1].msg:find('only available for PR sessions', 1, true) ~= nil
    )
  end)

  it(
    'バッチ submit の失敗は WARN して pending を保持し以後へ進まない',
    function()
      state.session.comments = {
        { id = 'c1', file = 'a.lua', line = 2, end_line = 2, body = 'x', origin = 'local' },
      }
      local refreshed = 0
      session_handler.refresh = function()
        refreshed = refreshed + 1
      end
      vim.ui.select = function(_items, _opts, cb)
        cb 'COMMENT'
      end
      vim.ui.input = function(_opts, cb)
        cb ''
      end
      -- バッチ (POST /reviews) を失敗させる
      cli._set_system(function(cmd, _opts, on_exit)
        if cmd[1] == 'gh' and cmd[2] == 'api' then
          table.insert(state.gh_calls, { cmd = cmd })
          if table.concat(cmd, ' '):find('pulls/7/reviews', 1, true) then
            on_exit { code = 1, stdout = '', stderr = 'gh: Validation Failed (HTTP 422)\n' }
            return
          end
        end
        on_exit { code = 0, stdout = '[]', stderr = '' }
      end)

      submit_handler.submit_review()

      assert.is_true(state.notifications[1].msg:find('failed to submit the review', 1, true) ~= nil)
      assert.is_nil(state.session.comments[1].gh_id) -- pending 保持
      assert.equals(0, refreshed)
      -- 以後へ進まない (POST /reviews の 1 回だけ)
      assert.equals(1, #state.gh_calls)
    end
  )

  it('行 root が無い場合は event + body の判定レビューのみ確定する', function()
    state.session.comments = {}
    state.session.general = { { id = 'g1', origin = 'local', body = 'general reply' } }
    local refreshed = 0
    session_handler.refresh = function()
      refreshed = refreshed + 1
    end
    vim.ui.select = function(_items, _opts, cb)
      cb 'COMMENT'
    end
    vim.ui.input = function(_opts, cb)
      cb 'summary only'
    end

    submit_handler.submit_review()

    local calls = state.gh_calls
    assert.equals(2, #calls)
    assert.same(post_argv 'pulls/7/reviews', calls[1].argv)
    assert.same({ event = 'COMMENT', body = 'summary only' }, calls[1].payload)
    assert.same(post_argv 'issues/7/comments', calls[2].argv)
    assert.equals(1, refreshed)
  end)
end)
