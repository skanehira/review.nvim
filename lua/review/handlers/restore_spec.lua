-- handlers/restore: 復元手順 (diff 再取得 + anchor 検証) と起動時 scan notify、
-- :Review list / <Enter> (sessions_list) のフロー (persistence-restore.md 全節)。
-- anchor 検証は純粋ロジックとして合成 diff で (a)(b)(c)/±20 境界を検証し、
-- resume / scan は git 注入スタブ + 注入 tmpdir の実ファイルで検証する。
local anchor = require 'review.core.anchor'
local cli = require 'review.git.cli'
local config = require 'review.config'
local paths = require 'review.store.paths'
local restore = require 'review.handlers.restore'
local session_handler = require 'review.handlers.session'
local sessions_list = require 'review.handlers.sessions_list'
local store = require 'review.store.session'

-- repo path の実在チェック (sessions_list の grey 判定) があるため、
-- 偽パスでなく mktemp の実ディレクトリを repo として使う。
local REPO_TOP = vim.fn.tempname()
vim.fn.mkdir(REPO_TOP, 'p')
local RAW_1HUNK = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1..2 100644',
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

local REAL_NOTIFY = vim.notify
local REAL_INPUT = vim.ui.input
local REAL_SELECT = vim.ui.select

local state = {}

-- core/diff 経由で files_by_path を作る (verify の入力を実パーサ産に固定)
local function parsed(text)
  local core_diff = require 'review.core.diff'
  local by_path = {}
  for _, f in ipairs(core_diff.parse(text)) do
    by_path[f.path] = f
  end
  return by_path
end

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, inputs = {}, input_answer = 'y', select_answer = 1 }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    paths._set_data_dir(state.dir)
    store._set_now(function()
      return 4321
    end)
    store._set_notify(function() end)
    session_handler._set_now(function()
      return 4321
    end)
    session_handler._reset()
    vim.notify = function(msg, level)
      table.insert(state.notifications, { msg = msg, level = level })
    end
    vim.ui.input = function(opts, cb)
      table.insert(state.inputs, opts)
      cb(state.input_answer)
    end
    vim.ui.select = function(items, _opts, on_choice)
      on_choice(items[state.select_answer])
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    state.git_stdout = RAW_1HUNK
    cli._set_system(function(cmd, _opts, on_exit)
      if cmd[2] == 'rev-parse' then
        on_exit { code = 0, stdout = REPO_TOP .. '\n', stderr = '' }
      elseif cmd[1] == 'git' and cmd[2] == 'diff' then
        on_exit {
          code = state.git_code or 0,
          stdout = state.git_stdout,
          stderr = state.git_stderr or '',
        }
      else
        on_exit { code = 0, stdout = '' }
      end
    end)
    cli._set_executable(function()
      return 1
    end)
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.notify = REAL_NOTIFY
    vim.ui.input = REAL_INPUT
    vim.ui.select = REAL_SELECT
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

local function saved_comment(overrides)
  local c = {
    id = 'c1',
    file = 'a.lua',
    line = 2,
    end_line = 2,
    body = 'note',
    anchor = { before = 'one', line = 'two', after = 'three' },
    state = 'active',
    created_at = 100,
  }
  for k, v in pairs(overrides or {}) do
    c[k] = v
  end
  return c
end

describe('core.anchor 検証 (合成差分)', function()
  local files = parsed(RAW_1HUNK)

  it('(a) 保存行のテキスト一致 -> active のまま行番号不変', function()
    local comments = { saved_comment() }
    anchor.verify(comments, files)
    assert.same(saved_comment(), comments[1])
  end)

  it('(b) ±20 以内の一致 -> active + 行数補正 (end_line も同量)', function()
    -- 保存 line=22..23 に対して 'two' は新側 line 2 = -20 補正
    local comments = { saved_comment { line = 22, end_line = 23 } }
    anchor.verify(comments, files)
    assert.same({ line = 2, end_line = 3, state = 'active' }, {
      line = comments[1].line,
      end_line = comments[1].end_line,
      state = comments[1].state,
    })
  end)

  it('(b) 境界: ちょうど 20 なら補正 / 21 なら outdated', function()
    local ok20 = { saved_comment { line = 22, end_line = 22 } }
    -- line を +20 ずらす = 保存行 22 の anchor(line) テキスト 'two' は新側行 2
    anchor.verify(ok20, files)
    assert.same({ line = 2, state = 'active' }, { line = ok20[1].line, state = ok20[1].state })

    local out21 = { saved_comment { line = 23, end_line = 23 } }
    anchor.verify(out21, files)
    assert.same({ line = 23, state = 'outdated' }, {
      line = out21[1].line,
      state = out21[1].state,
    })
  end)

  it('(c) 見つからない -> outdated (line/end_line は保存値のまま)', function()
    local comments = {
      saved_comment {
        line = 2,
        anchor = { before = vim.NIL, line = 'gone text', after = vim.NIL },
      },
    }
    anchor.verify(comments, files)
    assert.same({ line = 2, end_line = 2, state = 'outdated' }, {
      line = comments[1].line,
      end_line = comments[1].end_line,
      state = comments[1].state,
    })
  end)

  it('anchor 欠損 (vim.NIL) は検証不能として active のまま', function()
    local comments = { saved_comment { anchor = vim.NIL, line = 42 } }
    anchor.verify(comments, files)
    assert.equals('active', comments[1].state)
    assert.equals(42, comments[1].line)
  end)

  it('ファイル消失は outdated (file が new 差分に無い)', function()
    local comments = { saved_comment { file = 'other.lua' } }
    anchor.verify(comments, files)
    assert.equals('outdated', comments[1].state)
  end)
end)

describe('restore.resume (セッション再開)', function()
  use_env()

  local function save_session(overrides)
    local sess = {
      version = 1,
      id = 'main--feature',
      repo = REPO_TOP,
      mode = 'branch',
      base = 'main',
      head = 'feature',
      pr = vim.NIL,
      worktree = vim.NIL,
      status = 'closed',
      files = { ['a.lua'] = { viewed = true } },
      comments = {},
      created_at = 1,
      updated_at = 1,
    }
    for k, v in pairs(overrides or {}) do
      sess[k] = v
    end
    store.save(sess)
    return sess
  end

  it('load -> diff 再取得 -> anchor 検証 -> UI -> status=open save', function()
    local sess = save_session { comments = { saved_comment { line = 22, end_line = 22 } } }
    restore.resume_session(sess)

    local active = session_handler.active()
    assert.is_true(active ~= nil)
    assert.equals('open', active.status)
    -- anchor 検証結果が save に反映される (次回以降の検証省略)
    local reloaded = store.load(REPO_TOP, 'main--feature').data
    assert.same({ line = 2, state = 'active' }, {
      line = reloaded.comments[1].line,
      state = reloaded.comments[1].state,
    })
    assert.same(true, reloaded.files['a.lua'].viewed)
    assert.not_equals(-1, vim.fn.bufnr 'review://sidebar/main--feature')
    assert.equals(0, #state.notifications)
  end)

  it(
    'ref 解決不能 (E_REF) は WARN で開かず、保存セッションは無変更',
    function()
      local sess = save_session()
      state.git_code = 128
      state.git_stderr = "fatal: bad ref 'feature'\n"
      state.git_stdout = ''

      restore.resume_session(sess)

      assert.same(
        { msg = "review.nvim: fatal: bad ref 'feature'", level = vim.log.levels.WARN },
        state.notifications[1]
      )
      assert.is_nil(session_handler.active())
      assert.equals(0, vim.fn.bufexists 'review://sidebar/main--feature')
      assert.equals('closed', store.load(REPO_TOP, 'main--feature').data.status)
    end
  )

  it('active な別セッションの resume は確認後の save -> close から開始', function()
    session_handler.start { base = 'main', head = 'feature' } -- active = main--feature
    local other = vim.deepcopy(session_handler.active())
    other.id = 'main--other'
    other.head = 'other'
    other.status = 'closed'
    store.save(other)

    local reloaded_other = store.load(REPO_TOP, 'main--other').data
    restore.resume_session(reloaded_other)

    assert.equals(1, #state.inputs)
    assert.equals('main--other', session_handler.active().id)
    assert.equals('closed', store.load(REPO_TOP, 'main--feature').data.status)
  end)
end)

describe('復元時に差分がまるごと消滅 (persistence-restore.md エッジ)', function()
  use_env()

  local function save_vanishing_session(sess)
    local base = {
      version = 1,
      id = 'main--feature',
      repo = REPO_TOP,
      mode = 'branch',
      base = 'main',
      head = 'feature',
      pr = vim.NIL,
      worktree = vim.NIL,
      status = 'closed',
      files = {},
      comments = {},
      created_at = 1,
      updated_at = 1,
    }
    for k, v in pairs(sess) do
      base[k] = v
    end
    store.save(base)
    return store.load(REPO_TOP, 'main--feature').data
  end

  it(
    'comments あり: UI を開く + diff バッファ「変更なし」+ 全コメント outdated をヘッダ virt text',
    function()
      local sess = save_vanishing_session {
        files = { ['a.lua'] = { viewed = true } },
        comments = { saved_comment() },
      }
      state.git_stdout = '' -- 再取得差分がまるごと消滅

      restore.resume_session(sess)

      -- 「開くことを拒否せず」UI が開く
      local active = session_handler.active()
      assert.is_true(active ~= nil)
      assert.not_equals(-1, vim.fn.bufnr 'review://sidebar/main--feature')
      -- 消失ファイルは合成 entry で diff バッファが開き、「変更なし」表示
      local dbuf = vim.fn.bufnr 'review://diff/main--feature/a.lua'
      assert.not_equals(-1, dbuf)
      assert.same(
        { '■ M a.lua +0 -0', '変更なし' },
        vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)
      )
      -- 全コメント outdated -> ヘッダ行 virt text 一覧 (通常時と同じ規則)
      local ns = vim.api.nvim_get_namespaces()['review_comment']
      local marks = vim.api.nvim_buf_get_extmarks(dbuf, ns, 0, -1, { details = true })
      assert.equals(1, #marks)
      local virt = marks[1][4].virt_text
          and marks[1][4].virt_text[1]
          and marks[1][4].virt_text[1][1]
        or ''
      assert.equals(' ⚠ outdated: note', virt)
      -- outdated 化の結果が save される (status=open 含む)
      local reloaded = store.load(REPO_TOP, 'main--feature').data
      assert.equals('open', reloaded.status)
      assert.equals('outdated', reloaded.comments[1].state)
    end
  )

  it(
    'comments 0: nil 参照で落ちず、「変更なし」プレースホルダの diff バッファで UI を開く',
    function()
      local sess = save_vanishing_session {}
      state.git_stdout = ''

      restore.resume_session(sess)

      local active = session_handler.active()
      assert.is_true(active ~= nil)
      assert.not_equals(-1, vim.fn.bufnr 'review://sidebar/main--feature')
      local placeholder = vim.fn.bufnr 'review://diff/main--feature/(no-diff)'
      assert.not_equals(-1, placeholder)
      assert.same({ '変更なし' }, vim.api.nvim_buf_get_lines(placeholder, 0, -1, false))
      assert.equals('open', store.load(REPO_TOP, 'main--feature').data.status)
    end
  )

  it(
    '複数ファイル消失: 右ペインには sidebar パス昇順先頭のファイルが開く (diff-review 先頭ファイル規則)',
    function()
      local sess = save_vanishing_session {
        files = { ['z.lua'] = { viewed = false }, ['a.lua'] = { viewed = false } },
        comments = {
          saved_comment(),
          saved_comment { id = 'c2', file = 'z.lua', body = 'note2' },
        },
      }
      state.git_stdout = ''

      restore.resume_session(sess)

      assert.not_equals(-1, vim.fn.bufnr 'review://diff/main--feature/a.lua')
      local sb = vim.fn.bufnr 'review://sidebar/main--feature'
      assert.not_equals(-1, sb)
      local sidebar_lines = vim.api.nvim_buf_get_lines(sb, 0, -1, false)
      assert.equals(2, #sidebar_lines)
      assert.is_truthy(sidebar_lines[1]:find('a.lua', 1, true))
      assert.is_falsy(sidebar_lines[1]:find('z.lua', 1, true))
    end
  )
end)

describe(':Review (resume_or_select) と起動時 notify', function()
  use_env()

  local function write_open_session(id, base, head, overrides)
    local s = {
      version = 1,
      id = id,
      repo = REPO_TOP,
      mode = 'branch',
      base = base,
      head = head,
      pr = vim.NIL,
      worktree = vim.NIL,
      status = 'open',
      files = {},
      comments = {},
      created_at = 1,
      updated_at = 1,
    }
    for k, v in pairs(overrides or {}) do
      s[k] = v
    end
    store.save(s)
  end

  it('open 0 件: 開始ガイダンス通知', function()
    restore.resume_or_select()
    assert.same({
      msg = 'review.nvim: 復元できるセッションがありません。:Review start で開始してください',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.is_nil(session_handler.active())
  end)

  it('open 1 件: 即復元', function()
    write_open_session('main--feature', 'main', 'feature')
    restore.resume_or_select()
    assert.equals('main--feature', session_handler.active().id)
  end)

  it('open 複数: vim.ui.select で slug + refs + コメント数を選ばせて復元', function()
    write_open_session('main--feature', 'main', 'feature', { comments = { { id = 'c1' } } })
    write_open_session('x--y', 'x', 'y')
    state.select_answer = 2
    restore.resume_or_select()
    assert.equals('x--y', session_handler.active().id)
  end)

  it('VimEnter scan: open 1 件は「続けられます」notify、窓は開かない', function()
    write_open_session('main--feature', 'main', 'feature')
    restore.notify_open_sessions()
    assert.same({
      msg = 'review.nvim: main--feature のレビューが続けられます (:Review で復元)',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
    assert.equals(0, vim.fn.bufexists 'review://sidebar/main--feature')
  end)

  it('VimEnter scan: 複数なら個数と代表 slug', function()
    write_open_session('a--b', 'a', 'b')
    write_open_session('c--d', 'c', 'd')
    restore.notify_open_sessions()
    local msg = state.notifications[1].msg
    assert.equals(true, msg:find '2 件' ~= nil)
    assert.equals(true, msg:find 'a--b' ~= nil)
  end)

  it('VimEnter scan: open 0 件では何も通知しない', function()
    restore.notify_open_sessions()
    assert.equals(0, #state.notifications)
  end)

  it('repo 外では scan / resume とも開始ガイダンス扱い', function()
    state.git_code = 128
    state.git_stderr = 'fatal: not a git repository\n'
    restore.notify_open_sessions()
    assert.equals(0, #state.notifications)
    restore.resume_or_select()
    assert.same({
      msg = 'review.nvim: 復元できるセッションがありません。:Review start で開始してください',
      level = vim.log.levels.INFO,
    }, state.notifications[1])
  end)
end)

describe('sessions_list の開閉', function()
  use_env()

  it(
    ':Review list で一覧バッファが開き、<Enter> 相当 open_current が resume を呼ぶ',
    function()
      store.save {
        version = 1,
        id = 'main--feature',
        repo = REPO_TOP,
        mode = 'branch',
        base = 'main',
        head = 'feature',
        pr = vim.NIL,
        worktree = vim.NIL,
        status = 'closed',
        files = {},
        comments = {},
        created_at = 1,
        updated_at = 1,
      }
      sessions_list.open()

      local buf = vim.fn.bufnr 'review://sessions'
      assert.not_equals(-1, buf)
      local win = vim.fn.win_findbuf(buf)[1]
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      sessions_list.open_current()
      assert.equals('main--feature', session_handler.active().id)
      assert.equals('open', store.load(REPO_TOP, 'main--feature').data.status)
    end
  )

  it('repo path 消失セッションは grey (open_current で WARN、開かない)', function()
    store.save {
      version = 1,
      id = 'gone--gone',
      repo = '/spec/deleted-repo',
      mode = 'branch',
      base = 'gone',
      head = 'gone',
      pr = vim.NIL,
      worktree = vim.NIL,
      status = 'closed',
      files = {},
      comments = {},
      created_at = 1,
      updated_at = 1,
    }
    sessions_list.open()
    local buf = vim.fn.bufnr 'review://sessions'
    local win = vim.fn.win_findbuf(buf)[1]
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    sessions_list.open_current()
    assert.is_nil(session_handler.active())
    assert.same(1, #state.notifications)
  end)
end)

-- #6: 復元時の worktree 作成判断 (pr-worktree.md「異常終了からの回復」/
-- persistence-restore.md「復元手順」worktree 解決)。
local function pr_session(overrides)
  local sess = {
    version = 1,
    id = 'pr-7',
    repo = REPO_TOP,
    mode = 'pr',
    base = 'main',
    head = 'review-nvim/pr-7',
    pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
    worktree = vim.NIL,
    status = 'closed',
    files = {},
    comments = {},
    created_at = 1,
    updated_at = 1,
  }
  for k, v in pairs(overrides or {}) do
    sess[k] = v
  end
  assert.equals(true, store.save(sess).ok)
  return sess
end

describe('restore の worktree 解决 (mode=pr は resume でも常時作成/再利用)', function()
  use_env()

  it(
    '記録なし PR セッションの復元は `git worktree add --detach` で作って記録',
    function()
      pr_session()

      restore.resume_session(store.load(REPO_TOP, 'pr-7').data)

      assert.equals('pr-7', session_handler.active().id)
      local wt = require('review.store.paths').worktree_path(REPO_TOP, 'pr-7')
      assert.same({ path = wt, created_by_us = true }, store.load(REPO_TOP, 'pr-7').data.worktree)
    end
  )

  it(
    'scan で worktree=null 化された session (doD 3: dir 消滅 → 復元時に作って再生成)',
    function()
      -- 異常終了 -> scan 回収後の状態: 記録 null + status=open
      pr_session { status = 'open' }
      local health = require 'review.handlers.health'
      health.sweep(REPO_TOP, function() end)
      assert.equals(vim.NIL, store.load(REPO_TOP, 'pr-7').data.worktree)

      restore.resume_session(store.load(REPO_TOP, 'pr-7').data)

      local wt = require('review.store.paths').worktree_path(REPO_TOP, 'pr-7')
      assert.same({ path = wt, created_by_us = true }, store.load(REPO_TOP, 'pr-7').data.worktree)
      -- pattern stub の list (worktree 行なし) でも add は走る (add stub ok)
      assert.equals('pr-7', session_handler.active().id)
    end
  )

  it(
    '記録 + dir 実在 + git list に登録 => resume で add せず再利用 (pr-worktree.md 異常終了回復)',
    function()
      local wt = require('review.store.paths').worktree_path(REPO_TOP, 'pr-7')
      vim.fn.mkdir(wt, 'p')
      pr_session { status = 'open', worktree = { path = wt, created_by_us = true } }

      local calls = {}
      cli._set_system(function(cmd, _opts, on_exit)
        table.insert(calls, cmd)
        if cmd[2] == 'rev-parse' then
          on_exit { code = 0, stdout = REPO_TOP .. '\n', stderr = '' }
        elseif cmd[2] == 'diff' then
          on_exit { code = 0, stdout = RAW_1HUNK, stderr = '' }
        elseif cmd[2] == 'worktree' and cmd[3] == 'list' then
          on_exit {
            code = 0,
            stdout = 'worktree ' .. REPO_TOP .. '\nworktree ' .. wt .. '\n',
            stderr = '',
          }
        else
          on_exit { code = 0, stdout = '', stderr = '' }
        end
      end)

      restore.resume_session(store.load(REPO_TOP, 'pr-7').data)

      assert.equals('pr-7', session_handler.active().id)
      assert.same({ path = wt, created_by_us = true }, store.load(REPO_TOP, 'pr-7').data.worktree)
      for _, cmd in ipairs(calls) do
        assert.equals(false, cmd[3] == 'add', 'add が出た: ' .. table.concat(cmd, ' '))
      end
    end
  )
end)
