-- handlers/session: セッション開始 / 終了 / 削除と active 排他 (INV-1)、
-- UI open / sidebar <CR> / x の save トリガ (INV-4)。
-- git 注入スタブ (git/cli_spec と同期 on_exit パターン) で開始フローを同期駆動し、
-- save は paths._set_data_dir 注入の tmpdir へ実ファイルを書いて検証する。
local cli = require 'review.git.cli'
local config = require 'review.config'
local paths = require 'review.store.paths'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'

local REPO_TOP = '/spec/repo-top'
local SLUG = 'main--feature'

local RAW_DIFF_A_B = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1 +1,2 @@',
  ' line1',
  '+line2',
  'diff --git a/b.lua b/b.lua',
  'new file mode 100644',
  'index 0000000..3333333',
  '--- /dev/null',
  '+++ b/b.lua',
  '@@ -0,0 +1 @@',
  '+b1',
  '',
}, '\n')

local SIDEBAR_NAME = 'review://sidebar/' .. SLUG
local DIFF_A_NAME = 'review://diff/' .. SLUG .. '/a.lua'

local state = {}

-- cli._set_system 注入: 実行順に responses[idx] を同期 for on_exit を呼ぶ。
local function install_git(responses)
  state.git_calls = {}
  cli._set_system(function(cmd, opts, on_exit)
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    if responses[idx] == nil then
      error('git stub: 想定外の追加実行 ' .. table.concat(cmd, ' '), 0)
    end
    on_exit(responses[idx](cmd, opts))
  end)
  cli._set_executable(function()
    return 1
  end)
end

local top_ok = function()
  return { code = 0, stdout = REPO_TOP .. '\n', stderr = '' }
end

local diff_ok = function(stdout)
  return { code = 0, stdout = stdout, stderr = '' }
end

local function load_saved(id)
  return store.load(REPO_TOP, id or SLUG).data
end

local function json_path(id)
  return paths.session_file(REPO_TOP, id or SLUG)
end

local function existing_stub(overrides)
  local s = {
    version = 1,
    id = SLUG,
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
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

-- plenary busted は describe 外のフックを持たないため helper 経由で登録する。
-- vim 組み込み関数はプロセス単一なので real 参照は require 時に 1 回捕捉する
-- (before_each ごとに見ると spy が入れ子になり after_each の復旧先が壊れる)。
local REAL_NOTIFY = vim.notify
local REAL_INPUT = vim.ui.input

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, inputs = {}, input_answer = 'y' }
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
    session_handler._reset()
    -- review://* バッファは nvim インスタンス全局の単一リソース (同名再利用)。
    -- 前テスト残り を掃除しないと別テストの UI と混線する。
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
    vim.notify = REAL_NOTIFY
    vim.ui.input = REAL_INPUT
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

-- top -> diff メインの start を完結させる。
local function start_done(base, head)
  install_git {
    top_ok,
    function()
      return diff_ok(RAW_DIFF_A_B)
    end,
  }
  return session_handler.start { base = base, head = head }
end

describe('session.start 開始フロー', function()
  use_env()

  it(
    'diff 取得 -> session save -> sidebar + 先頭ファイル diff の UI 開き -> active 化',
    function()
      local res = start_done('main', 'feature')

      assert.equals(true, res.ok)
      assert.same({ 'git', 'rev-parse', '--show-toplevel' }, state.git_calls[1])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[2])

      assert.same({
        version = 1,
        id = SLUG,
        repo = REPO_TOP,
        mode = 'branch',
        base = 'main',
        head = 'feature',
        pr = vim.NIL,
        worktree = vim.NIL,
        status = 'open',
        files = { ['a.lua'] = { viewed = false }, ['b.lua'] = { viewed = false } },
        comments = {},
        created_at = 4321,
        updated_at = 4321,
      }, load_saved())
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      assert.not_equals(-1, sb)
      assert.same(
        { 'M a.lua +1 -0', 'A b.lua +1 -0' },
        vim.api.nvim_buf_get_lines(sb, 0, -1, false)
      )
      assert.not_equals(-1, vim.fn.bufnr(DIFF_A_NAME))
      assert.equals(0, #state.notifications)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    'ref 解決不能 (diff exit 128) は WARN 通知で UI を開かず save もしない',
    function()
      install_git {
        top_ok,
        function()
          return { code = 128, stdout = '', stderr = "fatal: bad revision 'nope'\n" }
        end,
      }
      -- git を伴う失敗は結果型では返さず notify で返す (DESIGN.md「API 一覧」非同期契約)。
      session_handler.start { base = 'main', head = 'nope' }

      assert.same(
        { msg = "review.nvim: fatal: bad revision 'nope'", level = vim.log.levels.WARN },
        state.notifications[1]
      )
      assert.equals(1, #state.notifications)
      assert.is_nil(load_saved())
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
      assert.is_nil(session_handler.active())
    end
  )

  it(
    '差分 0 ファイルは「変更なし」通知で開始しない (エラーではない)',
    function()
      install_git {
        top_ok,
        function()
          return diff_ok ''
        end,
      }
      local res = session_handler.start { base = 'main', head = 'feature' }

      -- git を伴う操作の戻り値は「ディスパッチを受け付けた」ことを表す (DESIGN.md API 一覧)。
      assert.equals(true, res.ok)
      assert.same({
        msg = 'review.nvim: 変更なし (main..feature): レビュー対象がありません',
        level = vim.log.levels.INFO,
      }, state.notifications[1])
      assert.equals(1, #state.notifications)
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
      assert.is_nil(session_handler.active())
    end
  )

  it(
    'head 省略時は vim.ui.input (branches -> tags 補完) で選んだ head で開始する',
    function()
      install_git {
        top_ok,
        function()
          return { code = 0, stdout = 'feature\nmain\n', stderr = '' }
        end,
        function()
          return { code = 0, stdout = 'v1\n', stderr = '' }
        end,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      local capture = nil
      vim.ui.input = function(opts, cb)
        capture = opts
        table.insert(state.inputs, opts)
        cb 'feature'
      end

      session_handler.start { base = 'main' }

      -- 既定 vim.ui.input は opts を vim.fn.input へそのまま渡す。Lua 関数を
      -- 含む opts は E467 で即失敗し on_confirm(nil) になるため、input() が
      -- 受理する文字形式 'customlist,{Vim script 関数名}' でなければならない
      -- (実 nvim での手動実証は DESIGN.md「既知の制約」)。
      assert.equals('customlist,ReviewNvimHeadComplete', capture.completion)
      assert.is_nil(capture.complete)
      -- 補完関数の実体解決 (vim fn -> luaeval -> Lua) を本物の呼び出しで pin する。
      -- opts を mock してもこの経路は mock を通らない。
      assert.same({ 'feature', 'main', 'v1' }, vim.fn.call('ReviewNvimHeadComplete', { '', '', 0 }))
      assert.same({ 'main' }, vim.fn.call('ReviewNvimHeadComplete', { 'ma', '', 0 }))
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[4])
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it('repo 外 (top 解決失敗) は WARN で開始しない', function()
    install_git {
      function()
        return { code = 128, stdout = '', stderr = 'fatal: not a git repository\n' }
      end,
    }
    session_handler.start { base = 'main', head = 'feature' }

    assert.same(1, #state.notifications)
    assert.equals(vim.log.levels.WARN, state.notifications[1].level)
    assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
  end)
end)

describe('session.start 既存セッション継承と active 排他 (INV-1)', function()
  use_env()

  it(
    '同一 refs 組の保存済みセッションは確認後の継承 (comments / viewed 引き継ぎ)',
    function()
      local existing = existing_stub {
        files = { ['a.lua'] = { viewed = true }, ['b.lua'] = { viewed = false } },
        comments = {
          {
            id = 'c1',
            file = 'a.lua',
            line = 2,
            end_line = 2,
            body = 'keep me',
            anchor = { before = 'line1', line = 'line2', after = vim.NIL },
            state = 'active',
            created_at = 100,
          },
        },
      }
      store.save(existing)

      start_done('main', 'feature')

      local sess = load_saved()
      assert.equals('open', sess.status)
      assert.same(existing.comments, sess.comments)
      assert.equals(true, sess.files['a.lua'].viewed)
      assert.equals(1, #state.inputs) -- 継承確認を 1 回
      assert.equals(
        'review.nvim: 既存セッション main--feature (main..feature, コメント 1 件) に同じ '
          .. 'refs 組の開始です。コメント内容を継承して開きますか？ [y/N]: ',
        state.inputs[1].prompt
      )
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      assert.equals('[✓] M a.lua +1 -0', vim.api.nvim_buf_get_lines(sb, 0, -1, false)[1])
    end
  )

  it(
    '継承確認を断るとディスクも UI も無変更 (開始も close も走らない)',
    function()
      store.save(existing_stub { status = 'open' })
      local mtime_before = vim.uv.fs_stat(json_path()).mtime
      state.input_answer = 'n'

      start_done('main', 'feature')

      assert.is_nil(session_handler.active())
      assert.same(mtime_before, vim.uv.fs_stat(json_path()).mtime)
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
    end
  )

  it(
    '別 refs 組が active な開始は確認後の save -> close してから新セッション',
    function()
      start_done('main', 'feature')

      install_git {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'hotfix' }

      assert.equals(1, #state.inputs)
      assert.equals('closed', load_saved('main--feature').status)
      assert.equals('open', load_saved('main--hotfix').status)
      assert.equals('main--hotfix', session_handler.active().id)
      assert.equals(0, vim.fn.bufexists 'review://sidebar/main--feature')
    end
  )

  it(
    '別 refs 組が active な開始の確認を断ると既存 active がそのまま残る',
    function()
      start_done('main', 'feature')
      install_git {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'hotfix' }

      assert.equals(SLUG, session_handler.active().id)
      assert.equals(0, vim.fn.bufexists 'review://sidebar/main--hotfix')
    end
  )

  -- active+同一 refs 保存済みの組合せ (レビューで検出した上書き開始バグの回帰 pin)。
  -- 保存済みがある限り active の有無にかかわらず継承で、上書き開始はできない。
  local function prepare_feature_with_comment_then_switch()
    start_done('main', 'feature')
    session_handler.active().comments[1] = {
      id = 'c1',
      file = 'a.lua',
      line = 2,
      end_line = 2,
      body = 'KEEP ME',
      anchor = { before = 'line1', line = 'line2', after = vim.NIL },
      state = 'active',
      created_at = 100,
    }
    session_handler.commit_comment_change() -- INV-4 save
    local sb = vim.fn.bufnr(SIDEBAR_NAME)
    local win = vim.fn.win_findbuf(sb)[1]
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    session_handler.toggle_viewed_current() -- a.lua viewed=true + save

    install_git {
      top_ok,
      function()
        return diff_ok(RAW_DIFF_A_B)
      end,
    }
    session_handler.start { base = 'main', head = 'hotfix' } -- 別 refs 組へ切替
    assert.equals('main--hotfix', session_handler.active().id)
    assert.equals('closed', load_saved('main--feature').status)
    state.inputs = {} -- 切替フローの確認は本テストの検証対象から外す
  end

  it(
    'active 下でも同一 refs 組の保存済みは継承 (コメント / viewed 保持、確認 1 回統合)',
    function()
      prepare_feature_with_comment_then_switch()
      local saved = load_saved()
      assert.equals('KEEP ME', saved.comments[1].body) -- 前提: 消さず保存されている

      install_git {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(1, #state.inputs) -- close+継承は 1 回の確認に統合
      assert.equals(
        'review.nvim: active セッション main--hotfix です。閉じて main--feature を継承しますか？'
          .. ' コメント内容も引き継ぎます [y/N]: ',
        state.inputs[1].prompt
      )
      assert.equals(SLUG, session_handler.active().id)
      local reloaded = load_saved()
      assert.equals('open', reloaded.status)
      assert.same(saved.comments, reloaded.comments) -- 上書きされず comments がそのまま
      assert.equals(true, reloaded.files['a.lua'].viewed)
      assert.equals('closed', load_saved('main--hotfix').status)
      assert.equals(
        '[✓] M a.lua +1 -0',
        vim.api.nvim_buf_get_lines(vim.fn.bufnr(SIDEBAR_NAME), 0, -1, false)[1]
      )
    end
  )

  it(
    'active 下の同一 refs 組継承確認を断ると active / ディスク無変更',
    function()
      prepare_feature_with_comment_then_switch()
      local mtime_before = vim.uv.fs_stat(paths.session_file(REPO_TOP, SLUG)).mtime
      install_git {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals('main--hotfix', session_handler.active().id)
      assert.same(mtime_before, vim.uv.fs_stat(paths.session_file(REPO_TOP, SLUG)).mtime)
      assert.equals(0, vim.fn.bufexists 'review://sidebar/main--feature')
    end
  )

  it(
    '衝突 slug (別 refs 組で同一 slug) は新規作成を拒否し既存を案内する',
    function()
      -- branch_slug の連結は単射でない: ('a--b','c') と ('a','b--c') は同一
      -- slug 'a--b--c' (paths.lua のコメントと同じ衝突)。
      store.save(existing_stub { id = 'a--b--c', base = 'a--b', head = 'c' })

      start_done('a', 'b--c')

      assert.same({
        msg = 'review.nvim: slug a--b--c に既存セッション (a--b..c) があります。'
          .. ':Review delete a--b--c で削除してください',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.is_nil(session_handler.active())
      assert.equals('a--b', store.load(REPO_TOP, 'a--b--c').data.base)
    end
  )
end)

describe('session.close / session.delete', function()
  use_env()

  it('active 0 件の close は E_NOT_ACTIVE を同期で返す', function()
    assert.same({
      __class = 'review.Result',
      ok = false,
      error = 'review.nvim: アクティブなセッションがありません',
      code = 'E_NOT_ACTIVE',
    }, session_handler.close())
  end)

  it(
    'コメント 0 件は確認なしで閉じ status=closed で save / window を掃除する',
    function()
      start_done('main', 'feature')

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.equals(4321, load_saved().updated_at)
      assert.is_nil(session_handler.active())
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
      assert.equals(0, vim.fn.bufexists(DIFF_A_NAME))
      assert.equals(0, #state.inputs)
    end
  )

  it(
    'コメントありの close は確認を要求する (n なら閉じず / y で status=closed)',
    function()
      start_done('main', 'feature')
      session_handler.active().comments[1] = {
        id = 'c1',
        file = 'a.lua',
        line = 2,
        end_line = 2,
        body = 'b',
        anchor = vim.NIL,
        state = 'active',
        created_at = 1,
      }

      state.input_answer = 'n'
      session_handler.close()
      assert.equals('open', load_saved().status)
      assert.equals(SLUG, session_handler.active().id)

      state.input_answer = 'y'
      session_handler.close()
      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
    end
  )

  it('delete: 確認 -> active 解除 -> JSON ファイル削除', function()
    start_done('main', 'feature')
    install_git { top_ok }
    state.input_answer = 'y'

    session_handler.delete(SLUG)

    assert.is_nil(session_handler.active())
    assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
  end)

  it('delete: 確認を要求する (n では削除しない)', function()
    start_done('main', 'feature')
    install_git { top_ok }
    state.input_answer = 'n'

    session_handler.delete(SLUG)

    assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
    assert.equals(SLUG, session_handler.active().id)
  end)
end)

describe('sidebar 操作 (viewed / 差分切替) と INV-4 save', function()
  use_env()

  local function focus_sidebar_row(row)
    local sb = vim.fn.bufnr(SIDEBAR_NAME)
    local win = vim.fn.win_findbuf(sb)[1]
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end

  it(
    '<Enter> で右ペインをそのファイルの diff に差し替え viewed=true + save',
    function()
      start_done('main', 'feature')
      focus_sidebar_row(2)

      session_handler.open_selected_file()

      assert.equals(1, vim.fn.bufexists 'review://diff/main--feature/b.lua')
      assert.equals(true, load_saved().files['b.lua'].viewed)
    end
  )

  it('x で viewed 切替 -> 直後に save (両方向)', function()
    start_done('main', 'feature')
    focus_sidebar_row(1)

    session_handler.toggle_viewed_current()
    assert.equals(true, load_saved().files['a.lua'].viewed)

    session_handler.toggle_viewed_current()
    assert.equals(false, load_saved().files['a.lua'].viewed)
  end)

  it(
    'sidebar o (keymap rhs 実行): git show <head>:<path> の read-only fileview が開く',
    function()
      start_done('main', 'feature')
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      local win = vim.fn.win_findbuf(sb)[1]
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      install_git {
        function()
          return { code = 0, stdout = 'line1\nline2\n', stderr = '' }
        end,
      }

      -- list.lua が貼った rhs 文字列そのものを実行する (押下と同一経路)
      local rhs
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(sb, 'n')) do
        if m.lhs == 'o' then
          rhs = m.rhs
        end
      end
      assert.is_not_nil(rhs)
      -- 発火時と同じ対象を叩く (終端の <CR> は keymap の確定キー。vim.cmd では除去)
      vim.cmd((rhs:gsub('<CR>$', '')))

      assert.same({ 'git', 'show', 'feature:a.lua' }, state.git_calls[1])
      local fbuf = vim.fn.bufnr 'review://file/main--feature/a.lua'
      assert.not_equals(-1, fbuf)
      assert.same({ 'line1', 'line2' }, vim.api.nvim_buf_get_lines(fbuf, 0, -1, false))
      assert.is_true(vim.bo[fbuf].readonly)
    end
  )

  it('q (close_by_key) は close と同じ (コメント 0 では無確認)', function()
    start_done('main', 'feature')

    session_handler.close_by_key()

    assert.equals('closed', load_saved().status)
    assert.is_nil(session_handler.active())
    assert.equals(0, #state.inputs)
  end)
end)
