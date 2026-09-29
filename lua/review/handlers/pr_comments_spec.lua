-- handlers/pr_comments: PR レビューコメントの GitHub 取り込み・突合。
-- 純ロジック (reconcile_*) は git/gh スタブを介さず session と API 形状の
-- fixture で検証する。fetch の並列調停は gh スタブで 3 系統の完了順を扱う。
local pr_comments = require 'review.handlers.pr_comments'
local config = require 'review.config'
local cli = require 'review.git.cli'

local function gh_comment(overrides)
  local c = {
    id = 10,
    path = 'src/a.lua',
    body = 'use insert',
    line = 12,
    in_reply_to_id = nil,
    user = { login = 'octocat' },
    created_at = '2024-01-02T03:04:05Z',
    subject_type = 'line',
    pull_request_review_id = 1,
  }
  for k, v in pairs(overrides or {}) do
    c[k] = v
  end
  return c
end

local function session_with(comments, overrides)
  local s = {
    id = 'pr-7',
    mode = 'pr',
    base = 'main',
    head = 'topic',
    pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
    comments = comments or {},
    general = {},
  }
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

-- file fixture (core/diff の File 形状。hunks の new_line で行数を決める)
local function diff_file(path, max_new_line)
  return {
    path = path,
    status = 'M',
    binary = false,
    hunks = {
      {
        old_start = 1,
        old_count = max_new_line,
        new_start = 1,
        new_count = max_new_line,
        lines = {
          { kind = 'add', text = 'x', new_line = max_new_line },
        },
      },
    },
  }
end

describe('pr_comments.enabled', function()
  it('mode=pr かつ PR url ありのみ true', function()
    assert.is_true(pr_comments.enabled(session_with {}))
    assert.is_false(pr_comments.enabled(session_with({}, { mode = 'branch' })))
    assert.is_false(pr_comments.enabled(session_with({}, { pr = { number = 7, url = nil } })))
  end)
end)

describe('pr_comments.reconcile_review_comments', function()
  it('新規 gh コメントを採番して追加し active (差分内の行) にする', function()
    local s = session_with {}
    local files = { ['src/a.lua'] = diff_file('src/a.lua', 20) }
    local res = pr_comments.reconcile_review_comments(
      s,
      { gh_comment() },
      { { id = 1, state = 'PENDING' } },
      files
    )
    assert.same({ added = 1, updated = 0, removed = 0 }, res)
    assert.equals(1, #s.comments)
    local c = s.comments[1]
    assert.equals('c1', c.id)
    assert.equals('gh', c.origin)
    assert.equals(10, c.gh_id)
    assert.equals('octocat', c.gh_user)
    assert.equals('pending', c.gh_state)
    assert.equals('active', c.state)
    assert.equals(12, c.line)
  end)

  it('PENDING review に属さないコメントは submitted と判定する', function()
    local s = session_with {}
    pr_comments.reconcile_review_comments(
      s,
      { gh_comment() },
      { { id = 2, state = 'APPROVED' } },
      {}
    )
    assert.equals('submitted', s.comments[1].gh_state)
  end)

  it('同じ gh_id の既存コメントを更新する (重複追加しない)', function()
    local existing = {
      {
        id = 'c1',
        origin = 'gh',
        gh_id = 10,
        body = 'old',
        line = 12,
        end_line = 12,
        state = 'active',
      },
    }
    local s = session_with(existing)
    local res = pr_comments.reconcile_review_comments(
      s,
      { gh_comment { body = 'new text' } },
      {},
      {}
    )
    assert.same({ added = 0, updated = 1, removed = 0 }, res)
    assert.equals(1, #s.comments)
    assert.equals('c1', s.comments[1].id) -- id 保持
    assert.equals('new text', s.comments[1].body)
  end)

  it(
    'local コメントは常に保持する (server 由来の削除に巻き込まれない)',
    function()
      local local_c = {
        id = 'c1',
        origin = nil, -- 旧スキーマ相当 (local)
        file = 'src/a.lua',
        line = 5,
        end_line = 5,
        body = 'my pending',
        state = 'active',
      }
      local s = session_with { local_c }
      pr_comments.reconcile_review_comments(s, {}, {}, {})
      assert.equals(1, #s.comments)
      assert.equals('my pending', s.comments[1].body)
    end
  )

  it('server から消えた gh コメントを削除する', function()
    local s = session_with {
      { id = 'c1', origin = 'gh', gh_id = 10, body = 'gone', line = 1, end_line = 1 },
    }
    local res = pr_comments.reconcile_review_comments(s, { gh_comment { id = 11 } }, {}, {})
    assert.same({ added = 1, updated = 0, removed = 1 }, res)
    assert.equals(1, #s.comments)
    assert.equals(11, s.comments[1].gh_id)
  end)

  it('subject_type=file は file が差分に無ければ outdated', function()
    local s = session_with {}
    pr_comments.reconcile_review_comments(
      s,
      { gh_comment { id = 20, path = 'gone.lua', subject_type = 'file', line = nil } },
      {},
      { ['src/a.lua'] = diff_file('src/a.lua', 20) }
    )
    assert.equals('outdated', s.comments[1].state)
  end)

  it('file が差分にあればファイルレベルは active', function()
    local s = session_with {}
    pr_comments.reconcile_review_comments(
      s,
      { gh_comment { id = 21, path = 'src/a.lua', subject_type = 'file', line = nil } },
      {},
      { ['src/a.lua'] = diff_file('src/a.lua', 20) }
    )
    assert.equals('active', s.comments[1].state)
  end)

  it('行コメントは差分の可視行数を超える行を outdated にする', function()
    local s = session_with {}
    pr_comments.reconcile_review_comments(
      s,
      { gh_comment { id = 22, line = 50 } },
      {},
      { ['src/a.lua'] = diff_file('src/a.lua', 20) }
    )
    assert.equals('outdated', s.comments[1].state)
  end)
end)

describe('pr_comments.reconcile_general', function()
  it('issue comments を採番して追加し、更新・削除を反映する', function()
    local s = session_with {}
    pr_comments.reconcile_general(s, {
      { id = 1, body = 'first', user = { login = 'a' }, created_at = '2024-01-02T03:04:05Z' },
    })
    assert.equals(1, #s.general)
    assert.equals('g1', s.general[1].id)
    assert.equals('gh', s.general[1].origin)
    assert.equals('first', s.general[1].body)

    pr_comments.reconcile_general(s, {
      { id = 1, body = 'updated', user = { login = 'a' }, created_at = '2024-01-02T03:04:05Z' },
      { id = 2, body = 'second', user = { login = 'b' }, created_at = '2024-01-02T03:04:05Z' },
    })
    assert.equals(2, #s.general)
    assert.equals('updated', s.general[1].body)
    assert.equals('g2', s.general[2].id)
  end)
end)

describe('pr_comments.pending_comments / pending_general', function()
  it('origin~=gh かつ gh_id 未付与のみを pending として返す', function()
    local s = session_with {
      { id = 'c1', body = 'p1' },
      { id = 'c2', body = 'pushed', gh_id = 5 },
      { id = 'c3', origin = 'gh', gh_id = 9, body = 'gh' },
    }
    local pending = pr_comments.pending_comments(s)
    assert.equals(1, #pending)
    assert.equals('p1', pending[1].body)
  end)

  it('pending_general は local で gh_id 未付与のみ', function()
    local s = session_with {}
    s.general = {
      { id = 'g1', origin = 'gh', gh_id = 1, body = 'gh' },
      { id = 'g2', body = 'local-pending' },
      { id = 'g3', body = 'local-pushed', gh_id = 2 },
    }
    local pending = pr_comments.pending_general(s)
    assert.equals(1, #pending)
    assert.equals('local-pending', pending[1].body)
  end)
end)

describe('pr_comments.fetch 並列調停 (gh スタブ)', function()
  local state = {}

  before_each(function()
    config.reset()
    cli._set_executable(function()
      return 1
    end)
    state.calls = {}
    cli._set_system(function(cmd, _opts, on_exit)
      table.insert(state.calls, cmd)
      local line = table.concat(cmd, ' ')
      if line:find('pulls/7/comments', 1, true) then
        on_exit {
          code = 0,
          stdout = table.concat {
            '[{"id":1,"path":"a.lua","body":"x","line":1,',
            '"subject_type":"line","user":{"login":"u"},',
            '"pull_request_review_id":null,',
            '"created_at":"2024-01-02T03:04:05Z"}]',
          },
          stderr = '',
        }
      elseif line:find('pulls/7/reviews', 1, true) then
        on_exit { code = 0, stdout = '[]', stderr = '' }
      elseif line:find('issues/7/comments', 1, true) then
        on_exit { code = 0, stdout = '[]', stderr = '' }
      else
        on_exit { code = 1, stdout = '', stderr = 'unexpected' }
      end
    end)
  end)

  after_each(function()
    cli._set_system(nil)
    cli._set_executable(nil)
    config.reset()
  end)

  it('3 系統を取得して突合し cb(false) を返す', function()
    local s = session_with {}
    local called
    pr_comments.fetch(s, { files_by_path = {} }, function(failed)
      called = failed
    end)
    assert.equals(false, called)
    assert.equals(1, #s.comments)
    assert.equals('c1', s.comments[1].id)
    -- 3 系統の呼び出しが走った
    assert.equals(3, #state.calls)
  end)

  it('1 系統の取得失敗は cb(true) を返しつつ成功系統は突合する', function()
    local s = session_with {}
    cli._set_system(function(cmd, _opts, on_exit)
      local line = table.concat(cmd, ' ')
      if line:find('pulls/7/comments', 1, true) then
        on_exit { code = 1, stdout = '', stderr = 'gh: Not Found (HTTP 404)\n' }
      else
        on_exit { code = 0, stdout = '[]', stderr = '' }
      end
    end)
    local called
    pr_comments.fetch(s, { files_by_path = {} }, function(failed)
      called = failed
    end)
    assert.equals(true, called)
    assert.equals(0, #s.comments) -- 取得失敗系統は突合しない
  end)

  it('owner/repo が解けない session は cb(true) で何もしない', function()
    local s = session_with({}, { pr = { number = 7, url = nil } })
    local called
    pr_comments.fetch(s, { files_by_path = {} }, function(failed)
      called = failed
    end)
    assert.equals(true, called)
    assert.equals(0, #s.comments)
  end)
end)
