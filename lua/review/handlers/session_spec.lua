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

-- top -> diff -> worktree 作成判断 (branch: head==HEAD + clean で skip) までを
-- 完結させるレスポンス列。作成判断の 3 呼び (rev-parse head / rev-parse HEAD /
-- status --porcelain) を同一コミット + clean で応答すると worktree なしになる。
local SAME_SHA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
local JUDGE_SKIP = {
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = '', stderr = '' }
  end,
}

-- top -> diff メインの start を完結させる。
local function start_done(base, head)
  install_git {
    top_ok,
    function()
      return diff_ok(RAW_DIFF_A_B)
    end,
    JUDGE_SKIP[1],
    JUDGE_SKIP[2],
    JUDGE_SKIP[3],
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
        JUDGE_SKIP[1],
        JUDGE_SKIP[2],
        JUDGE_SKIP[3],
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
        JUDGE_SKIP[1],
        JUDGE_SKIP[2],
        JUDGE_SKIP[3],
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
        JUDGE_SKIP[1],
        JUDGE_SKIP[2],
        JUDGE_SKIP[3],
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
      JUDGE_SKIP[1],
      JUDGE_SKIP[2],
      JUDGE_SKIP[3],
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
        JUDGE_SKIP[1],
        JUDGE_SKIP[2],
        JUDGE_SKIP[3],
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
        JUDGE_SKIP[1],
        JUDGE_SKIP[2],
        JUDGE_SKIP[3],
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

-- ---------------------------------------------------------------------------
-- #6 worktree: 作成判断 / close / delete / o 実ファイル (pr-worktree.md)
-- ---------------------------------------------------------------------------

local WT_OTHER_SHA = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

-- paths.worktree_path は注入済み state.dir を使うので require 時でなく呼ぶ時に計算する。
local function wt_path(slug)
  return paths.worktree_path(REPO_TOP, slug or SLUG)
end

-- 作成判断で worktree を要る状態にするレスポンス (head != HEAD コミット / tree clean)。
local JUDGE_HEAD_DIFF = {
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = WT_OTHER_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = '', stderr = '' }
  end,
}

-- 作成判断で worktree を要る状態にするレスポンス (同一コミット + 未コミット変更)。
local JUDGE_DIRTY = {
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = ' M a.lua\n', stderr = '' }
  end,
}

local git_ok = function()
  return { code = 0, stdout = '', stderr = '' }
end

local function git_fail(msg)
  return function()
    return { code = 255, stdout = '', stderr = msg }
  end
end

local function add_cmd(ref)
  return { 'git', 'worktree', 'add', '--detach', wt_path(), ref or 'feature' }
end

local function list_cmd()
  return { 'git', 'worktree', 'list', '--porcelain' }
end

-- 応答の選択肢を 1 回目順に 1 件ずつ返す入力スタブ (delete+force の 2 確認用)。
local function answer_queue(answers)
  local idx = 0
  vim.ui.input = function(opts, cb)
    idx = idx + 1
    table.insert(state.inputs, opts)
    cb(answers[idx])
  end
end

-- worktree 作成まで進む start。
local function start_with(responses)
  install_git(responses)
  return session_handler.start { base = 'main', head = 'feature' }
end

-- worktree 作成済み (記録 {path=wt_path(), created_by_us=true}) のセッションを開始。
local function started_with_worktree()
  start_with {
    top_ok,
    function()
      return diff_ok(RAW_DIFF_A_B)
    end,
    JUDGE_HEAD_DIFF[1],
    JUDGE_HEAD_DIFF[2],
    JUDGE_HEAD_DIFF[3],
    git_ok,
  }
end

-- install_git の worktree remove 非同期版。'git worktree remove' に限って
-- on_exit を state.deferred に捕捉して呼ばない (実 vim.system は非同期。
-- install_git の同期 on_exit では区別できない「remove 完了前/後」の順序を pin する)。
-- responses の remove のスロットは手前へ返るため読まれない (placeholder で可)。
local function install_git_deferred_remove(responses)
  state.git_calls = {}
  state.deferred = nil
  cli._set_system(function(cmd, opts, on_exit)
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    if cmd[2] == 'worktree' and cmd[3] == 'remove' then
      state.deferred = on_exit
      return
    end
    if responses[idx] == nil then
      error('git stub: 想定外の追加実行 ' .. table.concat(cmd, ' '), 0)
    end
    on_exit(responses[idx](cmd, opts))
  end)
  cli._set_executable(function()
    return 1
  end)
end

describe('worktree 作成判断 (branch: pr-worktree.md 決定表)', function()
  use_env()

  it(
    'head==HEAD コミットかつ clean => worktree を作らない (現在の作業ツリーが head の実ファイル)',
    function()
      start_done('main', 'feature')

      assert.equals(vim.NIL, load_saved().worktree)
      assert.equals(5, #state.git_calls) -- top, diff, rp head, rp HEAD, status
    end
  )

  it('判断の 5 呼び以降に worktree 起動は出ない (skip)', function()
    start_done('main', 'feature')
    local joined = ''
    for _, cmd in ipairs(state.git_calls) do
      joined = joined .. table.concat(cmd, ' ') .. ';'
    end
    assert.equals(
      'git rev-parse --show-toplevel;git diff main feature;'
        .. 'git rev-parse --verify feature;git rev-parse --verify HEAD;'
        .. 'git -C '
        .. REPO_TOP
        .. ' status --porcelain;',
      joined
    )
  end)

  it(
    'head != HEAD コミット => add --detach <data 下の path> <head> 作り created_by_us=true 記録',
    function()
      start_with {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        JUDGE_HEAD_DIFF[1],
        JUDGE_HEAD_DIFF[2],
        JUDGE_HEAD_DIFF[3],
        git_ok,
      }

      assert.same(add_cmd(), state.git_calls[6])
      assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
      assert.equals(0, #state.notifications)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    '同一コミットでも未コミット変更あり => worktree を作る (決定表: clean は両条件)',
    function()
      start_with {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        JUDGE_DIRTY[1],
        JUDGE_DIRTY[2],
        JUDGE_DIRTY[3],
        git_ok,
      }

      assert.same(add_cmd(), state.git_calls[6])
      assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
    end
  )

  it('作成失敗 -> `git worktree prune` 再試行 recover (孤児登録の回収)', function()
    start_with {
      top_ok,
      function()
        return diff_ok(RAW_DIFF_A_B)
      end,
      JUDGE_HEAD_DIFF[1],
      JUDGE_HEAD_DIFF[2],
      JUDGE_HEAD_DIFF[3],
      git_fail 'fatal: already registered\n', -- add1
      git_ok, -- prune
      git_ok, -- add2
    }

    assert.same(add_cmd(), state.git_calls[8])
    assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[7])
    assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
  end)

  it(
    '作成失敗 (prune でも解消せず / 自前記録なし) => E_WORKTREE 案内を WARN、開始中断 (save なし・UI なし)',
    function()
      start_with {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        JUDGE_HEAD_DIFF[1],
        JUDGE_HEAD_DIFF[2],
        JUDGE_HEAD_DIFF[3],
        git_fail('fatal: ' .. wt_path() .. ' already exists\n'), -- add1
        git_ok, -- prune
        git_fail('fatal: ' .. wt_path() .. ' already exists\n'), -- add2
      }

      assert.same(
        (
          'review.nvim: worktree を作成できません: %s。'
          .. '同名の作業ツリーが残っている場合は `git worktree remove` で掃除してから再試行してください (fatal: %s already exists)'
        ):format(wt_path(), wt_path()),
        state.notifications[1].msg
      )
      assert.equals(vim.log.levels.WARN, state.notifications[1].level)
      assert.equals(1, #state.notifications)
      assert.is_nil(load_saved())
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
      assert.is_nil(session_handler.active())
    end
  )

  it(
    '記録済み worktree: git list 登録あり + dir 実在 => add せず再利用 (再開時の worktree 再利用)',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      local real_wt = vim.uv.fs_realpath(wt)
      store.save(existing_stub { worktree = { path = wt, created_by_us = true } })

      start_with {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        JUDGE_DIRTY[1],
        JUDGE_DIRTY[2],
        JUDGE_DIRTY[3],
        function()
          return {
            code = 0,
            stdout = 'worktree ' .. REPO_TOP .. '\nworktree ' .. real_wt .. '\n',
            stderr = '',
          }
        end,
      }

      assert.equals(6, #state.git_calls)
      assert.same(list_cmd(), state.git_calls[6])
      assert.same({ path = wt, created_by_us = true }, load_saved().worktree)
    end
  )

  it(
    -- INV-3: 削除してよいのは created_by_us=true の自前分だけ
    '記録 true + dir 実在 + 未登録 => add 衝突 -> prune -> 再衝突 -> remove_dir して再 add',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      store.save(existing_stub { worktree = { path = wt, created_by_us = true } })

      start_with {
        top_ok,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        JUDGE_DIRTY[1],
        JUDGE_DIRTY[2],
        JUDGE_DIRTY[3],
        function()
          return { code = 0, stdout = 'worktree /elsewhere\n', stderr = '' } -- list: 未登録
        end,
        git_fail 'fatal: already registered\n', -- add1
        git_ok, -- prune
        git_fail 'fatal: already registered\n', -- add2 (dir がまだ在る)
        git_ok, -- add3 (remove_dir 後)
      }

      -- remove_dir が自前 dir を実削除した (add3 はスタブ応答なので dir は再生成されない)。
      -- 削除后的成功 add まで通ってワークツリー記録が復活すること自体の往復は worktree_spec 実 git 側。
      assert.is_true(vim.uv.fs_stat(wt) == nil)
      -- top, diff, rev-parse x2, status, list, add1, prune, add2, add3
      assert.equals(10, #state.git_calls)
      assert.same({ path = wt, created_by_us = true }, load_saved().worktree)
    end
  )
end)

describe('close の worktree クリーンアップ (セッション終了 1-4)', function()
  use_env()

  it(
    -- 終了手順 2-3: status -> save(closed) -> remove。ref 掃除は delete のみ
    'worktree clean => 確認なしで save(closed) -> `git worktree remove` まで走る',
    function()
      started_with_worktree()

      install_git {
        git_ok, -- status clean
        git_ok, -- remove ok
      }
      session_handler.close()

      assert.same({ 'git', '-C', wt_path(), 'status', '--porcelain' }, state.git_calls[1])
      assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[2])
      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      assert.equals(0, #state.inputs)
    end
  )

  it(
    'worktree 未コミット変更あり: --force 確認。キャンセル = close 中止 (save なし・UI 維持)',
    function()
      started_with_worktree()
      state.input_answer = 'n'
      install_git {
        function()
          return { code = 0, stdout = ' M a.lua\n', stderr = '' }
        end,
      }

      session_handler.close()

      assert.equals(1, #state.inputs)
      assert.equals(
        (
          'review.nvim: worktree %s に未コミットの変更があります。削除して閉じますか？ '
          .. '(git worktree remove --force — ディスクの編集は破棄されます) [y/N]: '
        ):format(wt_path()),
        state.inputs[1].prompt
      )
      assert.equals('open', load_saved().status)
      assert.equals(SLUG, session_handler.active().id)
      assert.equals(1, vim.fn.bufexists(SIDEBAR_NAME))
      assert.equals(1, #state.git_calls) -- status 之後何も走らない
    end
  )

  it(
    '--force 承認 => save(closed) -> remove --force。worktree 記録は JSON に残る (ref も残る: update-ref なし)',
    function()
      started_with_worktree()
      install_git {
        function()
          return { code = 0, stdout = ' M a.lua\n', stderr = '' }
        end,
        git_ok, -- remove --force ok
      }

      session_handler.close()

      assert.same({ 'git', 'worktree', 'remove', '--force', wt_path() }, state.git_calls[2])
      assert.equals('closed', load_saved().status)
      assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
      assert.is_nil(session_handler.active())
    end
  )

  it(
    'remove 失敗は WARN を出し close (save・クローズ) 自体は完了させる (残骸は起動 scan)',
    function()
      started_with_worktree()
      install_git {
        git_ok, -- status clean
        function()
          return { code = 128, stdout = '', stderr = 'fatal: remove boom\n' }
        end,
      }

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      assert.same({
        msg = 'review.nvim: worktree 掃除に失敗しました (残骸は起動 scan が回収します): fatal: remove boom',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
    end
  )

  it(
    'status 検知不能 (dir 消失 etc の git 失敗) は remove を呼ばず WARN で close 完走',
    function()
      started_with_worktree()
      install_git {
        git_fail("fatal: cannot change to '" .. wt_path() .. "'\n"),
      }

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.equals(1, #state.git_calls)
      assert.equals(vim.log.levels.WARN, state.notifications[1].level)
    end
  )

  it(
    'worktree なしセッションの close は git 追加呼び出し 0 (従来動作)',
    function()
      start_done('main', 'feature')
      install_git {}
      session_handler.close()
      assert.equals('closed', load_saved().status)
      assert.equals(0, #state.git_calls)
    end
  )

  it(
    'INV-3: created_by_us=false 記録のまま close すると worktree に一切触れない (status/remove 0 件)',
    function()
      started_with_worktree()
      -- active / disk の記録を非自前へ書き換える (テスト目的の注入)
      local sess = load_saved()
      sess.worktree = { path = wt_path(), created_by_us = false }
      assert.equals(true, store.save(sess).ok)
      session_handler.active().worktree = sess.worktree
      install_git { git_ok }

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      assert.same({ path = wt_path(), created_by_us = false }, load_saved().worktree)
      assert.equals(0, #state.git_calls)
    end
  )
end)

describe('delete の worktree / ref 掃除', function()
  use_env()

  it(
    '閉じた作成分残骸 (active なし): status -> remove 掃除 -> 自前 pr ref 削除 -> JSON 削除 (孤児 dir を残さない)',
    function()
      vim.fn.mkdir(wt_path 'pr-7', 'p')
      store.save(existing_stub {
        id = 'pr-7',
        mode = 'pr',
        base = 'main',
        head = 'review-nvim/pr-7',
        pr = { number = 7, url = 'https://github.com/acme/demo/pull/7' },
        worktree = { path = wt_path 'pr-7', created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean
        git_ok, -- remove ok
        git_ok, -- update-ref ok
      }
      state.input_answer = 'y'

      session_handler.delete 'pr-7'

      assert.same({ 'git', '-C', wt_path 'pr-7', 'status', '--porcelain' }, state.git_calls[2])
      assert.same({ 'git', 'worktree', 'remove', wt_path 'pr-7' }, state.git_calls[3])
      assert.same({ 'git', 'update-ref', '-d', 'refs/heads/review-nvim/pr-7' }, state.git_calls[4])
      assert.equals(4, #state.git_calls)
      assert.is_true(vim.uv.fs_stat(paths.session_file(REPO_TOP, 'pr-7')) == nil)
    end
  )

  it(
    '閉じたセッションに worktree 記録なし: git は top だけ (branch なので ref 掃除なし)',
    function()
      store.save(existing_stub { pr = vim.NIL })
      install_git { top_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.equals(1, #state.git_calls)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    end
  )

  it(
    'active 同一 id の delete は close 相当の掃除 (status -> save -> remove) -> JSON 削除',
    function()
      started_with_worktree()
      install_git {
        top_ok,
        git_ok, -- worktree status clean
        git_ok, -- remove ok
      }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.same({ 'git', '-C', wt_path(), 'status', '--porcelain' }, state.git_calls[2])
      assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
      local has_update_ref = false
      for _, cmd in ipairs(state.git_calls) do
        if cmd[2] == 'update-ref' then
          has_update_ref = true
        end
      end
      assert.equals(false, has_update_ref)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
      assert.is_nil(session_handler.active())
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
    end
  )

  it(
    'active 同一 id の delete: JSON+ref 削除は remove (手順 3) の投入より先へ進まず、完了を待って実行する',
    function()
      started_with_worktree()
      install_git_deferred_remove { top_ok, git_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      -- remove は投入済みで未完了 (state.deferred)。この時点で JSON が消えて
      -- いると、remove 失敗時に孤児 dir を scan が回収できない (記録が既に
      -- 削除済みで created_by_us を読めない) — pr-worktree.md「セッションの
      -- 削除」手順 1〜3 完了順の pin。
      assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
      assert.is_true(state.deferred ~= nil)
      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)
      assert.equals(0, #state.notifications)

      state.deferred { code = 0, stdout = '', stderr = '' }

      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
      assert.is_nil(session_handler.active())
      assert.equals(3, #state.git_calls)
    end
  )

  it(
    'active 同一 id の delete で remove 失敗: closed 残骸と同一の掃除で回収してから削除完了 (孤児 dir なし)',
    function()
      started_with_worktree()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p') -- remove 失敗後も dir が残る実状態
      install_git_deferred_remove { top_ok, git_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)
      state.deferred { code = 255, stdout = '', stderr = 'fatal: remove boom\n' }

      -- 失敗は通知され (delete 自身の失敗通知)、掃除が完走したら JSON+ref 削除へ進む。
      assert.same({
        msg = 'review.nvim: worktree 掃除に失敗しました (残骸は起動 scan が回収します): fatal: remove boom',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      assert.is_true(vim.uv.fs_stat(wt) == nil)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    end
  )

  it(
    'active 同一 id の delete で remove も dir 削除も失敗: 中止と WARN、JSON は closed+created_by_us で scan 回収可',
    function()
      started_with_worktree()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      local locked = io.open(vim.fs.joinpath(wt, 'locked.txt'), 'w')
      locked:write 'x\n'
      locked:close()
      -- dir を r-x (書き込み不可) にすると remove_dir の unlink が実 FS 権限で失敗する
      -- (root 実行では成り立たない。make test はローカル非 root 前提 — DESIGN.md 開発コマンド)。
      vim.fn.system { 'chmod', '555', wt }
      assert.equals(0, vim.v.shell_error)
      install_git_deferred_remove { top_ok, git_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)
      state.deferred { code = 255, stdout = '', stderr = 'fatal: remove boom\n' }

      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      assert.same({
        msg = 'review.nvim: worktree 掃除に失敗しました (残骸は起動 scan が回収します): fatal: remove boom',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.same({
        msg = 'review.nvim: 孤児 worktree dir を消去できませんでした。孤児 dir を残さないためセッション削除は中止します: '
          .. wt,
        level = vim.log.levels.WARN,
      }, state.notifications[2])
      -- JSON を消さない = closed + created_by_us=true の記録が残る。これは起動
      -- scan (health.classify) の「掃除してよい残骸」入力そのもの (孤児化しない)。
      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)
      assert.same({ path = wt, created_by_us = true }, load_saved().worktree)

      -- after_each の tmpdir 掃除 (delete 'rf') を通すため権限を戻す
      vim.fn.system { 'chmod', '755', wt }
      assert.equals(0, vim.v.shell_error)
    end
  )

  it(
    'INV-3: created_by_us=false 記録の dir は触れない (active なし delete は remove なしでファイルのみ削除)',
    function()
      store.save(existing_stub {
        worktree = { path = wt_path(), created_by_us = false },
      })
      install_git { top_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.equals(1, #state.git_calls)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    end
  )

  it(
    'active なし残骸が dirty: --force 確認、キャンセルなら delete 中止 (JSON 保持・dir 保持)',
    function()
      vim.fn.mkdir(wt_path(), 'p')
      store.save(existing_stub {
        worktree = { path = wt_path(), created_by_us = true },
      })
      install_git {
        top_ok,
        function()
          return { code = 0, stdout = ' M a.lua\n', stderr = '' }
        end,
      }
      answer_queue { 'y', 'n' }

      session_handler.delete(SLUG)

      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)
      assert.equals(2, #state.inputs)
      assert.equals(
        (
          'review.nvim: worktree %s に未コミットの変更があります。削除して閉じますか？ '
          .. '(git worktree remove --force — ディスクの編集は破棄されます) [y/N]: '
        ):format(wt_path()),
        state.inputs[2].prompt
      )
    end
  )

  it(
    'remove 失敗 (dir 残る) は prune + 自前 dir remove_dir で回収してから削除を続行 (孤児 dir を残さない)',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      store.save(existing_stub {
        worktree = { path = wt, created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean
        git_fail 'fatal: remove boom\n', -- remove 失敗
        git_ok, -- prune ok
      }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      assert.is_true(vim.uv.fs_stat(wt) == nil)
      assert.is_true(vim.uv.fs_stat(json_path()) == nil)
    end
  )
end)

describe('open_file_current の worktree / 削除行 (o)', function()
  use_env()

  it(
    'worktree 記録あり: <worktree>/<path> の実ファイルを開く (git show を呼ばず・編集可)',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      local f = io.open(vim.fs.joinpath(wt, 'a.lua'), 'w')
      f:write 'WT-HEAD-CONTENT\n'
      f:close()
      started_with_worktree()
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      local win = vim.fn.win_findbuf(sb)[1]
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      install_git {} -- 追加の git 呼び出しは即エラー

      -- sidebar o の RHS (keymap) を実行 = 押下と同一経路
      local rhs
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(sb, 'n')) do
        if m.lhs == 'o' then
          rhs = m.rhs
        end
      end
      vim.cmd((rhs:gsub('<CR>$', '')))

      local fbuf = vim.fn.bufnr(vim.fs.joinpath(wt, 'a.lua'))
      assert.not_equals(-1, fbuf)
      assert.same({ 'WT-HEAD-CONTENT' }, vim.api.nvim_buf_get_lines(fbuf, 0, -1, false))
      assert.equals(false, vim.bo[fbuf].readonly)
      assert.equals('a.lua', vim.b[fbuf].review_meta.path)
    end
  )

  it(
    'worktree 記録なし: 従来通り git show read-only (作成判断 skip 経路の o)',
    function()
      start_done('main', 'feature')
      install_git {
        function()
          return { code = 0, stdout = 'shown\n', stderr = '' }
        end,
      }
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      local win = vim.fn.win_findbuf(sb)[1]
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })

      session_handler.open_file_current()

      assert.same({ 'git', 'show', 'feature:a.lua' }, state.git_calls[1])
    end
  )

  it(
    'diff の削除行上で o: コンテキストへ寄せず WARN (fileview を開かない・git を呼ばない)',
    function()
      local RAW_DEL = table.concat({
        'diff --git a/a.lua b/a.lua',
        'index 1111111..2222222 100644',
        '--- a/a.lua',
        '+++ b/a.lua',
        '@@ -1,2 +1,2 @@',
        ' line1',
        '-gone',
        '+new',
        '',
      }, '\n')
      install_git {
        top_ok,
        function()
          return diff_ok(RAW_DEL)
        end,
        JUDGE_SKIP[1],
        JUDGE_SKIP[2],
        JUDGE_SKIP[3],
      }
      session_handler.start { base = 'main', head = 'feature' }

      local diff_buf = vim.fn.bufnr(DIFF_A_NAME)
      local win = vim.fn.win_findbuf(diff_buf)[1]
      vim.api.nvim_set_current_win(win)
      local del_row
      for i, line in ipairs(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)) do
        if line:sub(1, 1) == '-' then
          del_row = i
          break
        end
      end
      assert.is_true(del_row ~= nil)
      vim.api.nvim_win_set_cursor(win, { del_row, 0 })
      install_git {}

      session_handler.open_file_current()

      assert.same({
        msg = 'review.nvim: 削除行の上のためファイルを開けません (new 側に該当行がありません)',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.equals(-1, vim.fn.bufnr 'review://file/main--feature/a.lua')
    end
  )
end)
