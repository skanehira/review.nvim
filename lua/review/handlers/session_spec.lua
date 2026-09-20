-- handlers/session: セッション開始 / 終了 / 削除と active 排他 (INV-1)、専有 tab
-- 3 窓 UI open / panel 操作 / <Tab> <S-Tab> [F ]F / viewed / tab 消滅経路の save
-- トリガ (INV-4)、
-- head 解決フロー、pr worktree の作成・掃除・直列化 (pr-worktree.md)、絞り込み。
-- git 注入スタブ (git/cli_spec と同期 on_exit パターン) で開始〜窓張付を同期駆動し、
-- save は paths._set_data_dir 注入の tmpdir へ実ファイルを書いて検証する (INV-4 =
-- ディスク判定)。head 実ファイル窓の経路 (:edit 相当) はディスク実在が前提なので
-- repo を実ファイル付きで用意する (旧 unified 自发描画からの設計変更、diff-review.md)。
local cli = require 'review.git.cli'
local config = require 'review.config'
local paths = require 'review.store.paths'
local commentmarks = require 'review.ui.commentmarks'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_windows = require 'review.ui.windows'

local SLUG = 'main--feature'
local SIDEBAR_NAME = 'review://sidebar/' .. SLUG

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

-- c.lua 削除 + bin.dat binary を含む差分 (窓張り分けの分岐テスト用)。
local RAW_DIFF_DEL_BIN = table.concat({
  'diff --git a/bin.dat b/bin.dat',
  'index 111..222 100644',
  'Binary files a/bin.dat and b/bin.dat differ',
  'diff --git a/c.lua b/c.lua',
  'deleted file mode 100644',
  'index 333..000',
  '--- a/c.lua',
  '+++ /dev/null',
  '@@ -1,2 +0,0 @@',
  '-line1',
  '-line2',
  '',
}, '\n')

local state = {}

-- cli._set_system 注入: 実行順に responses[idx] を同期 for on_exit を呼ぶ。
-- state.git_opts[idx] には vim.system opts を並列記録し、cwd 契約を pin できるように
-- する。show は既定応答 (base / 縮退 head scratch 充填) を用意し、open_file 由来の
-- git show が応答不足で error にならないようにする (明示列挙も可能)。
local function install_git(responses)
  state.git_calls = {}
  state.git_opts = {}
  cli._set_system(function(cmd, opts, on_exit)
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    state.git_opts[idx] = opts
    if responses[idx] ~= nil then
      on_exit(responses[idx](cmd, opts))
      return
    end
    if cmd[2] == 'show' then
      on_exit { code = 0, stdout = 'base content\n', stderr = '' }
      return
    end
    error('git stub: 想定外の追加実行 ' .. table.concat(cmd, ' '), 0)
  end)
  cli._set_executable(function()
    return 1
  end)
end

-- install_git の worktree remove 非同期版。'git worktree remove' に限って
-- on_exit を state.deferred に捕捉して呼ばない (実 vim.system は非同期。
-- install_git の同期 on_exit では区別できない「remove 完了前/後」の順序を pin する)。
-- responses の remove のスロットは手前へ返るため読まれない (placeholder で可)。
local function install_git_deferred_remove(responses)
  state.git_calls = {}
  state.git_opts = {}
  state.deferred = nil
  cli._set_system(function(cmd, opts, on_exit)
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    state.git_opts[idx] = opts
    if cmd[2] == 'worktree' and cmd[3] == 'remove' then
      state.deferred = on_exit
      return
    end
    if responses[idx] ~= nil then
      on_exit(responses[idx](cmd, opts))
      return
    end
    if cmd[2] == 'show' then
      on_exit { code = 0, stdout = 'base content\n', stderr = '' }
      return
    end
    error('git stub: 想定外の追加実行 ' .. table.concat(cmd, ' '), 0)
  end)
  cli._set_executable(function()
    return 1
  end)
end

local top_ok = function()
  return { code = 0, stdout = state.repo .. '\n', stderr = '' }
end

local diff_ok = function(stdout)
  return { code = 0, stdout = stdout, stderr = '' }
end

local function load_saved(id)
  return store.load(state.repo, id or SLUG).data
end

local function json_path(id)
  return paths.session_file(state.repo, id or SLUG)
end

local function existing_stub(overrides)
  local s = {
    version = 1,
    id = SLUG,
    repo = state.repo,
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

-- paths.worktree_path は注入済み data dir を使うので require 時でなく呼ぶ時に計算。
local function wt_path(slug)
  return paths.worktree_path(state.repo, slug or SLUG)
end

local function git_fail(msg)
  return function()
    return { code = 255, stdout = '', stderr = msg }
  end
end

local function add_cmd(ref, slug)
  return { 'git', 'worktree', 'add', '--detach', wt_path(slug), ref or 'feature' }
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

local function has_call(prefix)
  for _, cmd in ipairs(state.git_calls) do
    if table.concat(cmd, ' '):sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function has_worktree_call()
  for _, cmd in ipairs(state.git_calls) do
    if cmd[2] == 'worktree' then
      return true
    end
  end
  return false
end

-- file panel (既定 tree) の行はヘッダで揺れるので、entry 写像で行を探す
-- (行番号ハードコードは tree/list 切替・ヘッダ仕様に结合しすぎ、焦点がぼやける)。
local function panel_row_for_buf(buf, kind, path)
  local filepanel = require 'review.ui.filepanel'
  for row = 1, vim.api.nvim_buf_line_count(buf) do
    local entry = filepanel.row_entry(buf, row)
    if entry ~= nil and entry.kind == kind and entry.path == path then
      return row
    end
  end
  return nil
end

local function panel_row_for(kind, path)
  return panel_row_for_buf(vim.api.nvim_win_get_buf(ui_windows.win 'panel'), kind, path)
end

-- 現在開いているファイルを panel カーソルの entry 写像から取る (deleted 等の
-- 告知 scratch では head 窓 buf 名が前のファイルのまま残るため、head_buf_name
-- ではなく移動系の契約である panel 追従から見る)。
local function panel_current_path()
  local pw = ui_windows.win 'panel'
  local buf = vim.api.nvim_win_get_buf(pw)
  local entry = require('review.ui.filepanel').row_entry(buf, vim.api.nvim_win_get_cursor(pw)[1])
  return entry ~= nil and entry.path or nil
end

local function focus_panel_file(needle)
  local pw = ui_windows.win 'panel'
  local row = panel_row_for_buf(vim.api.nvim_win_get_buf(pw), 'file', needle)
  assert.is_not_nil(row, 'panel 行が見つからない: ' .. needle)
  vim.api.nvim_set_current_win(pw)
  vim.api.nvim_win_set_cursor(pw, { row, 0 })
end

-- plenary busted は describe 外のフックを持たないため helper 経由で登録する。
-- vim 組み込み関数はプロセス単一なので real 参照は require 時に 1 回捕捉する
-- (before_each ごとに見ると spy が入れ子になり after_each の復旧先が壊れる)。
local REAL_NOTIFY = vim.notify
local REAL_INPUT = vim.ui.input

local function review_tab()
  local st = ui_windows.state()
  return st and st.tab or nil
end

local function head_buf_name()
  local w = ui_windows.win 'head'
  return w ~= nil and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) or nil
end

local function base_buf_name()
  local w = ui_windows.win 'base'
  return w ~= nil and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) or nil
end

-- active セッションへコメントを 1 件注入し commit_comment_change (INV-4 save +
-- 表示再構成) まで通す (handlers/comments の UI 往復を待たない最小注入。
-- file / line は開始時 head 実ファイル a.lua の解ける位置)。
local function inject_comment(body, file, line)
  local sess = session_handler.active()
  sess.comments[#sess.comments + 1] = {
    id = 'c' .. (#sess.comments + 1),
    file = file or 'a.lua',
    line = line or 2,
    end_line = line or 2,
    body = body,
    anchor = { before = 'line1', line = 'line2', after = vim.NIL },
    state = 'active',
    created_at = 100,
  }
  session_handler.commit_comment_change()
end

local function inject_comment_at(line, body)
  inject_comment(body, 'a.lua', line)
end

-- 位置を解けない outdated (state=outdated 確定) を 1 件注入し commit_comment_change
-- (save + 表示再構成) まで通す。集約先 head 窓の無いファイル (告知 / 差分消失) の
-- panel winbar ⚠N 検証用 (persistence-restore「anchor 検証」)。
local function inject_outdated(body, file)
  local sess = session_handler.active()
  sess.comments[#sess.comments + 1] = {
    id = 'c' .. (#sess.comments + 1),
    file = file,
    line = 2,
    end_line = 2,
    body = body,
    anchor = { before = vim.NIL, line = 'ghost text', after = vim.NIL },
    state = 'outdated',
    created_at = 100,
  }
  session_handler.commit_comment_change()
end

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, inputs = {}, input_answer = 'y' }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    -- head 実ファイル窓の経路 (:edit 相当) はディスク実在が前提なので repo を作る
    local raw = vim.fs.joinpath(state.dir, 'repo')
    vim.fn.mkdir(raw, 'p')
    for _, n in ipairs { 'a.lua', 'b.lua', 'c.lua', 'bin.dat' } do
      local f = io.open(vim.fs.joinpath(raw, n), 'w')
      f:write 'line1\nline2\n'
      f:close()
    end
    state.repo = vim.uv.fs_realpath(raw) or raw
    state.cwd0 = vim.uv.cwd()
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
    -- review://* とレビュー tab は nvim プロセス共有。前テスト残りを掃除して
    -- 隔離 tab を現在の tab にする (同名再利用の混線防止)。
    if ui_windows.state() ~= nil then
      ui_windows.close()
    end
    ui_windows.reset()
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        pcall(vim.cmd, 'tabclose!')
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
  end)
  after_each(function()
    if ui_windows.state() ~= nil then
      ui_windows.close()
    end
    ui_windows.reset()
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        pcall(vim.cmd, 'tabclose!')
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
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
    -- 555 化された残骸 dir を含めて掃除できるよう権限を戻す (chmod テスト側でも
    -- 戻すが、失敗経路の取りこぼし対策)
    pcall(vim.fn.system, { 'chmod', '-R', '755', state.dir })
    vim.fn.delete(state.dir, 'rf')
  end)
end

-- head / base 解決系の共通応答部品
local SAME_SHA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
local OTHER_SHA = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
local RP_HEAD_MATCH = {
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
}
local RP_HEAD_MISMATCH = {
  function()
    return { code = 0, stdout = SAME_SHA .. '\n', stderr = '' }
  end,
  function()
    return { code = 0, stdout = OTHER_SHA .. '\n', stderr = '' }
  end,
}

local git_ok = function()
  return { code = 0, stdout = '', stderr = '' }
end
local showref_ok = function()
  return { code = 0, stdout = '', stderr = '' }
end
local showref_miss = function()
  return { code = 1, stdout = '', stderr = '' }
end
local status_clean = function()
  return { code = 0, stdout = '', stderr = '' }
end
local status_dirty = function()
  return { code = 0, stdout = ' M a.lua\n', stderr = '' }
end

-- 開始を完結させる (head == 現在のチェックアウト / 先頭ファイル a.lua の
-- base = git show 充填まで)。
local function start_done(base, head)
  install_git {
    top_ok,
    RP_HEAD_MATCH[1],
    RP_HEAD_MATCH[2],
    function()
      return diff_ok(RAW_DIFF_A_B)
    end,
    function(cmd)
      assert.same({ 'git', 'show', 'main:a.lua' }, cmd)
      return { code = 0, stdout = 'line1\nline2\n', stderr = '' }
    end,
  }
  return session_handler.start { base = base, head = head }
end

-- worktree 作成判断は mode=pr のみ。pr 開始は add/再利用 -> diff (cwd=worktree、
-- 単引数) の順 (pr-worktree.md「PR 解決」3)。handlers/pr と同じ入口 (session.begin)。
local function begin_pr(responses, opts)
  install_git(responses)
  return session_handler.begin {
    repo = state.repo,
    id = (opts and opts.id) or SLUG,
    mode = 'pr',
    base = 'main',
    head = (opts and opts.head) or 'feature',
  }
end

-- worktree 作成済み (記録 {path=wt_path(), created_by_us=true}) のセッションを開始。
local function started_with_worktree()
  begin_pr {
    git_ok, -- worktree add (stub なので dir は作られない: dir 前提の検証は各自 mkdir)
    function()
      return diff_ok(RAW_DIFF_A_B)
    end,
  }
end

describe('session.start 開始フロー (専有 tab 3 窓)', function()
  use_env()

  it(
    'diff -> save -> 専有 tab 3 窓 (panel 左 / base / head 実ファイル) -> active 化',
    function()
      local res = start_done('main', 'feature')

      assert.equals(true, res.ok)
      assert.same({ 'git', 'rev-parse', '--show-toplevel' }, state.git_calls[1])
      -- head==HEAD 一致 (通常経路) は作業ツリー基準の単引数形
      assert.same({ 'git', 'rev-parse', '--verify', 'feature' }, state.git_calls[2])
      assert.same({ 'git', 'rev-parse', '--verify', 'HEAD' }, state.git_calls[3])
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[4])
      -- 一覧先頭ファイルの open_file = 移動系の唯一経路 (base = git show 充填)
      assert.same({ 'git', 'show', 'main:a.lua' }, state.git_calls[5])
      assert.equals(state.repo, state.git_opts[5].cwd)

      assert.same({
        version = 1,
        id = SLUG,
        repo = state.repo,
        mode = 'branch',
        base = 'main',
        head = 'feature',
        pr = vim.NIL,
        worktree = vim.NIL,
        status = 'open',
        -- files entry は一覧解決時 viewed=false で作られるが、open 効果では付かない
        -- (レビュー完了マーク = panel の x トグルのみ / diff-review「file panel」)
        files = { ['a.lua'] = { viewed = false }, ['b.lua'] = { viewed = false } },
        comments = {},
        created_at = 4321,
        updated_at = 4321,
      }, load_saved())

      local tab = review_tab()
      assert.is_true(tab ~= nil and vim.api.nvim_tabpage_is_valid(tab))
      assert.is_not.equals(state.tab, tab, 'レビューは専有 tabpage で開く')
      assert.equals(1, #vim.api.nvim_tabpage_list_wins(state.tab), 'ユーザー窓を触らない')
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(tab))

      local pos = function(w)
        return vim.fn.win_screenpos(w)[2]
      end
      assert.is_true(pos(ui_windows.win 'panel') < pos(ui_windows.win 'base'))
      assert.is_true(pos(ui_windows.win 'base') < pos(ui_windows.win 'head'))

      assert.equals(state.repo .. '/a.lua', head_buf_name())
      assert.equals('review://base/' .. SLUG .. '/a.lua', base_buf_name())
      -- base 窓 = git show <base>:<path> 充填・filetype detect (窓の中身表)
      local base_buf = vim.fn.bufnr('review://base/' .. SLUG .. '/a.lua')
      assert.same({ 'line1', 'line2' }, vim.api.nvim_buf_get_lines(base_buf, 0, -1, false))
      assert.equals('lua', vim.bo[base_buf].filetype)
      -- head 実ファイル窓 = 編集可
      local hw = ui_windows.win 'head'
      assert.equals(true, vim.bo[vim.api.nvim_win_get_buf(hw)].modifiable)
      -- 開通 focus は head 窓 (直後の c/e が効く位置から開始)
      assert.equals(hw, vim.api.nvim_get_current_win())

      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      assert.not_equals(-1, sb)
      -- 開始 open ではマークを付けない (開いただけの行は素のまま)
      assert.same({
        'Changes (2)',
        'Showing changes for: main..作業ツリー',
        'M a.lua +1 -0',
        'A b.lua +1 -0',
      }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
      assert.equals(0, #state.notifications)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    '開通時にレビュー tab を repo へ tcd する (ユーザー tab には漏れない)',
    function()
      start_done('main', 'feature')
      assert.equals(state.repo, vim.fn.getcwd(-1, 0))
      vim.api.nvim_set_current_tabpage(state.tab)
      assert.equals(state.cwd0, vim.fn.getcwd(-1, 0))
    end
  )

  it('head/base 窓の opts (窓 diff / scrollbind / cursorbind / fold / wrap=off)', function()
    start_done('main', 'feature')
    for _, role in ipairs { 'base', 'head' } do
      local w = ui_windows.win(role)
      assert.equals(true, vim.wo[w].diff)
      assert.equals(true, vim.wo[w].scrollbind)
      assert.equals(true, vim.wo[w].cursorbind)
      assert.equals('diff', vim.wo[w].foldmethod)
      assert.equals(false, vim.wo[w].wrap)
    end
  end)

  it('panel 窓幅は config.panel_width (既定 35) + winfixwidth', function()
    start_done('main', 'feature')
    local pw = ui_windows.win 'panel'
    assert.equals(35, vim.api.nvim_win_get_width(pw))
    assert.equals(true, vim.wo[pw].winfixwidth)
  end)

  it('splitright が false でも panel 左 / base / head 右', function()
    vim.o.splitright = false
    start_done('main', 'feature')
    local pos = function(w)
      return vim.fn.win_screenpos(w)[2]
    end
    assert.is_true(pos(ui_windows.win 'panel') < pos(ui_windows.win 'base'))
    assert.is_true(pos(ui_windows.win 'base') < pos(ui_windows.win 'head'))
  end)

  it('splitright が true でも panel 左 / base / head 右', function()
    vim.o.splitright = true
    start_done('main', 'feature')
    local pos = function(w)
      return vim.fn.win_screenpos(w)[2]
    end
    assert.is_true(pos(ui_windows.win 'panel') < pos(ui_windows.win 'base'))
    assert.is_true(pos(ui_windows.win 'base') < pos(ui_windows.win 'head'))
  end)

  it(
    '開通時に chrome が効く (global winbar 式 / 窓 number off / w:review_winbar)',
    function()
      vim.o.winbar = ''
      vim.o.number = true -- レビュー開始直前まで番号表示が有効な環境から開始する
      start_done('main', 'feature')
      local hw, bw, pw = ui_windows.win 'head', ui_windows.win 'base', ui_windows.win 'panel'
      assert.equals('main..feature · a.lua · +1 -0 · 0 comments', vim.w[hw].review_winbar)
      assert.equals('base · a.lua (git show)', vim.w[bw].review_winbar)
      assert.equals('main..feature · 2 files · 0 comments', vim.w[pw].review_winbar)
      assert.equals('%{get(w:,"review_winbar","")}', vim.o.winbar)
      -- b: 変数は実ファイル窓経由でユーザー窓へ漏れるため使わない (chrome 決定)
      assert.is_nil(vim.b[vim.fn.bufnr(SIDEBAR_NAME)].review_winbar)
      assert.equals(false, vim.api.nvim_get_option_value('number', { win = hw }))
      assert.equals(false, vim.api.nvim_get_option_value('number', { win = pw }))
      -- ユーザー tab の窓は number のまま = 窓ローカル操作の保証
      vim.api.nvim_set_current_tabpage(state.tab)
      assert.equals(
        true,
        vim.api.nvim_get_option_value(
          'number',
          { win = vim.api.nvim_tabpage_list_wins(state.tab)[1] }
        )
      )
      vim.o.winbar = ''
    end
  )

  it(
    'ref 解決不能 (diff exit 128) は WARN 通知で UI を開かず save もしない',
    function()
      install_git {
        top_ok,
        -- rev-parse <head> 失敗 (短絡) -> 縮退 2 引数形の diff 本体が E_REF を出す
        function()
          return { code = 128, stdout = '', stderr = "fatal: bad revision 'nope'\n" }
        end,
        function()
          -- 実 git と同じ shape (fatal 主行 + usage 続き) で翻訳経路を通す
          return {
            code = 128,
            stdout = '',
            stderr = "fatal: bad revision 'nope'\nusage: git diff [<options>]\n",
          }
        end,
      }
      -- git を伴う失敗は結果型では返さず notify で返す (DESIGN.md「API 一覧」非同期契約)。
      session_handler.start { base = 'main', head = 'nope' }

      -- 存在しない ref に switch 提案も縮退 INFO も出さない (提案対象は解決可能な
      -- ローカルブランチだけ — INV-3)。rev-parse <head> 失敗で short-circuit ->
      -- 縮退 2 引数形の diff 本体が E_REF を出す。
      assert.same({ 'git', 'rev-parse', '--verify', 'nope' }, state.git_calls[2])
      assert.same({ 'git', 'diff', 'main', 'nope' }, state.git_calls[3])
      assert.equals(0, #state.inputs)
      -- 生 stderr 丸出しでなく「名前 + 次の行動」を伝える (UX review F4)
      assert.same({
        msg = "review.nvim: レビュー対象 ref が解決できません: 'nope'。存在するブランチ/コミットを"
          .. '指定してください (start の base/head 引数は <Tab> で補完できます)',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.not_equals(nil, state.notifications[1].msg:find("'nope'", 1, true))
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
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok ''
        end,
      }
      local res = session_handler.start { base = 'main', head = 'feature' }

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
    'head 省略は rev-parse --abbrev-ref HEAD を自動採用・保存する (入力 UI を出さない)',
    function()
      install_git {
        top_ok,
        function()
          return { code = 0, stdout = 'feature\n', stderr = '' }
        end,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      local res = session_handler.start { base = 'main' }

      assert.equals(true, res.ok)
      assert.same({ 'git', 'rev-parse', '--abbrev-ref', 'HEAD' }, state.git_calls[2])
      assert.equals('feature', load_saved().head)
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[5])
      assert.equals(0, #state.inputs)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    'detached HEAD では head に literal "HEAD" を保存して通常経路で開始する',
    function()
      install_git {
        top_ok,
        function()
          return { code = 0, stdout = 'HEAD\n', stderr = '' }
        end,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main' }

      assert.equals('HEAD', load_saved('main--HEAD').head)
      assert.equals('main--HEAD', session_handler.active().id)
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[5])
      assert.equals(0, #state.inputs)
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

-- ---------------------------------------------------------------------------
-- head / base 窓の中身 (diff-review 表)。scratch 縮退 / 削除 / binary の張り分け。
-- ---------------------------------------------------------------------------

describe('head / base 窓の中身分岐 (窓張り分け表)', function()
  use_env()

  it(
    'scratch 縮退 (switch 拒否): 両窓 scratch + head 窓は git show <head>:<path> 充填',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals('review://base/' .. SLUG .. '/a.lua', base_buf_name())
      assert.equals('review://head/' .. SLUG .. '/a.lua', head_buf_name())
      local head_buf = vim.fn.bufnr('review://head/' .. SLUG .. '/a.lua')
      assert.same({ 'git', 'show', 'feature:a.lua' }, state.git_calls[8])
      assert.equals(state.repo, state.git_opts[8].cwd)
      assert.same({ 'base content' }, vim.api.nvim_buf_get_lines(head_buf, 0, -1, false))
      assert.equals('lua', vim.bo[head_buf].filetype)
      assert.equals('hide', vim.bo[head_buf].bufhidden)
    end
  )

  it(
    '削除ファイル: head 窓は告知 scratch + 両窓 diffoff、base 窓は git show',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_DEL_BIN)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }

      -- 一覧先頭 = bin.dat (パス昇順) -> <Tab> で c.lua へ
      assert.equals('review://binary/' .. SLUG .. '/bin.dat', head_buf_name())
      session_handler.next_file() -- c.lua

      assert.equals('review://deleted/' .. SLUG .. '/c.lua', head_buf_name())
      assert.equals('review://base/' .. SLUG .. '/c.lua', base_buf_name())
      local head_buf = vim.fn.bufnr('review://deleted/' .. SLUG .. '/c.lua')
      local lines = vim.api.nvim_buf_get_lines(head_buf, 0, -1, false)
      assert.equals(1, #lines)
      assert.is_true(lines[1]:find('deleted', 1, true) ~= nil)
      -- 削除は告知ペア (head 告知 1 行 / base 旧内容) なので両窓で窓 diff を抜ける
      -- (相手のいない diff ペアを作らない — issue #38)
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
      assert.equals(false, vim.wo[ui_windows.win 'base'].diff)
      -- git show 充填は base 窓のみ (head 実ファイル編集事故を作らない)
      assert.is_true(has_call 'git show main:c.lua')
      assert.is_false(has_call 'git show feature:c.lua')
    end
  )

  it(
    'binary: base/head 同一の告知 scratch を共有し両窓 diffoff・git show 0 件',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_DEL_BIN)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }

      local name = 'review://binary/' .. SLUG .. '/bin.dat'
      assert.equals(name, head_buf_name())
      assert.equals(name, base_buf_name())
      local buf = vim.fn.bufnr(name)
      assert.equals(2, #vim.fn.win_findbuf(buf))
      assert.same({ 'Binary files differ' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.equals(false, vim.wo[ui_windows.win 'base'].diff)
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
      -- 窓 diff に参加しない告知窓なので git show を呼ばない
      assert.is_false(has_call 'git show')
    end
  )

  it(
    '追加ファイル (A): base 窓は review://null scratch (git show を呼ばない)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      session_handler.next_file() -- b.lua (A)

      assert.equals('review://null/' .. SLUG .. '/b.lua', base_buf_name())
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      assert.is_false(has_call 'git show main:b.lua')
    end
  )

  it(
    '追加ファイル (A): base が 0 行 null scratch なので両窓で窓 diff を無効にし、head winbar に new file マークを出す',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      session_handler.next_file() -- b.lua (A)

      assert.equals('review://null/' .. SLUG .. '/b.lua', base_buf_name())
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      -- 追加 (A) は base = 0 行 null scratch とのペアなので窓 diff を張らない
      -- (全行 DiffAdd の塗りつぶしを作らない。M ファイルの窓 diff 有効は別 test が陰性対照)
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
      assert.equals(false, vim.wo[ui_windows.win 'base'].diff)
      -- head winbar は既定要素 (+a -d / N comments) を保ったまま末尾に種別マーク
      -- (base winbar の (new file) と同文言)
      assert.equals(
        'main..feature · b.lua · +1 -0 · 0 comments · new file',
        vim.w[ui_windows.win 'head'].review_winbar
      )
    end
  )

  it(
    'scratch 縮退 + 追加ファイル (A): base は null scratch のまま両窓 diffoff',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'
      session_handler.start { base = 'main', head = 'feature' }
      session_handler.next_file() -- b.lua (A)

      assert.equals('review://null/' .. SLUG .. '/b.lua', base_buf_name())
      assert.equals('review://head/' .. SLUG .. '/b.lua', head_buf_name())
      -- 縮退経路でも追加 (A) は 0 行 null scratch とのペアなので窓 diff を張らない
      assert.equals(false, vim.wo[ui_windows.win 'head'].diff)
      assert.equals(false, vim.wo[ui_windows.win 'base'].diff)
    end
  )

  -- 再利用分岐 (diff-review「head / base 窓の中身» «既にユーザーが開いていれば
  -- 同一バッファを再利用») でも_review キーの張込は必須 (head 窓で c/e/d/y/i/o/q が
  -- 効かないと開始導線が壊れる)。b.lua (未既在 = bufadd 生成側) と対で張込を pin。
  local function gate_installed(buf)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if
        m.lhs == 'c'
        and type(m.rhs) == 'string'
        and m.rhs:find('review.ui.keygate', 1, true) ~= nil
      then
        return true
      end
    end
    return false
  end

  it(
    '開始前に :edit 済みの実ファイル: head 窓で再利用され、再利用側にもレビューキーが張られる',
    function()
      vim.cmd('edit ' .. vim.fn.fnameescape(state.repo .. '/a.lua'))
      start_done('main', 'feature')

      local reused = vim.fn.bufnr(state.repo .. '/a.lua')
      assert.equals(
        reused,
        vim.api.nvim_win_get_buf(ui_windows.win 'head'),
        '既在の実ファイル buf が head 窓で再利用される (窓の中身表)'
      )
      assert.is_true(
        gate_installed(reused),
        '再利用分岐でレビューキーが張られていない (c が head 窓で発火しない)'
      )

      -- 対照: 未既在の b.lua (bufadd 側) も同一の open_file 導線で張られている
      session_handler.next_file()
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      assert.is_true(
        gate_installed(vim.api.nvim_win_get_buf(ui_windows.win 'head')),
        '対照の b.lua にもキーが無く、比較自体が壊れている'
      )
    end
  )

  it(
    '復元時 差分まるごと消滅 + outdated comments: 3 窓を開き「変更なし」placeholder に集約',
    function()
      local existing = existing_stub {
        status = 'open',
        files = { ['a.lua'] = { viewed = true } },
        comments = {
          {
            id = 'c1',
            file = 'a.lua',
            line = 2,
            end_line = 2,
            body = 'ghost',
            anchor = { before = vim.NIL, line = 'gone', after = vim.NIL },
            state = 'outdated',
            created_at = 1,
          },
        },
      }
      install_git { top_ok }
      session_handler.resume_into(existing, {}, vim.NIL, false)

      assert.is_true(review_tab() ~= nil)
      local ph = 'review://base/' .. SLUG .. '/(no-changes)'
      assert.equals(ph, base_buf_name())
      assert.equals(ph, head_buf_name())
      local head_buf = vim.fn.bufnr(ph)
      assert.same({ '変更なし' }, vim.api.nvim_buf_get_lines(head_buf, 0, -1, false))

      local ns = vim.api.nvim_get_namespaces().review_comment
      local above = nil
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, { details = true })) do
        if m[4].virt_lines_above then
          above = m
        end
      end
      assert.is_not_nil(above, 'placeholder の outdated 集約 mark が無い')
      local text = ''
      for _, chunk in ipairs(above[4].virt_lines[1] or {}) do
        text = text .. (type(chunk[1]) == 'table' and chunk[1][1] or chunk[1])
      end
      assert.equals(' 1 outdated (prompt 除外中)', text)
    end
  )

  it(
    '差分消滅開通でも panel 一覧は diff 由来 0 件・files map に消失ファイルを入れない',
    function()
      local existing = existing_stub {
        status = 'open',
        files = { ['a.lua'] = { viewed = true } },
        comments = {
          {
            id = 'c1',
            file = 'a.lua',
            line = 2,
            end_line = 2,
            body = 'ghost',
            anchor = { before = vim.NIL, line = 'gone', after = vim.NIL },
            state = 'outdated',
            created_at = 1,
          },
        },
      }
      install_git { top_ok }
      session_handler.resume_into(existing, {}, vim.NIL, false)

      -- panel 空一覧 (persistence-restore「files=0 の開通は panel 空一覧」)
      local sb = vim.fn.bufnr(SIDEBAR_NAME)
      assert.same({ '' }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
      -- スキーマ: files = 差分に出る全ファイル (消失ファイルの合成行を入れない)
      assert.same({}, load_saved().files)
    end
  )
end)

-- ---------------------------------------------------------------------------
-- panel winbar の outdated 集約先なし ⚠N (diff-review「窓装飾」/ persistence-restore
-- 「anchor 検証」— head 窓さえない outdated の可視化)
-- ---------------------------------------------------------------------------

describe('panel winbar ⚠N (集約先 head 窓の無い outdated)', function()
  use_env()

  it(
    'binary 告知と差分消失ファイルの outdated を panel winbar 末尾 ⚠N に数える',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_DEL_BIN)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      inject_outdated('on binary notice', 'bin.dat')
      inject_outdated('on vanished file', 'gone.lua')

      local pw = ui_windows.win 'panel'
      assert.equals('main..feature · 2 files · 2 comments · ⚠2', vim.w[pw].review_winbar)
    end
  )

  it(
    'head 実窓がある outdated は ⚠N に入れず、head バッファ内の id 接頭辞を warning 色にする',
    function()
      start_done('main', 'feature')
      inject_comment 'resolvable thread'
      local sess = session_handler.active()
      sess.comments[1].state = 'outdated'
      session_handler.commit_comment_change()

      -- ⚠N 対象ではない (head 窓に集約先がある)
      local pw = ui_windows.win 'panel'
      assert.equals('main..feature · 2 files · 1 comment', vim.w[pw].review_winbar)
      -- 件数に ⚠ を付けず、本文先頭の id 接頭辞だけ warning 色にする
      local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
      local ns = vim.api.nvim_get_namespaces().review_comment
      local found = nil
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, { details = true })) do
        local vt = ''
        for _, chunk in ipairs(m[4].virt_text or {}) do
          vt = vt .. (type(chunk[1]) == 'table' and chunk[1][1] or chunk[1])
        end
        if vt == ' \u{EA6B} 1' then
          found = m
        end
      end
      assert.is_not_nil(found, 'outdated 混在 mark が無い')
      assert.equals('ReviewCommentOutdated', found[4].virt_lines[1][1][2])
    end
  )
end)

-- ---------------------------------------------------------------------------
-- head 解決フロー (diff-review.md「開始」2 / DESIGN 決定表)
-- ---------------------------------------------------------------------------

local SWITCH_OFFER = 'review.nvim: head feature は現在のチェックアウトと別のコミットです。'
  .. 'git switch で feature に切り替えてレビューしますか? [y/N]: '

local DEGRADED_MSG = {
  msg = 'review.nvim: head の状態はチェックアウトされていません。読み取り専用 scratch でレビューします',
  level = vim.log.levels.INFO,
}

describe('head 解決フロー (branch: diff-review「開始」2)', function()
  use_env()

  it(
    'rev-parse <head> と HEAD が一致 -> 通常経路 (switch 提案なし・status 照会なし・単引数 diff)',
    function()
      start_done('main', 'feature')

      assert.equals(5, #state.git_calls)
      assert.equals(0, #state.inputs)
      assert.equals(0, #state.notifications)
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[4])
      assert.equals(vim.NIL, load_saved().worktree)
    end
  )

  it(
    '不一致 + ローカルブランチ + clean + 承諾 -> git switch 後に通常経路の単引数 diff (INFO なし)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        git_ok, -- switch ok
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(1, #state.inputs)
      assert.equals(SWITCH_OFFER, state.inputs[1].prompt)
      assert.same({ 'git', 'switch', 'feature' }, state.git_calls[6])
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[7]) -- switch 後 = 作業ツリー基準
      assert.equals(0, #state.notifications)
      assert.equals(SLUG, session_handler.active().id)
      -- switch 後は実ファイル窓 (縮退しない)
      assert.equals(state.repo .. '/a.lua', head_buf_name())
    end
  )

  it(
    '承諾後 switch 失敗 -> WARN + scratch 縮退 INFO、diff は <base> <head> 2 引数形で開始は続く',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return {
            code = 128,
            stdout = '',
            stderr = 'fatal: your local changes would be overwritten by checkout\n',
          }
        end,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.same({
        msg = 'review.nvim: git switch に失敗しました。読み取り専用 scratch でレビューします: '
          .. 'fatal: your local changes would be overwritten by checkout',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      assert.same(DEGRADED_MSG, state.notifications[2])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[7])
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    'switch 提案を拒否 -> 縮退 INFO + 2 引数 diff で開始 (git switch は一切走らない)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_clean,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(1, #state.inputs)
      assert.is_false(has_call 'git switch')
      assert.same(DEGRADED_MSG, state.notifications[1])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[6])
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    '不一致 + dirty な作業ツリー -> 提案を出さない (INV-3) ので縮退 INFO + 2 引数 diff',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_dirty,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(0, #state.inputs)
      assert.same(DEGRADED_MSG, state.notifications[1])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[6])
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    '不一致 + 非ローカルブランチ (show-ref 非ヒット) -> status も見ず提案なしで縮退 (tag/sha 相当)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_miss,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.same(
        { 'git', 'show-ref', '--verify', '--quiet', 'refs/heads/feature' },
        state.git_calls[4]
      )
      assert.is_false(has_call 'git status --porcelain')
      assert.equals(0, #state.inputs)
      assert.same(DEGRADED_MSG, state.notifications[1])
      assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[5])
    end
  )

  it('branch は switch 拒否の縮退でも worktree 起動 0 件・記録 nil', function()
    install_git {
      top_ok,
      RP_HEAD_MISMATCH[1],
      RP_HEAD_MISMATCH[2],
      showref_ok,
      status_clean,
      function()
        return diff_ok(RAW_DIFF_A_B)
      end,
    }
    state.input_answer = 'n'

    session_handler.start { base = 'main', head = 'feature' }

    assert.is_false(has_worktree_call())
    assert.equals(vim.NIL, load_saved().worktree)
  end)

  it(
    'branch は作業ツリー dirty でも worktree を作らない (縮退は head 解決フローが担う)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MISMATCH[1],
        RP_HEAD_MISMATCH[2],
        showref_ok,
        status_dirty,
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(vim.NIL, load_saved().worktree)
      assert.is_false(has_worktree_call())
    end
  )

  it(
    '開始時に created_by_us=true 名残を remove で掃除し、セッション記録は nil になる',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      store.save(existing_stub { worktree = { path = wt, created_by_us = true } })
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
        git_ok, -- 掃除: status clean
        git_ok, -- 掃除: remove ok
      }
      state.input_answer = 'y' -- 継承確認

      session_handler.start { base = 'main', head = 'feature' }

      assert.same({ 'git', '-C', wt, 'status', '--porcelain' }, state.git_calls[5])
      assert.same({ 'git', 'worktree', 'remove', wt }, state.git_calls[6])
      assert.equals(vim.NIL, load_saved().worktree)
      assert.equals(SLUG, session_handler.active().id)
    end
  )

  it(
    'created_by_us=false 名残記録は掃除しない (INV-3: 自前分のみ削除)。remove 起動 0 件',
    function()
      local wt = wt_path()
      store.save(existing_stub { worktree = { path = wt, created_by_us = false } })
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'y' -- 継承確認

      session_handler.start { base = 'main', head = 'feature' }

      -- top / RP x2 / diff / (open) show = 5。worktree 掃除 (status/remove) は 0 件
      assert.equals(5, #state.git_calls)
      assert.is_false(has_worktree_call())
      assert.equals(vim.NIL, load_saved().worktree)
    end
  )
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
      local a_row = panel_row_for('file', 'a.lua')
      assert.equals(
        '[✓] M \u{EA6B} a.lua +1 -0',
        vim.api.nvim_buf_get_lines(sb, 0, -1, false)[a_row]
      )
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
    '別 refs 組が active な開始は確認後の save -> close してから新セッション (レビュー tab 張り替え)',
    function()
      start_done('main', 'feature')
      local tab_before = review_tab()

      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
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
      -- 切替は専有 tab を閉じてから新 tab を開く (レビュー tab を増やさない)
      assert.is_false(vim.api.nvim_tabpage_is_valid(tab_before))
      assert.is_true(review_tab() ~= nil)
    end
  )

  it(
    '別 refs 組が active な開始の確認を断ると既存 active がそのまま残る',
    function()
      start_done('main', 'feature')
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
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
    inject_comment 'KEEP ME' -- a.lua (save + 表示再構成まで共通経路)
    -- b.lua だけ x でレビュー完了にトグル (a.lua は開いているが未マークのまま)
    focus_panel_file 'b.lua'
    session_handler.toggle_viewed_current()

    install_git {
      top_ok,
      RP_HEAD_MATCH[1],
      RP_HEAD_MATCH[2],
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
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }

      assert.equals(1, #state.inputs) -- close+継承は 1 回の確認に統合
      assert.equals(
        'review.nvim: active セッション main--hotfix です。閉じて main--feature を継承しますか？'
          .. ' コメント・完了マーク内容も引き継ぎます [y/N]: ',
        state.inputs[1].prompt
      )
      assert.equals(SLUG, session_handler.active().id)
      local reloaded = load_saved()
      assert.equals('open', reloaded.status)
      assert.same(saved.comments, reloaded.comments) -- 上書きされず comments がそのまま
      assert.equals(true, reloaded.files['b.lua'].viewed)
      assert.equals('closed', load_saved('main--hotfix').status)
      -- 継承後も a.lua は未マーク (開封連動が無い契約の回帰 pin) / b のマークは保持
      local a_row = panel_row_for('file', 'a.lua')
      assert.equals(
        'M \u{EA6B} a.lua +1 -0',
        vim.api.nvim_buf_get_lines(vim.fn.bufnr(SIDEBAR_NAME), 0, -1, false)[a_row]
      )
    end
  )

  it(
    'active 下の同一 refs 組継承確認を断ると active / ディスク無変更',
    function()
      prepare_feature_with_comment_then_switch()
      local mtime_before = vim.uv.fs_stat(json_path()).mtime
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'n'

      session_handler.start { base = 'main', head = 'feature' }

      assert.equals('main--hotfix', session_handler.active().id)
      assert.same(mtime_before, vim.uv.fs_stat(json_path()).mtime)
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
      assert.equals('a--b', store.load(state.repo, 'a--b--c').data.base)
    end
  )
end)

describe('session.close / session.delete (q 経路 = close と tab 消滅)', function()
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
    'コメント 0 件: 確認なしで閉じ status=closed / レビュー tab 消滅 / extmark 残骸 0',
    function()
      start_done('main', 'feature')
      inject_comment 'first' -- extmark を張っておく (残骸 0 検証のため)
      local tab = review_tab()
      local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
      local ns = vim.api.nvim_get_namespaces().review_comment
      assert.is_true(#vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}) > 0)

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.equals(4321, load_saved().updated_at)
      assert.is_nil(session_handler.active())
      assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
      assert.is_false(vim.api.nvim_tabpage_is_valid(tab), 'q = レビュー tab を閉じる')
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}))
      -- 実ファイルバッファ (modified を含むユーザー所有物) は消さない
      assert.is_true(vim.api.nvim_buf_is_valid(head_buf))
    end
  )

  it(
    'close は再利用したユーザー既在の実バッファからもレビューキーを除く (残骸 0・バッファ自体は保持)',
    function()
      vim.cmd('edit ' .. vim.fn.fnameescape(state.repo .. '/a.lua'))
      start_done('main', 'feature')
      local reused = vim.api.nvim_win_get_buf(ui_windows.win 'head')
      -- close 直前の正状態 (張込が no-op ならこの assert が落ちる)
      local installed = false
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(reused, 'n')) do
        if
          m.lhs == 'c'
          and type(m.rhs) == 'string'
          and m.rhs:find('review.ui.keygate', 1, true) ~= nil
        then
          installed = true
        end
      end
      assert.is_true(installed, '前提: close 前に張込済みでなければならない')

      session_handler.close()

      assert.is_true(
        vim.api.nvim_buf_is_valid(reused),
        'ユーザー実バッファは消さない'
      )
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(reused, 'n')) do
        assert.is_true(
          type(m.rhs) ~= 'string' or m.rhs:find('review.ui.keygate', 1, true) == nil,
          '残骸: ' .. m.lhs
        )
      end
    end
  )

  it(
    'close_by_key と tabclose の INFO が競合しない (q 経路は tab 消滅 INFO を出さない)',
    function()
      start_done('main', 'feature')
      session_handler.close_by_key()
      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      for _, n in ipairs(state.notifications) do
        assert.is_true(
          n.msg:find('レビュー tab を閉じました', 1, true) == nil,
          'q 経路で tab 消滅 INFO が出た: ' .. n.msg
        )
      end
    end
  )

  it(
    'コメントありの close は確認を要求する (n なら閉じず / y で status=closed)',
    function()
      start_done('main', 'feature')
      inject_comment 'keep'

      state.input_answer = 'n'
      session_handler.close()
      assert.equals('open', load_saved().status)
      assert.equals(SLUG, session_handler.active().id)
      assert.is_true(review_tab() ~= nil)

      state.input_answer = 'y'
      session_handler.close()
      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
    end
  )

  it(
    'ユーザーが :tabclose で閉じる: active 解除・status=open 維持・save・INFO («開き直し可»)',
    function()
      start_done('main', 'feature')
      inject_comment 'tabclosed-keep'
      local review_t = review_tab()

      vim.api.nvim_set_current_tabpage(review_t)
      vim.cmd 'tabclose!'
      vim.wait(300, function()
        return session_handler.active() == nil
      end)

      assert.is_false(vim.api.nvim_tabpage_is_valid(review_t))
      assert.is_nil(session_handler.active())
      local saved = load_saved()
      assert.equals(
        'open',
        saved.status,
        'tab 消滅を close と解釈しない (status=open 維持)'
      )
      assert.equals(1, #saved.comments) -- save 済み (INV-4 + tab 消滅 save)
      local notify = nil
      for _, n in ipairs(state.notifications) do
        if n.msg:find('レビュー tab を閉じました', 1, true) ~= nil then
          notify = n
        end
      end
      assert.is_not_nil(notify, 'tab 消滅 INFO が無い')
      assert.equals(vim.log.levels.INFO, notify.level)
      -- extmark 残骸 0 (張った head 実バッファを明示 clear — 開き直しまで残さない)
      local head_buf = vim.fn.bufnr(state.repo .. '/a.lua')
      local ns = vim.api.nvim_get_namespaces().review_comment
      assert.is_true(vim.api.nvim_buf_is_valid(head_buf))
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}))
    end
  )

  -- 互換 pin (issue #26): v0.10.0 と stable で TabClosed 発火時点の tab handle
  -- 失効タイミングが違う (0.10.0 は is_valid が true のまま発火する)。両バージョンが
  -- ともに満たすべき振る舞いの 3 点セットを 1 つの test に締める。
  it(
    'tab 消滅 → 掃除完走 + windows.state() nil + session status=open 維持'
      .. ' (0.10.0/stable 互換 pin)',
    function()
      start_done('main', 'feature')
      local review_t = review_tab()

      vim.api.nvim_set_current_tabpage(review_t)
      vim.cmd 'tabclose!'
      vim.wait(300, function()
        return ui_windows.state() == nil and session_handler.active() == nil
      end)

      assert.is_true(
        not vim.tbl_contains(vim.api.nvim_list_tabpages(), review_t),
        'review tab が現存している (消滅していない)'
      )
      assert.is_nil(
        ui_windows.state(),
        'tab 消滅後も windows.state が居残りの版がある'
      )
      assert.is_nil(session_handler.active())
      assert.equals('open', load_saved().status, 'tab 消滅を close と解釈しない')
    end
  )

  it(
    'レビュー tab を閉じたまま :Review start (同一 refs) で開き直せる (placeholder でなく実窓)',
    function()
      start_done('main', 'feature')
      vim.api.nvim_set_current_tabpage(review_tab())
      vim.cmd 'tabclose!'
      vim.wait(300, function()
        return session_handler.active() == nil
      end)
      -- 開き直し = 同一 refs 組の保存済み継承 (confirm y)。git は start 相当を再実行
      start_done('main', 'feature')
      assert.equals(SLUG, session_handler.active().id)
      assert.equals(state.repo .. '/a.lua', head_buf_name())
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

describe('panel 操作 (open_file / viewed) と移動系', function()
  use_env()

  local function ex_bufname()
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()))
  end

  it(
    '<CR> open は head/base を張り替えるがレビュー完了マークを付けない',
    function()
      start_done('main', 'feature')
      focus_panel_file 'b.lua'

      session_handler.open_selected_file()

      assert.equals(false, load_saved().files['b.lua'].viewed)
      assert.equals('review://null/' .. SLUG .. '/b.lua', base_buf_name())
      assert.equals(state.repo .. '/b.lua', head_buf_name())
    end
  )

  it(
    '<CR> は focus を panel に維持し、diff 窓と一覧カーソルを開いたファイル行へ揃える',
    function()
      start_done('main', 'feature')
      focus_panel_file 'b.lua'

      session_handler.open_selected_file()

      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      assert.equals(
        panel_row_for('file', 'b.lua'),
        vim.api.nvim_win_get_cursor(ui_windows.win 'panel')[1]
      )
    end
  )

  it(
    '<CR> は窓役割の drift を復旧する (head 窓を閉じていても再建して張る)',
    function()
      start_done('main', 'feature')
      vim.api.nvim_win_close(ui_windows.win 'head', true)
      focus_panel_file 'b.lua'

      session_handler.open_selected_file()

      assert.equals(3, #vim.api.nvim_tabpage_list_wins(review_tab()))
      assert.equals('head', ui_windows.role_of(ui_windows.win 'head'))
      assert.equals(state.repo .. '/b.lua', head_buf_name())
    end
  )

  it('head 窓 drift (他 buf を表示) でも open_file 再張付で復旧する', function()
    start_done('main', 'feature')
    vim.api.nvim_win_set_buf(ui_windows.win 'head', vim.api.nvim_create_buf(false, true))
    assert.is_nil(ui_windows.role_of(ui_windows.win 'head'))
    focus_panel_file 'b.lua'

    session_handler.open_selected_file()

    assert.equals(state.repo .. '/b.lua', head_buf_name())
    assert.equals('head', ui_windows.role_of(ui_windows.win 'head'))
  end)

  it('<Tab> で次ファイルへ open_file (マークは触らない / focus は head)', function()
    start_done('main', 'feature') -- 先頭 a.lua
    session_handler.next_file()

    assert.equals(state.repo .. '/b.lua', ex_bufname())
    assert.equals(false, load_saved().files['b.lua'].viewed)
  end)

  it('<S-Tab> で前ファイルに戻る (base git show 再充填)', function()
    start_done('main', 'feature')
    session_handler.next_file()
    session_handler.prev_file()

    assert.equals(state.repo .. '/a.lua', ex_bufname())
    assert.is_true(has_call 'git show main:a.lua')
  end)

  it('端では <Tab>/<S-Tab> は無動作 (最後の次へを進まない)', function()
    start_done('main', 'feature')
    session_handler.next_file() -- b
    session_handler.next_file() -- 端 = noop
    assert.equals(state.repo .. '/b.lua', ex_bufname())
    session_handler.prev_file()
    session_handler.prev_file() -- 端 = noop
    assert.equals(state.repo .. '/a.lua', ex_bufname())
  end)

  it(
    '[F で最初 / ]F で最後のファイルを open_file (端での再押下も同一対象)',
    function()
      start_done('main', 'feature') -- 先頭 a.lua
      session_handler.next_file() -- b.lua
      session_handler.first_file()
      assert.equals(state.repo .. '/a.lua', ex_bufname())
      assert.equals(ui_windows.win 'head', vim.api.nvim_get_current_win())
      session_handler.last_file()
      assert.equals(state.repo .. '/b.lua', ex_bufname())
      session_handler.last_file() -- 端の再押下 = 同一対象を維持 (無動作)
      assert.equals(state.repo .. '/b.lua', ex_bufname())
    end
  )

  it(
    '[F/]F open でマークは連動せず、x トグルが付け外しして save する',
    function()
      start_done('main', 'feature') -- 先頭 a.lua open
      assert.equals(false, load_saved().files['a.lua'].viewed)
      session_handler.last_file() -- b.lua
      assert.equals(false, load_saved().files['b.lua'].viewed)

      focus_panel_file 'b.lua'
      session_handler.toggle_viewed_current()
      assert.equals(true, load_saved().files['b.lua'].viewed) -- 付与と直後 save (INV-4)
      session_handler.toggle_viewed_current()
      assert.equals(false, load_saved().files['b.lua'].viewed) -- 外しも同様
    end
  )

  it(
    'S / <leader>e (focus_sidebar) で focus が panel へ移り、閉窓からは左再建',
    function()
      start_done('main', 'feature')
      session_handler.focus_sidebar()
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))

      vim.api.nvim_win_close(ui_windows.win 'panel', true)
      session_handler.focus_sidebar()
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(review_tab()))
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
      assert.is_true(
        vim.fn.win_screenpos(ui_windows.win 'panel')[2]
          < vim.fn.win_screenpos(ui_windows.win 'base')[2]
      )
    end
  )

  it(
    '<leader>b (toggle_panel): panel 窓を閉じる / 再度 open でレビュー窓を残す',
    function()
      start_done('main', 'feature')
      session_handler.toggle_panel() -- hide
      assert.is_nil(ui_windows.win 'panel')
      assert.is_true(vim.api.nvim_win_is_valid(ui_windows.win 'head'))
      assert.is_true(vim.api.nvim_win_is_valid(ui_windows.win 'base'))

      session_handler.toggle_panel() -- show (再建 + focus)
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(review_tab()))
      -- 再建 panel は一覧が載っている (開いている files)
      local sb = vim.api.nvim_win_get_buf(ui_windows.win 'panel')
      assert.same({
        'Changes (2)',
        'Showing changes for: main..作業ツリー',
        'M a.lua +1 -0',
        'A b.lua +1 -0',
      }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
    end
  )

  it(
    'x でマークを付け外し -> 直後に save (開始 open は未マークから開始)',
    function()
      start_done('main', 'feature') -- a.lua 開始 open (viewed=false)
      focus_panel_file 'a.lua'

      session_handler.toggle_viewed_current()
      assert.equals(true, load_saved().files['a.lua'].viewed)

      session_handler.toggle_viewed_current()
      assert.equals(false, load_saved().files['a.lua'].viewed)
    end
  )

  it('x 後に panel 一覧が [✓] 再描画される (付与と解除の両方向)', function()
    start_done('main', 'feature') -- 開封だけでは [✓] が付かない前提
    focus_panel_file 'b.lua'
    session_handler.toggle_viewed_current()

    local sb = vim.api.nvim_win_get_buf(ui_windows.win 'panel')
    assert.same({
      'Changes (2)',
      'Showing changes for: main..作業ツリー',
      'M a.lua +1 -0',
      '[✓] A b.lua +1 -0',
    }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))

    session_handler.toggle_viewed_current() -- 解除方向も再描画される
    assert.same({
      'Changes (2)',
      'Showing changes for: main..作業ツリー',
      'M a.lua +1 -0',
      'A b.lua +1 -0',
    }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
  end)

  it('q (close_by_key) は無確認で閉じ tab 消滅 INFO も出さない', function()
    start_done('main', 'feature')
    local tab = review_tab()

    session_handler.close_by_key()

    assert.equals('closed', load_saved().status)
    assert.is_nil(session_handler.active())
    assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
    assert.equals(0, #state.notifications)
    assert.equals(0, #state.inputs)
  end)
end)

describe('commit_comment_change (INV-4 + extmark 再適用)', function()
  use_env()

  it('save + head extmark 再構成 + head/panel winbar comments 件数', function()
    start_done('main', 'feature')
    inject_comment 'first thread'

    local saved = load_saved()
    assert.equals(1, #saved.comments)
    local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
    local ns = vim.api.nvim_get_namespaces().review_comment
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}))

    local hw = ui_windows.win 'head'
    assert.equals('main..feature · a.lua · +1 -0 · 1 comment', vim.w[hw].review_winbar)
    local pw = ui_windows.win 'panel'
    assert.equals('main..feature · 2 files · 1 comment', vim.w[pw].review_winbar)

    -- 2 件目 (同一行 = 同一 group の extmark は併合のまま件数 2)
    inject_comment_at(2, 'second thread')
    assert.equals(2, #load_saved().comments)
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, {}))
    local details = vim.api.nvim_buf_get_extmarks(head_buf, ns, 0, -1, { details = true })
    local vt = ''
    for _, chunk in ipairs(details[1][4].virt_text or {}) do
      vt = vt .. (type(chunk[1]) == 'table' and chunk[1][1] or chunk[1])
    end
    assert.is_true(vt:find('\u{EA6B} 2', 1, true) ~= nil, vt)
    assert.equals('main..feature · a.lua · +1 -0 · 2 comments', vim.w[hw].review_winbar)
  end)

  it(
    'file panel の行がコメント CRUD 直後に追随する (アイコン表示 -> 消滅)',
    function()
      start_done('main', 'feature')
      local pw = ui_windows.win 'panel'
      local pbuf = vim.api.nvim_win_get_buf(pw)
      local function row_of(path)
        for _, line in ipairs(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)) do
          if line:find(path, 1, true) ~= nil then
            return line
          end
        end
        return nil
      end
      local before = assert(row_of 'a.lua', 'panel に a.lua 行が無い')
      assert.is_nil(
        before:find('\u{EA6B}', 1, true),
        '前提: コメント 0 件でアイコンが出ている'
      )
      inject_comment 'first thread'
      local after = assert(row_of 'a.lua', 'panel に a.lua 行が無い (commit 後)')
      assert.is_true(
        after:find('\u{EA6B}', 1, true) ~= nil,
        'panel 行にコメントアイコンが反映されない'
      )
      -- 削除 (最後の 1 件) でアイコンも消える (同じ render 経路)
      table.remove(session_handler.active().comments, 1)
      session_handler.commit_comment_change()
      local restored = assert(row_of 'a.lua')
      assert.is_nil(
        restored:find('\u{EA6B}', 1, true),
        'panel 行からアイコンが消えない'
      )
    end
  )

  it(
    '告知窓 (binary) を開いている間は save と panel winbar のみ (extmark を張らない)',
    function()
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(RAW_DIFF_DEL_BIN)
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      inject_comment('on-binary', 'bin.dat', 1) -- file=bin.dat のコメントを注入

      local bin_buf = vim.fn.bufnr('review://binary/' .. SLUG .. '/bin.dat')
      local ns = vim.api.nvim_get_namespaces().review_comment
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(bin_buf, ns, 0, -1, {}))
      assert.equals(
        'main..feature · 2 files · 1 comment',
        vim.w[ui_windows.win 'panel'].review_winbar
      )
      assert.equals(1, #load_saved().comments)
    end
  )
end)

-- ---------------------------------------------------------------------------
-- pr worktree (作成判断 / 記録再利用 / 直列化)
-- ---------------------------------------------------------------------------

describe(
  'pr worktree 作成判断 (mode=pr は常時作って差分は worktree 基準)',
  function()
    use_env()

    it(
      'pr: add --detach -> cwd=worktree の単引数 git diff <base> -> created_by_us=true 記録',
      function()
        begin_pr {
          git_ok, -- add
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }

        assert.same(add_cmd(), state.git_calls[1])
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[2])
        -- dir 実在しない (stub add) ため open 充填の show cwd は repo 基準
        assert.same({ 'git', 'show', 'main:a.lua' }, state.git_calls[3])
        assert.equals(state.repo, state.git_opts[3].cwd)
        assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
        assert.equals(0, #state.notifications)
        assert.equals(SLUG, session_handler.active().id)
      end
    )

    it('add 失敗 -> `git worktree prune` 再試行 recover -> diff まで到達', function()
      begin_pr {
        git_fail 'fatal: already registered\n', -- add1
        git_ok, -- prune
        git_ok, -- add2
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }

      assert.same(add_cmd(), state.git_calls[3])
      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[2])
      assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
    end)

    it(
      '作成失敗 (prune でも解消せず) は E_WORKTREE 案内で中断。diff は作成前に走らない (save なし・UI なし)',
      function()
        begin_pr {
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
        assert.is_false(has_call 'git diff')
        assert.is_nil(load_saved())
        assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME))
        assert.is_nil(session_handler.active())
      end
    )

    it(
      '記録済み worktree: dir 実在 + git list 登録あり => add せず再利用 (crash 後再開)',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        -- 再利用する worktree の a.lua を実在させる (head 実ファイル窓の前提)
        local wf = io.open(vim.fs.joinpath(wt, 'a.lua'), 'w')
        wf:write 'WT-HEAD-CONTENT\n'
        wf:close()
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = true },
        })

        begin_pr {
          function()
            return {
              code = 0,
              stdout = 'worktree ' .. state.repo .. '\nworktree ' .. vim.uv.fs_realpath(wt) .. '\n',
              stderr = '',
            }
          end, -- list: 登録あり
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }

        assert.is_false(has_call 'git worktree add')
        assert.same(list_cmd(), state.git_calls[1])
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[2])
        assert.equals(wt, state.git_opts[2].cwd)
        assert.same({ path = wt, created_by_us = true }, load_saved().worktree)
        -- dir 実在 -> head 実ファイルも show 充填も worktree 基準
        -- (bufadd は symlink を解決して buf 名を持つので buffer 名側だけ realpath で
        -- 比較。git へ渡す cwd は記録された worktree path のまま — macOS の
        -- /var -> /private/var 正規化は buf 名側の挙動)
        assert.equals(vim.uv.fs_realpath(vim.fs.joinpath(wt, 'a.lua')), head_buf_name())
        assert.equals(wt, state.git_opts[3].cwd)
      end
    )

    it(
      '記録 true + dir 実在 + 未登録 => add 衝突 -> prune -> 再衝突 -> remove_dir して再 add',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = true },
        })

        begin_pr {
          function()
            return { code = 0, stdout = 'worktree /elsewhere\n', stderr = '' } -- list: 未登録
          end,
          git_fail 'fatal: already registered\n', -- add1
          git_ok, -- prune
          git_fail 'fatal: already registered\n', -- add2 (dir がまだ在る)
          git_ok, -- add3 (remove_dir 後)
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }

        -- remove_dir が自前 dir を実削除した (add3 はスタブ応答なので dir は再生成されない)。
        assert.is_true(vim.uv.fs_stat(wt) == nil)
        -- list, add1, prune, add2, add3, diff, (open) show
        assert.equals(7, #state.git_calls)
        assert.same({ path = wt, created_by_us = true }, load_saved().worktree)
      end
    )

    it(
      '差分 0 ファイルは「変更なし」で開かず、作りたての自前 worktree を掃除して戻る (孤児化防止)',
      function()
        begin_pr {
          git_ok, -- add
          function()
            return diff_ok ''
          end,
          git_ok, -- remove (0 差分掃除)
        }

        assert.same({
          msg = 'review.nvim: 変更なし (main..feature): レビュー対象がありません',
          level = vim.log.levels.INFO,
        }, state.notifications[1])
        assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
        assert.is_nil(load_saved())
        assert.is_nil(session_handler.active())
      end
    )

    -- 0 差分掃除の remove も worktree 登録変更なので直列化契約の対象
    -- (pr-worktree.md「worktree 登録操作の直列化」。「close -> 即 begin」の pin と
    -- 同族で、remove 最中の concurrent add = main--x + main--x1 二重登録の源を
    -- この経路でも reopen しないことを pin する)。
    it(
      '0 差分 remove 最中の begin (pr) は add/diff が lock 待ちで、remove 完了後に再開する',
      function()
        install_git_deferred_remove {
          git_ok, -- add #1
          function()
            return diff_ok ''
          end, -- diff #1: 0 ファイル -> remove (deferred)
          git_ok, -- remove #1 (deferred: placeholder)
          git_ok, -- add #2 (remove 完了後に再開)
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }
        local opts = {
          repo = state.repo,
          id = SLUG,
          mode = 'pr',
          base = 'main',
          head = 'feature',
        }
        session_handler.begin(opts) -- #1: add -> diff 0 -> remove 投入 (未完)

        assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
        assert.is_true(state.deferred ~= nil)

        -- 同一 slug の 2 度目の開始: #1 は 0 差分で save していないので existing
        -- なしで proceed を通り、resolve_worktree で lock を待つ -> git 起動 0 件。
        session_handler.begin(opts)
        assert.equals(3, #state.git_calls)
        assert.is_nil(session_handler.active())

        state.deferred { code = 0, stdout = '', stderr = '' }

        assert.same(add_cmd(), state.git_calls[4])
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[5])
        assert.equals(SLUG, session_handler.active().id)
        assert.same({ path = wt_path(), created_by_us = true }, load_saved().worktree)
      end
    )

    it(
      '記録再利用で 0 差分: remove 成功後、保存 JSON の worktree 記録を nil 化する (実在しない dir を指した記録を残さない)',
      function()
        local wt = wt_path()
        vim.fn.mkdir(wt, 'p')
        store.save(existing_stub {
          mode = 'pr',
          worktree = { path = wt, created_by_us = true },
        })
        install_git {
          function()
            return {
              code = 0,
              stdout = 'worktree ' .. state.repo .. '\nworktree ' .. vim.uv.fs_realpath(wt) .. '\n',
              stderr = '',
            }
          end, -- list 登録あり -> 記録を再利用 (add なし)
          function()
            return diff_ok ''
          end,
          git_ok, -- 0 差分掃除の remove 成功
        }
        state.input_answer = 'y' -- 継承確認

        session_handler.begin {
          repo = state.repo,
          id = SLUG,
          mode = 'pr',
          base = 'main',
          head = 'feature',
        }

        assert.same({ 'git', 'worktree', 'remove', wt }, state.git_calls[3])
        assert.is_nil(session_handler.active())
        -- 開始は開かない = 新規 save はしないが、既存 JSON の整合は保つ
        assert.same(
          existing_stub { mode = 'pr', worktree = vim.NIL, updated_at = 4321 },
          load_saved()
        )
      end
    )
  end
)

describe('close の worktree クリーンアップ (セッション終了 1-4)', function()
  use_env()

  it(
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
    'remove 失敗は WARN + 二段目自己修復 (prune + 自前 dir 削除) で close を完走させる',
    function()
      started_with_worktree()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      install_git {
        git_ok, -- status clean
        function()
          return { code = 128, stdout = '', stderr = 'fatal: remove boom\n' }
        end,
        git_ok, -- prune (二段目)
      }

      session_handler.close()

      assert.equals('closed', load_saved().status)
      assert.is_nil(session_handler.active())
      assert.same({
        msg = 'review.nvim: worktree 掃除に失敗しました (残骸は起動 scan が回収します): fatal: remove boom',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      -- 孤児 dir を残さない (does not point back 系の崩れ登録は prune + dir rm が正攻)
      assert.is_true(vim.uv.fs_stat(wt) == nil)
      assert.equals(1, #state.notifications)
    end
  )

  it(
    'close -> 即 begin (pr) で add は remove 完了待ち (同一 path 直列化 = 二重登録防止)',
    function()
      started_with_worktree()
      -- close(q, 0 件=無確認): status -> remove(deferred)。pr begin(継承y)は
      -- resolve_worktree が最先頭なので lock 待ち = add も diff も remove 完了後。
      install_git_deferred_remove {
        git_ok, -- status (close)
        git_ok, -- remove (deferred: placeholder)
        git_ok, -- add (begin: remove 完了後に再開)
        function()
          return diff_ok(RAW_DIFF_A_B)
        end,
      }
      state.input_answer = 'y'

      session_handler.close_by_key()
      session_handler.begin {
        repo = state.repo,
        id = SLUG,
        mode = 'pr',
        base = 'main',
        head = 'feature',
      }

      for _, c in ipairs(state.git_calls) do
        if c[3] == 'add' or c[2] == 'diff' then
          error(
            'remove 完了前に worktree add / diff が走った (race = main--x + main--x1 二重登録の源)',
            0
          )
        end
      end
      assert.is_true(state.deferred ~= nil)

      state.deferred { code = 0, stdout = '', stderr = '' }

      local has_add = false
      for _, c in ipairs(state.git_calls) do
        if c[3] == 'add' then
          has_add = true
        end
      end
      assert.is_true(has_add, 'remove 完了後も add が再開しない')
      assert.same(add_cmd(), state.git_calls[3])
      assert.same({ 'git', 'diff', 'main' }, state.git_calls[4])
      assert.equals(SLUG, session_handler.active().id)
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

  it('worktree なしセッションの close は git 追加呼び出し 0', function()
    start_done('main', 'feature')
    install_git {}
    session_handler.close()
    assert.equals('closed', load_saved().status)
    assert.equals(0, #state.git_calls)
  end)

  it(
    'INV-3: created_by_us=false 記録のまま close すると worktree に一切触れない',
    function()
      started_with_worktree()
      -- active / disk の記録を非自前へ書き換える (テスト目的の注入)
      local sess = load_saved()
      sess.worktree = { path = wt_path(), created_by_us = false }
      assert.equals(true, store.save(sess).ok)
      session_handler.active().worktree = sess.worktree
      install_git {}

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
    '閉じた作成分残骸 (active なし): status -> remove 掃除 -> 自前 pr ref 削除 -> JSON 削除',
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
      assert.is_true(vim.uv.fs_stat(paths.session_file(state.repo, 'pr-7')) == nil)
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

  describe('head 窓実バッファの扱い', function()
    it(
      'tabclose 後も head 実ファイルバッファの modified 内容は失われない',
      function()
        start_done('main', 'feature')
        inject_comment 'keep-buffer'
        local head_buf = vim.api.nvim_win_get_buf(ui_windows.win 'head')
        vim.api.nvim_buf_set_lines(head_buf, 1, 2, false, { 'USER EDIT' })

        vim.api.nvim_set_current_tabpage(review_tab())
        vim.cmd 'tabclose!'
        vim.wait(300, function()
          return session_handler.active() == nil
        end)

        assert.is_true(vim.api.nvim_buf_is_valid(head_buf))
        assert.equals(true, vim.bo[head_buf].modified)
        assert.same({ 'line1', 'USER EDIT' }, vim.api.nvim_buf_get_lines(head_buf, 0, -1, false))
      end
    )
  end)

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
      install_git_deferred_remove { top_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      -- remove は投入済みで未完了 (state.deferred)。この時点で JSON が消えて
      -- いると、remove 失敗時に孤児 dir を scan が回収できない — pr-worktree.md
      -- 「セッションの削除」手順 1〜3 完了順の pin。
      assert.same({ 'git', 'worktree', 'remove', wt_path() }, state.git_calls[3])
      assert.is_true(state.deferred ~= nil)
      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)

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
      install_git_deferred_remove { top_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)
      state.deferred { code = 255, stdout = '', stderr = 'fatal: remove boom\n' }

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
      -- (root 実行では成り立たない。make test はローカル非 root 前提 — DESIGN.md)。
      vim.fn.system { 'chmod', '555', wt }
      assert.equals(0, vim.v.shell_error)
      install_git_deferred_remove { top_ok, git_ok, git_ok }
      state.input_answer = 'y'

      session_handler.delete(SLUG)
      state.deferred { code = 255, stdout = '', stderr = 'fatal: remove boom\n' }

      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      assert.same({
        msg = 'review.nvim: worktree 掃除に失敗しました (残骸は起動 scan が回収します): fatal: remove boom',
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      local function has_msg(pat)
        for _, n in ipairs(state.notifications) do
          if n.msg:find(pat, 1, true) ~= nil then
            return true
          end
        end
        return false
      end
      assert.is_true(has_msg 'worktree dir を削除できませんでした')
      assert.is_true(has_msg '孤児 worktree dir を消去できませんでした')
      -- JSON を消さない = closed + created_by_us=true の記録が残る (起動 scan 回収可)。
      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)
      assert.same({ path = wt, created_by_us = true }, load_saved().worktree)

      -- after_each の tmpdir 掃除 (delete 'rf') を通すため権限を戻す
      vim.fn.system { 'chmod', '755', wt }
      assert.equals(0, vim.v.shell_error)
    end
  )

  it(
    'INV-3: created_by_us=false 記録の dir は触れない (active なし delete は JSON ファイルのみ削除)',
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
    'active なし残骸が dirty: --force 確認、キャンセルなら delete 中止 (JSON 保持)',
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
    '確認は vim.ui.input (cmdline) で行い、応答後に cmdline をクリアする',
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
      local echoes = {}
      local REAL_ECHO = vim.api.nvim_echo
      vim.api.nvim_echo = function(chunks, history, opts)
        table.insert(echoes, { chunks = chunks, history = history, opts = opts })
        return REAL_ECHO(chunks, history, opts)
      end
      local prompts = {}
      vim.ui.input = function(opts, cb)
        prompts[#prompts + 1] = opts.prompt
        cb 'n' -- キャンセル = delete 中止 (このテストの主眼は入力経路と後始末)
      end
      session_handler.delete(SLUG)
      vim.api.nvim_echo = REAL_ECHO
      assert.equals(1, #prompts, 'vim.ui.input (cmdline) 経由で確認していない')
      -- 応答後に cmdline を空 echo で掃除する契約 (残留した打鍵の混入防止)
      local cleared = false
      for _, e in ipairs(echoes) do
        if #e.chunks == 0 and e.history == false then
          cleared = true
        end
      end
      assert.is_true(cleared, '応答後に cmdline クリア (空 echo) が呼ばれない')
    end
  )

  it(
    'remove 失敗 (dir 残る) は prune + 自前 dir remove_dir で回収してから削除を続行',
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

  it(
    '閉じた残骸で dir まで消せなければ delete を中止して JSON を残す (孤児 dir なし・scan 回収可)',
    function()
      local wt = wt_path()
      vim.fn.mkdir(wt, 'p')
      local locked = io.open(vim.fs.joinpath(wt, 'locked.txt'), 'w')
      locked:write 'x\n'
      locked:close()
      -- dir を r-x (書き込み不可) にすると remove_dir の unlink が実 FS 権限で
      -- 失敗する (root 実行では成り立たない。make test はローカル非 root 前提)。
      vim.fn.system { 'chmod', '555', wt }
      assert.equals(0, vim.v.shell_error)
      store.save(existing_stub {
        worktree = { path = wt, created_by_us = true },
      })
      install_git {
        top_ok,
        git_ok, -- status clean
        git_fail 'fatal: remove boom\n', -- remove 失敗
        git_ok, -- prune ok (dir は rm 不能のまま)
      }
      state.input_answer = 'y'

      session_handler.delete(SLUG)

      assert.same({ 'git', 'worktree', 'prune' }, state.git_calls[4])
      assert.equals(4, #state.git_calls)
      assert.same({
        msg = 'review.nvim: 孤児 worktree dir を消去できませんでした。'
          .. '孤児 dir を残さないためセッション削除は中止します: '
          .. wt,
        level = vim.log.levels.WARN,
      }, state.notifications[1])
      -- JSON を消さない = closed + created_by_us の記録が残る (起動 scan が回収できる)
      assert.is_true(vim.uv.fs_stat(json_path()) ~= nil)
      assert.equals('closed', load_saved().status)
      assert.same({ path = wt, created_by_us = true }, load_saved().worktree)

      -- after_each の tmpdir 掃除 (delete 'rf') を通すため権限を戻す
      vim.fn.system { 'chmod', '755', wt }
      assert.equals(0, vim.v.shell_error)
    end
  )
end)

describe('panel 絞り込み (`/`)', function()
  use_env()

  local inputs

  before_each(function()
    inputs = {}
    vim.ui.input = function(opts, cb)
      inputs[#inputs + 1] = opts
      -- 同期発火 (use_env の input stub と同型)。filter_sidebar は vim.ui.input の
      -- cb を即呼ぶ前提で状態を更新する。
      cb(inputs.result)
    end
  end)
  after_each(function()
    vim.ui.input = REAL_INPUT
  end)

  local function panel_lines()
    local pw = ui_windows.win 'panel'
    if pw == nil then
      return nil
    end
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pw), 0, -1, false)
  end

  local function panel_winbar()
    local pw = ui_windows.win 'panel'
    return pw ~= nil and vim.w[pw].review_winbar or nil
  end

  it('絞り込み後は一致ファイルのみ表示し、winbar に filter を出す', function()
    start_done('main', 'feature')
    inputs.result = 'a.lua'
    session_handler.filter_sidebar()
    assert.same({
      'Changes (1)',
      'Showing changes for: main..作業ツリー',
      'M a.lua +1 -0',
    }, panel_lines())
    assert.equals('main..feature · 1 file · 0 comments · filter=a.lua', panel_winbar())
  end)

  it('空入力で解除 (全行戻る・winbar から filter 消える)', function()
    start_done('main', 'feature')
    inputs.result = 'a.lua'
    session_handler.filter_sidebar()
    assert.equals(3, #panel_lines())
    inputs.result = ''
    session_handler.filter_sidebar()
    assert.equals(4, #panel_lines())
    assert.equals('main..feature · 2 files · 0 comments', panel_winbar())
  end)

  it('キャンセル (nil) は現在の絞り込みを維持する', function()
    start_done('main', 'feature')
    inputs.result = 'a.lua'
    session_handler.filter_sidebar()
    inputs.result = nil
    session_handler.filter_sidebar()
    assert.same({
      'Changes (1)',
      'Showing changes for: main..作業ツリー',
      'M a.lua +1 -0',
    }, panel_lines())
  end)

  it(
    '<Tab>/<S-Tab> は絞り込み後の並びを進む (非一致ファイルを跨がない)',
    function()
      start_done('main', 'feature') -- 先頭 a.lua
      inputs.result = 'b.lua'
      session_handler.filter_sidebar()
      session_handler.next_file()
      assert.equals(state.repo .. '/b.lua', head_buf_name())
    end
  )

  it('[F/]F は絞り込み後、一致集合の最初/最後を開く', function()
    start_done('main', 'feature') -- 先頭 a.lua
    inputs.result = 'b.lua'
    session_handler.filter_sidebar()
    session_handler.first_file()
    assert.equals(state.repo .. '/b.lua', head_buf_name())
    session_handler.last_file()
    assert.equals(state.repo .. '/b.lua', head_buf_name())
  end)

  it(
    '一致 0 件は 0 行一覧 + 解除案内の winbar (閉じない・窓も残す)',
    function()
      start_done('main', 'feature')
      inputs.result = 'zzz'
      session_handler.filter_sidebar()
      local lines = panel_lines()
      -- nvim の空 buffer 契約 (最低 1 空行) = 絞り込み 0 件は空行 1 本 + winbar 案内
      assert.equals(1, #lines)
      assert.equals('', lines[1])
      assert.equals(
        'main..feature · 0 files · 0 comments · filter=zzz (空入力で解除)',
        panel_winbar()
      )
    end
  )

  it('active 不在では入力を開かない (無音 safe)', function()
    inputs.result = 'x'
    session_handler.filter_sidebar()
    assert.equals(0, #inputs)
    assert.equals(0, #state.notifications)
  end)
end)

-- ---------------------------------------------------------------------------
-- 保存時リフレッシュ (diff-review.md「リフレッシュ (未コミット反映契約)」)。
-- BufWritePost -> `git diff <base>` 再取得 -> 再パース -> anchor 検証 ->
-- ±カウント・panel・スレッド・winbar 再適用 -> :diffupdate -> 永続化。in-flight まとめ /
-- 失敗保持 / close・切替時の active guard を応答キューで pin する (#15 の契約移植)。
-- 3 窓構造での観測面: winbar は w:review_winbar (窓変数)、panel 行の [✓] は
-- x でトグルするレビュー完了マーク (open では付かない)
-- 表記、threads は head 実バッファ extmark、再取得で消えたファイルは files map と
-- 一覧から落ち panel winbar 末尾 ⚠N で可視化 (#16 契約、persistence-restore
-- 「anchor 検証」)。
-- ---------------------------------------------------------------------------

-- 保存後の作業ツリーを模擬する 2 回目の差分: a.lua は +2 増で line2 が行 4 へ
-- 後退 (anchor ±20 補正の対象)。c.lua が新規出現、b.lua は差分から消滅
-- (outdated 化 + map / 一覧から除去 -> winbar ⚠ で可視化)。a.lua の ±は +1 -> +2
-- に動く。
local RAW_DIFF_V2 = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1 +1,4 @@',
  ' line1',
  '+insA',
  '+insB',
  ' line2',
  'diff --git a/c.lua b/c.lua',
  'new file mode 100644',
  'index 0000000..4444444',
  '--- /dev/null',
  '+++ b/c.lua',
  '@@ -0,0 +1 @@',
  '+c1',
  '',
}, '\n')

-- 保存後に a.lua の実バッファが見る内容 (RAW_DIFF_V2 の new 側 = 4 行)。head 窓は
-- 実ファイルなので、単体でも保存後のディスク状態をバッファへ反映して張返を pin する。
local A_SAVED_LINES = { 'line1', 'insA', 'insB', 'line2' }

-- install_git の `git diff` のみ on_exit を遅延発火するスタブ (DESIGN「既知の
-- 制約」: 既定注入スタブは同期なので in-flight まとめ / close 中解決の順序契約
-- は遅延スタブでなければ観測できない)。deferred に応答を 1 呼べる。
local function install_git_deferred_diff(responses)
  state.git_calls = {}
  state.git_opts = {}
  state.deferred = nil
  state.diff_calls = 0
  cli._set_system(function(cmd, opts, on_exit)
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    state.git_opts[idx] = opts
    if cmd[2] == 'diff' then
      state.diff_calls = state.diff_calls + 1
      -- 解決コール内で次の deferred が登録される (追い fetch)。自分の分だけを
      -- 掃除する (後発を nil で潰さない)。
      local wrap
      wrap = function(res)
        on_exit(res)
        if state.deferred == wrap then
          state.deferred = nil
        end
      end
      state.deferred = wrap
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

-- 保存されたセッションファイル実体のバッファ (head 窓が張る実ファイルそのもの。
-- state.repo 配下が auto refresh の会員条件)。BufWritePost は exec_autocmds で
-- 発火させる (headless で :w 実書き込みより決定的。契約の本体は「buffer イベント」)。
local function session_file_buf(path)
  local name = state.repo .. '/' .. path
  local buf = vim.fn.bufnr(name)
  if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

local function fire_buf_write_post(buf)
  vim.api.nvim_exec_autocmds('BufWritePost', { buffer = buf, modeline = false })
end

-- 開始済みセッションにコメントを 2 件植えて save (a.lua は補正対象、
-- b.lua はリフレッシュで痕跡消失 -> outdated 対象)。
local function seed_two_comments()
  session_handler.active().comments = {
    {
      id = 'c1',
      file = 'a.lua',
      line = 2,
      end_line = 2,
      body = 'shift me',
      anchor = { before = 'line1', line = 'line2', after = vim.NIL },
      state = 'active',
      created_at = 100,
    },
    {
      id = 'c2',
      file = 'b.lua',
      line = 1,
      end_line = 1,
      body = 'gone',
      anchor = { before = vim.NIL, line = 'b1', after = vim.NIL },
      state = 'active',
      created_at = 101,
    },
  }
  session_handler.commit_comment_change() -- INV-4 save (リフレッシュ前の基準状態)
end

describe(
  '保存時リフレッシュ (diff-review「リフレッシュ (未コミット反映契約)」)',
  function()
    use_env()

    local function panel_rows()
      return vim.api.nvim_buf_get_lines(vim.fn.bufnr(SIDEBAR_NAME), 0, -1, false)
    end

    local function head_winbar()
      local w = ui_windows.win 'head'
      return w ~= nil and vim.w[w].review_winbar or nil
    end

    local function panel_winbar()
      local w = ui_windows.win 'panel'
      return w ~= nil and vim.w[w].review_winbar or nil
    end

    after_each(function()
      session_handler._set_diffupdate(nil)
      -- 実ファイルバッファは tab と無関係に生きるので明示掃除
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if vim.api.nvim_buf_is_valid(buf) and name:sub(1, #state.repo) == state.repo then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end)

    it(
      'BufWritePost -> git 再取得 -> parse -> anchor 検証 -> save の順 (±カウント・panel・winbar・extmark 再適用)',
      function()
        start_done('main', 'feature')
        seed_two_comments()

        -- 保存後の実ファイルを模擬 (a.lua new 側 4 行 = RAW_DIFF_V2 の内容)。
        local abuf = session_file_buf 'a.lua'
        vim.api.nvim_buf_set_lines(abuf, 0, -1, false, A_SAVED_LINES)

        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          -- head commit 比較 (通常経路は一致 = INFO なし)
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        fire_buf_write_post(abuf)

        -- 応答キューの呼び出し順が仕様の一部 (DESIGN「development」)。差分再取得は
        -- head 解決と一致する単引数形 (作業ツリー基準)、その後 commit 比較。
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[1])
        assert.same({ 'git', 'rev-parse', '--verify', 'feature' }, state.git_calls[2])
        assert.same({ 'git', 'rev-parse', '--verify', 'HEAD' }, state.git_calls[3])
        assert.equals(3, #state.git_calls)
        assert.equals(0, #state.notifications)

        -- 再パース -> anchor 検証 -> save の順序はディスク JSON の補正で観測
        -- (INV-4: 永続化はメモリ状態ではなくディスクで判定)。
        local saved = load_saved()
        assert.same({
          {
            id = 'c1',
            file = 'a.lua',
            line = 4, -- 'line2' が new 側行 4 へ移動、±20 内補正
            end_line = 4,
            body = 'shift me',
            anchor = { before = 'line1', line = 'line2', after = vim.NIL },
            state = 'active',
            created_at = 100,
          },
          {
            id = 'c2',
            file = 'b.lua',
            line = 1, -- outdated でも保存値のまま保持
            end_line = 1,
            body = 'gone',
            anchor = { before = vim.NIL, line = 'b1', after = vim.NIL },
            state = 'outdated',
            created_at = 101,
          },
        }, saved.comments)
        -- 3 窓契約: 再取得で消えた b.lua は files map に合成行を作らない
        -- (一覧も同じ集合。outdated は panel winbar ⚠N で可視化)
        assert.same({
          -- open はマークを変えない (viewed=レビュー完了 = x でのみ付与)
          ['a.lua'] = { viewed = false },
          ['c.lua'] = { viewed = false },
        }, saved.files)

        -- ±カウント・panel 再適用 (a.lua はコメントあり = アイコン付き)
        assert.same({
          'Changes (2)',
          'Showing changes for: main..作業ツリー',
          'M \u{EA6B} a.lua +2 -0',
          'A c.lua +1 -0',
        }, panel_rows())
        -- winbar: head 窓は窓変数 chrome (w:review_winbar 一本化)
        assert.equals('main..feature · a.lua · +2 -0 · 1 comment', head_winbar())
        -- b.lua outdated (head 窓の解らないファイル) は panel winbar 末尾 ⚠1
        assert.equals('main..feature · 2 files · 2 comments · ⚠1', panel_winbar())

        -- スレッド extmark は補正後行 4 (0-based 3) へ張返 (実ファイル窓の
        -- mark を捨てて session から再構成 — diff-review「コメント表示」)
        local marks = vim.api.nvim_buf_get_extmarks(abuf, commentmarks.ns(), 0, -1, {})
        assert.equals(1, #marks)
        assert.equals(3, marks[1][2])
      end
    )

    it(
      'in-flight 中の保存は dirtyまとめ (再取得 1 本のまま)、完了後の追い fetch は 1 回だけ',
      function()
        start_done('main', 'feature')
        install_git_deferred_diff {
          nil, -- diff #1 (deferred: placeholder)
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
          nil, -- diff #2 (追い fetch: deferred)
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }

        session_handler.refresh() -- #1 発射
        fire_buf_write_post(session_file_buf 'a.lua') -- in-flight 中 -> dirty
        fire_buf_write_post(session_file_buf 'a.lua') -- 2 回目の保存もまとめ

        assert.equals(1, state.diff_calls) -- 多重 fetch しない
        assert.is_true(state.deferred ~= nil)

        state.deferred(diff_ok(RAW_DIFF_V2)) -- #1 解決 -> apply -> dirty -> 追い 1 本

        assert.equals(2, state.diff_calls)
        assert.is_true(state.deferred ~= nil)

        state.deferred(diff_ok(RAW_DIFF_V2)) -- 追い fetch 解決 -> ここで完了

        assert.equals(2, state.diff_calls)
        -- 適用は 1 回まとめの最終状態で完了 (b.lua はコメントのない消失ファイル =
        -- 一覧からも落ちる。補正詳細は BufWritePost 側のテストで pin)。
        assert.same({
          'Changes (2)',
          'Showing changes for: main..作業ツリー',
          'M a.lua +2 -0',
          'A c.lua +1 -0',
        }, panel_rows())
        assert.equals(0, #state.notifications)
      end
    )

    it(
      '再取得失敗は WARN + 前回 parse 保持 (ディスクも panel も無変更)',
      function()
        start_done('main', 'feature')
        seed_two_comments()
        local before_saved = load_saved()
        local before_sidebar = panel_rows()

        install_git {
          function()
            -- 実 git と同じ shape (fatal 主行 + usage 続き)
            return {
              code = 128,
              stdout = '',
              stderr = "fatal: bad revision 'main'\nusage: git diff [<options>]\n",
            }
          end,
        }
        fire_buf_write_post(session_file_buf 'a.lua')

        assert.same({ 'git', 'diff', 'main' }, state.git_calls[1])
        assert.equals(1, #state.git_calls) -- 失敗後は commit 比較も追い fetch も走らない
        assert.same({
          msg = 'review.nvim: 差分の再取得に失敗しました。現在の表示とコメントを保持します: '
            .. "レビュー対象 ref が解決できません: 'main'。存在するブランチ/コミットを"
            .. '指定してください (start の base/head 引数は <Tab> で補完できます)',
          level = vim.log.levels.WARN,
        }, state.notifications[1])
        assert.equals(1, #state.notifications)
        assert.same(before_saved, load_saved())
        assert.same(before_sidebar, panel_rows())
      end
    )

    it(
      'セッション外保存と scratch 窓の保存は何もしない (会員実ファイルのみ自動リフレッシュ)',
      function()
        start_done('main', 'feature')
        -- 応答なしのスタブ = 会員外で git が走ればその場で error (検出)。
        install_git {}
        -- base scratch (review://base/…): 実ファイルでない = 会員外
        fire_buf_write_post(vim.fn.bufnr('review://base/' .. SLUG .. '/a.lua'))
        -- セッション外の実ファイル名バッファ (repo 根の外)
        local obuf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(obuf, '/tmp/review-spec-outside/a.lua')
        fire_buf_write_post(obuf)
        assert.equals(0, #state.git_calls)
        assert.equals(0, #state.notifications)
        pcall(vim.api.nvim_buf_delete, obuf, { force = true })

        -- 陽性対照: 会員実ファイルの保存は再取得が走る («会員判定が常に false で
        -- 何も起きない» 壊れ方を通過させない — 無条件 return の空実装は通らない)。
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        fire_buf_write_post(session_file_buf 'a.lua')
        assert.same({ 'git', 'diff', 'main' }, state.git_calls[1])
        assert.equals(3, #state.git_calls)
      end
    )

    it(
      'close 最中に in-flight が解決しても適用しない (active guard: disk も UI も触らない)',
      function()
        start_done('main', 'feature')
        install_git_deferred_diff { nil }
        session_handler.refresh()
        fire_buf_write_post(session_file_buf 'a.lua') -- dirty も設定されるが無効化対象
        assert.equals(1, state.diff_calls)

        session_handler.close() -- コメント 0 件 = 無確認で閉じる (in-flight/dirty 無効化)
        assert.is_nil(session_handler.active())

        state.deferred(diff_ok(RAW_DIFF_V2)) -- 解決: 対象セッションはもう active でない

        assert.equals(1, state.diff_calls) -- 結果破棄 = 追い fetch も走らない
        assert.equals('closed', load_saved().status)
        assert.same(
          { ['a.lua'] = { viewed = false }, ['b.lua'] = { viewed = false } },
          load_saved().files -- c.lua 再パース結果が書き戻されていない
        )
        assert.equals(0, vim.fn.bufexists(SIDEBAR_NAME)) -- 再描画で窓も復活しない
        assert.equals(0, #state.notifications)
      end
    )

    it(
      '現在の開きファイルが再取得差分から消滅: 窓はそのまま +0 -0 でゼロ化、panel 行は map から落ちる',
      function()
        start_done('main', 'feature') -- 初期開き a.lua
        session_handler.open_file 'b.lua' -- b.lua を実ファイル窓へ張り替え
        -- b.lua は追加 (A) = head winbar の末尾に種別マークが付く (issue #38)
        assert.equals('main..feature · b.lua · +1 -0 · 0 comments · new file', head_winbar())

        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        fire_buf_write_post(session_file_buf 'b.lua')

        -- 窓の張り替えはしない (head は実ファイル = ユーザーの編集対象)。±カウントは
        -- ゼロ差分として zero clear、一覧と files map からは合成行を作らず除去
        -- (outdated 化はコメントのあるファイル側のテストで pin)。
        assert.equals(state.repo .. '/b.lua', head_buf_name())
        -- リフレッシュは bind しないので窓 diffoff と base (new file) ラベルが維持
        -- され、head 側の種別マークも維持する (窓状態と winbar の一貫)
        assert.equals('main..feature · b.lua · +0 -0 · 0 comments · new file', head_winbar())
        assert.same({
          'Changes (2)',
          'Showing changes for: main..作業ツリー',
          'M a.lua +2 -0',
          'A c.lua +1 -0',
        }, panel_rows())
        assert.same(
          { ['a.lua'] = { viewed = false }, ['c.lua'] = { viewed = false } },
          load_saved().files
        )
      end
    )

    it(
      'リフレッシュの再取得は scratch 縮退セッションで <base> <head> 2 引数形 (開始時解決と一致)',
      function()
        install_git {
          top_ok,
          RP_HEAD_MISMATCH[1],
          RP_HEAD_MISMATCH[2],
          showref_ok,
          status_clean,
          function()
            return diff_ok(RAW_DIFF_A_B)
          end,
        }
        state.input_answer = 'n' -- switch 提案を拒否 = 縮退解で開始
        session_handler.start { base = 'main', head = 'feature' }

        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
        }
        session_handler.refresh()

        assert.same({ 'git', 'diff', 'main', 'feature' }, state.git_calls[1])
        -- 縮退は作業ツリーを見ないので head commit 比較も走らない (1 本だけ)
        assert.equals(1, #state.git_calls)
        assert.same(DEGRADED_MSG, state.notifications[1])
        assert.equals(1, #state.notifications)
      end
    )

    it(
      'リフレッシュの再取得は pr で cwd=worktree の単引数形 (開始時解決と一致・HEAD 比較なし)',
      function()
        started_with_worktree()

        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
        }
        session_handler.refresh()

        assert.same({ 'git', 'diff', 'main' }, state.git_calls[1])
        assert.equals(wt_path(), state.git_opts[1].cwd)
        -- PR は worktree を --detach するため HEAD 比較は恒真 (誤発火) -> 呼ばない
        assert.equals(1, #state.git_calls)
        assert.equals(0, #state.notifications)
      end
    )

    it(
      'head と現在の HEAD の commit 違いを INFO 1 回 (処理は続行)、告知後は比較打ち切り',
      function()
        start_done('main', 'feature')

        -- #1: commit 一致 -> INFO なし (比較の 2 rev-parse は走る)
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        session_handler.refresh()
        assert.same({ 'git', 'rev-parse', '--verify', 'feature' }, state.git_calls[2])
        assert.same({ 'git', 'rev-parse', '--verify', 'HEAD' }, state.git_calls[3])
        assert.equals(0, #state.notifications)

        -- #2: head=OTHER / HEAD=SAME -> 不一致 INFO 1 回 + 適用は進む (定義は
        -- base vs 現在のチェックアウトであり処理を止めない)
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          function()
            return { code = 0, stdout = OTHER_SHA .. '\n', stderr = '' }
          end,
          RP_HEAD_MATCH[2],
        }
        session_handler.refresh()
        assert.same({
          msg = 'review.nvim: セッション開始時の head と現在のチェックアウトが違います',
          level = vim.log.levels.INFO,
        }, state.notifications[1])
        assert.equals(1, #state.notifications)
        assert.same({
          'Changes (2)',
          'Showing changes for: main..作業ツリー',
          'M a.lua +2 -0',
          'A c.lua +1 -0',
        }, panel_rows())

        -- #3: 告知済み -> rev-parse 比較は以後走らない (save ごとに同じ告知を出さ
        -- ない。余剰呼び出しは stub が error で弾く)
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
        }
        session_handler.refresh()
        assert.equals(1, #state.git_calls)
        assert.equals(1, #state.notifications)
      end
    )

    it(
      ':diffupdate はセッション実ファイルの &diff 窓にだけ発火 (head 枠と同一 buf の user 窓。base scratch・セッション外窓は不発火)',
      function()
        local fired = {}
        start_done('main', 'feature')
        session_handler._set_diffupdate(function(win)
          fired[#fired + 1] = vim.api.nvim_win_get_buf(win)
        end)

        -- head 窓の張る実ファイル (&diff) = 発火対象。加えて同一バッファを
        -- &diff で見るユーザー窓 (会員なので同じ buf の窓全てが対象)。
        local abuf = vim.fn.bufnr(state.repo .. '/a.lua')
        vim.api.nvim_set_current_tabpage(state.tab)
        vim.cmd 'vsplit'
        vim.api.nvim_win_set_buf(0, abuf)
        vim.api.nvim_win_set_option(0, 'diff', true)
        -- ユーザー自分の別ツリーの diff 窓 (セッション会員外)
        local obuf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(obuf, '/tmp/review-spec-outside/x.lua')
        vim.cmd 'vsplit'
        vim.api.nvim_win_set_buf(0, obuf)
        vim.api.nvim_win_set_option(0, 'diff', true)

        -- 会員実ファイルのバッファへ BufWritePost -> 再取得適用後に :diffupdate が
        -- 発火するのは会員 &diff 窓だけ (base scratch 窓・会員外窓は不発火、
        -- panel 窓は &diff なし)。
        install_git {
          function()
            return diff_ok(RAW_DIFF_V2)
          end,
          RP_HEAD_MATCH[1],
          RP_HEAD_MATCH[2],
        }
        fire_buf_write_post(abuf)

        -- 2 エントリともセッション実ファイル buf = head 窓とユーザー窓の 2 つ
        -- (会員外の obuf・base scratch が混じらないことの完全一致 assert)。
        assert.same({ abuf, abuf }, fired)

        pcall(vim.api.nvim_buf_delete, obuf, { force = true })
      end
    )
  end
)

-- ---------------------------------------------------------------------------
-- file panel ツリー表示 / view state (issue-17 の handlers 側契約)。
-- 行フォーマットの正誤表そのものは ui/treelist_spec / ui/filepanel_spec (実 FS) が
-- pin するので、ここでは «i トグル・dir 折込・カーソル逆追従・view state が
-- session JSON に載らない» の調停のみを検証する。多段差分スタブ (app/util/*,
-- cmd ファイルと cmd/ dir の同名併存 (置換), z.txt) を実 disk なしで駆動する
-- (head は未実在 = 告知 scratch 経路。panel 契約の検証には不要)。
-- ---------------------------------------------------------------------------

local RAW_DIFF_TREES = table.concat({
  'diff --git a/app/util/x.lua b/app/util/x.lua',
  'index 111..222 100644',
  '--- a/app/util/x.lua',
  '+++ b/app/util/x.lua',
  '@@ -1 +1,2 @@',
  ' line1',
  '+line2',
  'diff --git a/app/y.lua b/app/y.lua',
  'new file mode 100644',
  'index 000..333',
  '--- /dev/null',
  '+++ b/app/y.lua',
  '@@ -0,0 +1 @@',
  '+y1',
  'diff --git a/cmd b/cmd',
  'deleted file mode 100644',
  'index 444..000',
  '--- a/cmd',
  '+++ /dev/null',
  '@@ -1 +0,0 @@',
  '-base',
  'diff --git a/cmd/main.go b/cmd/main.go',
  'new file mode 100644',
  'index 000..555',
  '--- /dev/null',
  '+++ b/cmd/main.go',
  '@@ -0,0 +1 @@',
  '+package main',
  'diff --git a/z.txt b/z.txt',
  'index 666..777',
  '--- a/z.txt',
  '+++ b/z.txt',
  '@@ -1 +1,2 @@',
  ' z1',
  '+z2',
  '',
}, '\n')

local function start_trees()
  install_git {
    top_ok,
    RP_HEAD_MATCH[1],
    RP_HEAD_MATCH[2],
    function()
      return diff_ok(RAW_DIFF_TREES)
    end,
  }
  return session_handler.start { base = 'main', head = 'feature' }
end

local function panel_window_lines()
  local pw = ui_windows.win 'panel'
  local buf = vim.api.nvim_win_get_buf(pw)
  return buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe('file panel ツリー / view state (issue-17)', function()
  use_env()

  local TREE_LINES = {
    'Changes (5)',
    'Showing changes for: main..作業ツリー',
    '* app/',
    '  M util/',
    '    M x.lua +1 -0',
    '  A y.lua +1 -0',
    'A cmd/',
    '  A main.go +1 -0',
    'D cmd +0 -1',
    'M z.txt +1 -0',
  }

  it(
    '開通から既定 tree。初期 open_file の panel カーソルがその file 行に逆追従',
    function()
      start_trees()
      local _, lines = panel_window_lines()
      assert.same(TREE_LINES, lines)
      local pw = ui_windows.win 'panel'
      local row = vim.api.nvim_win_get_cursor(pw)[1]
      assert.equals(panel_row_for('file', 'app/util/x.lua'), row)
    end
  )

  it('<Tab> (next_file) でも panel カーソルが逆追従する', function()
    start_trees()
    session_handler.next_file() -- app/y.lua
    local pw = ui_windows.win 'panel'
    assert.equals(panel_row_for('file', 'app/y.lua'), vim.api.nvim_win_get_cursor(pw)[1])
  end)

  it(
    'i で list 表示 (現行フラット・ヘッダなし) -> i でもう一度 tree',
    function()
      start_trees()
      session_handler.toggle_listing_style()
      local _, lines = panel_window_lines()
      assert.same({
        'M app/util/x.lua +1 -0',
        'A app/y.lua +1 -0',
        'D cmd +0 -1',
        'A cmd/main.go +1 -0',
        'M z.txt +1 -0',
      }, lines)
      -- list 表示では collapsed 集合は効かない (全ファイル行)
      session_handler.toggle_listing_style()
      local _, back = panel_window_lines()
      assert.same(TREE_LINES, back)
    end
  )

  it(
    '<CR> on dir 行は折りたたみ / 再 <CR> で展開 (o も同じ入口・カーソルは dir 行)',
    function()
      start_trees()
      local pw = ui_windows.win 'panel'
      local dir_row = panel_row_for('dir', 'app')
      vim.api.nvim_set_current_win(pw)
      vim.api.nvim_win_set_cursor(pw, { dir_row, 0 })

      session_handler.open_selected_file()
      local _, lines = panel_window_lines()
      assert.same({
        'Changes (5)',
        'Showing changes for: main..作業ツリー',
        '▸ * app/',
        'A cmd/',
        '  A main.go +1 -0',
        'D cmd +0 -1',
        'M z.txt +1 -0',
      }, lines)
      -- 折り畳み後も panel カーソルは dir 行に残り、選択 entry も dir のまま
      assert.equals(dir_row, vim.api.nvim_win_get_cursor(pw)[1])
      session_handler.open_selected_file() -- 再 <CR> = 展開
      local _, back = panel_window_lines()
      assert.same(TREE_LINES, back)
    end
  )

  it(
    '<CR> で dir 行と file 行が区別される (o on dir も折込・file cmd は開く)',
    function()
      start_trees()
      local pw = ui_windows.win 'panel'
      -- 同名併存: dir cmd (折込) と file cmd D (告知 scratch)
      local dir_row = panel_row_for('dir', 'cmd')
      local file_row = panel_row_for('file', 'cmd')
      assert.is_true(dir_row ~= nil and file_row ~= nil and dir_row ~= file_row)

      vim.api.nvim_set_current_win(pw)
      vim.api.nvim_win_set_cursor(pw, { dir_row, 0 })
      session_handler.open_selected_file() -- <CR>/o = dir では折込 (別 tab は開かない)
      local _, lines = panel_window_lines()
      assert.equals('▸ A cmd/', lines[7])
      assert.equals(dir_row, vim.api.nvim_win_get_cursor(pw)[1])

      -- 展開に戻す dir 操作では head 窓の中身を替えない (告知 scratch は据え置き)
      session_handler.open_selected_file()
      vim.api.nvim_win_set_cursor(pw, { file_row, 0 })
      session_handler.open_selected_file() -- <CR> on file cmd = open_file (D = 告知 scratch)
      assert.equals(
        'review://deleted/' .. SLUG .. '/cmd',
        vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(ui_windows.win 'head'))
      )
    end
  )

  it('view state (filter/collapsed/listing style) は session JSON に載らない', function()
    start_trees()
    -- 変更を伴う操作で save を踏ませる: viewed 切替 (INV-4) + filter + fold + i
    session_handler.next_file() -- persist 経由の save
    local pw = ui_windows.win 'panel'
    vim.api.nvim_set_current_win(pw)
    vim.api.nvim_win_set_cursor(pw, { panel_row_for('dir', 'app'), 0 })
    session_handler.open_selected_file()
    session_handler.toggle_listing_style()

    local raw = table.concat(vim.fn.readfile(paths.session_file(state.repo, SLUG)), '\n')
    local decoded = vim.json.decode(raw)
    local allowed = {
      version = true,
      id = true,
      repo = true,
      mode = true,
      base = true,
      head = true,
      pr = true,
      worktree = true,
      status = true,
      files = true,
      comments = true,
      created_at = true,
      updated_at = true,
    }
    for key in pairs(decoded) do
      assert.is_true(allowed[key] == true, 'session JSON に view state らしき key: ' .. key)
    end
    -- files は path -> {viewed} のまま (collapsed などの混入なし)
    assert.same({
      -- 開始 open + <Tab> open だけではマークは付かない
      ['app/util/x.lua'] = { viewed = false },
      ['app/y.lua'] = { viewed = false },
      cmd = { viewed = false },
      ['cmd/main.go'] = { viewed = false },
      ['z.txt'] = { viewed = false },
    }, decoded.files)
  end)

  it('winbar 末尾 ⚠N は listing style トグルを跨いで維持される', function()
    start_done('main', 'feature')
    inject_outdated('x', 'gone.lua')
    assert.equals(
      'main..feature · 2 files · 1 comment · ⚠1',
      vim.w[ui_windows.win 'panel'].review_winbar
    )
    session_handler.toggle_listing_style()
    assert.equals(
      'main..feature · 2 files · 1 comment · ⚠1',
      vim.w[ui_windows.win 'panel'].review_winbar
    )
  end)

  it(
    '<Tab>/<S-Tab> はパス昇順でなく file panel の表示順 (ツリー上→下) を辿る',
    function()
      start_trees() -- 初期 open = app/util/x.lua
      assert.equals('app/util/x.lua', panel_current_path())

      session_handler.next_file() -- ツリー: app/y.lua (パス昇順と同じ)
      assert.equals('app/y.lua', panel_current_path())

      -- ここがパス昇順と分岐: ツリーは cmd/main.go -> cmd (file)、パスは cmd -> cmd/main.go
      session_handler.next_file()
      assert.equals('cmd/main.go', panel_current_path())
      session_handler.next_file()
      assert.equals('cmd', panel_current_path())
      session_handler.next_file()
      assert.equals('z.txt', panel_current_path())
      session_handler.next_file() -- 端 = 無動作
      assert.equals('z.txt', panel_current_path())

      session_handler.prev_file() -- ツリーを 1 つ上へ
      assert.equals('cmd', panel_current_path())
    end
  )

  it(
    '折りたたみ dir の子は表示と同一規則で飛ばし、list モードはフラット順を辿る',
    function()
      start_trees() -- 初期 open = app/util/x.lua
      local pw = ui_windows.win 'panel'
      vim.api.nvim_set_current_win(pw)
      vim.api.nvim_win_set_cursor(pw, { panel_row_for('dir', 'app'), 0 })
      session_handler.open_selected_file() -- app を折りたたむ (子は非表示)

      -- 非表示になった現在位置は順序から外れ、次 = 表示先頭 (cmd/main.go)
      session_handler.next_file()
      assert.equals('cmd/main.go', panel_current_path())
      session_handler.first_file() -- 現対象が先頭なので無動作
      assert.equals('cmd/main.go', panel_current_path())

      -- list モードは折りたたみを無視したフラット (パス昇順)
      session_handler.toggle_listing_style()
      session_handler.open_file 'app/y.lua'
      session_handler.next_file() -- パス昇順: app/y.lua -> cmd (file)
      assert.equals('cmd', panel_current_path())
    end
  )
end)
