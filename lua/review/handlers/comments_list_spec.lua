-- handlers/comments_list: 横断コメント一覧の開閉・ジャンプ・行操作 (docs/design/
-- features/comment-list.md「操作」「ジャンプ」「追随」「エッジケースの決定」)。
-- session_spec と同じ git 注入スタブ + 実 FS fixture で active セッションを立て、
-- 一覧窓 / head 窓の実バッファ・カーソル・通知文言 (確定文言の正本) を検証する。
-- 折畳・絞り込み・list 表示は panel の view state 側で動かし、一覧の表示順が
-- { collapsed = {}, mode = 'tree' } 解決 (折畳無視・tree 固定) であることを pin する。
-- e の永続化はディスクの session JSON を読んで判定する (INV-4)。
local cli = require 'review.git.cli'
local commentlist = require 'review.ui.commentlist'
local comments_list = require 'review.handlers.comments_list'
local comments_handler = require 'review.handlers.comments'
local config = require 'review.config'
local paths = require 'review.store.paths'
local session_handler = require 'review.handlers.session'
local store = require 'review.store.session'
local ui_windows = require 'review.ui.windows'

local SLUG = 'main--feature'
local COMMENTS_BUF = 'review://comments/' .. SLUG

-- コメント入力 float の確定 (insert の <C-y>)。実 float を実打鍵で駆動する
-- (vim.ui.input はセッション close 確認 / 絞り込み用で、編集 float は別実装)。
local CY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)

-- 編集中の float の先頭行を消してから本文を打ち <C-y> で確定する。
local function type_into_float(body)
  vim.cmd 'normal 0d$'
  vim.cmd('normal i' .. body .. CY)
end

-- float の title (input.lua の契約: 0.10 は文字列 / 0.13 は chunk table)。
local function title_text()
  local t = vim.api.nvim_win_get_config(0).title
  return type(t) == 'table' and (type(t[1]) == 'table' and t[1][1] or t[1]) or (t or '')
end

-- a.lua: M (実ファイル) / bin.dat: binary / c.lua: D / src/deep/new.lua: A。
-- tree 表示順 = src/deep/new.lua -> a.lua -> bin.dat -> c.lua。
local RAW_DIFF = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1 +1,2 @@',
  ' line1',
  '+line2',
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
  'diff --git a/src/deep/new.lua b/src/deep/new.lua',
  'new file mode 100644',
  'index 0000000..3333333',
  '--- /dev/null',
  '+++ b/src/deep/new.lua',
  '@@ -0,0 +1,3 @@',
  '+deep1',
  '+deep2',
  '+deep3',
  '',
}, '\n')

local SAME_SHA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
local OTHER_SHA = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

local state = {}

local REAL_NOTIFY = vim.notify
local REAL_INPUT = vim.ui.input

-- cli._set_system 注入: 実行順に responses[idx] を同期で on_exit する。
-- show (base scratch / 縮退 head の充填) は path に応じた既定応答。
local function install_git(responses)
  state.git_calls = {}
  cli._set_system(function(cmd, opts, on_exit)
    local idx = #state.git_calls + 1
    table.insert(state.git_calls, cmd)
    if responses[idx] ~= nil then
      on_exit(responses[idx](cmd, opts))
      return
    end
    if cmd[2] == 'show' then
      local spec = cmd[3] or ''
      local body = spec:find('src/deep/new.lua', 1, true) and 'deep1\ndeep2\ndeep3\n'
        or 'line1\nline2\n'
      on_exit { code = 0, stdout = body, stderr = '' }
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
local sha = function(value)
  return function()
    return { code = 0, stdout = value .. '\n', stderr = '' }
  end
end
local showref_ok = function()
  return { code = 0, stdout = '', stderr = '' }
end
local status_clean = function()
  return { code = 0, stdout = '', stderr = '' }
end

local function use_env()
  before_each(function()
    config.reset()
    state = { notifications = {}, input_answer = 'y', git_calls = {} }
    state.dir = vim.fn.tempname()
    vim.fn.mkdir(state.dir, 'p')
    local raw = vim.fs.joinpath(state.dir, 'repo')
    vim.fn.mkdir(vim.fs.joinpath(raw, 'src/deep'), 'p')
    local files = {
      ['a.lua'] = 'line1\nline2\n',
      ['b.lua'] = 'line1\nline2\n',
      ['bin.dat'] = 'binary\n',
      ['src/deep/new.lua'] = 'deep1\n',
    }
    for name, body in pairs(files) do
      local f = io.open(vim.fs.joinpath(raw, name), 'w')
      f:write(body)
      f:close()
    end
    state.repo = vim.uv.fs_realpath(raw) or raw
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
      table.insert(state.notifications, opts)
      cb(state.input_answer)
    end
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
    comments_list._set_now(nil)
    session_handler._reset()
    config.reset()
    cli._set_system(nil)
    cli._set_executable(nil)
    vim.fn.delete(state.dir, 'rf')
  end)
end

-- 通常経路 (head == 現在のチェックアウト) の開始を完結させる。
local function start_done()
  install_git {
    top_ok,
    sha(SAME_SHA),
    sha(SAME_SHA),
    function()
      return diff_ok(RAW_DIFF)
    end,
  }
  return session_handler.start { base = 'main', head = 'feature' }
end

-- scratch 縮退 (head が別コミット + switch 拒否) の開始を完結させる。
local function start_degraded()
  state.input_answer = 'n'
  install_git {
    top_ok,
    sha(SAME_SHA),
    sha(OTHER_SHA),
    showref_ok,
    status_clean,
    function()
      return diff_ok(RAW_DIFF)
    end,
  }
  return session_handler.start { base = 'main', head = 'feature' }
end

-- active セッションのコメントを 1 件注入する (render は session.comments を読む)。
local function comment_stub(overrides)
  local c = {
    id = 'c1',
    file = 'a.lua',
    line = 1,
    end_line = 1,
    body = 'body',
    anchor = vim.NIL,
    state = 'active',
    created_at = 1,
  }
  for k, v in pairs(overrides or {}) do
    c[k] = v
  end
  return c
end

local function add_comment(overrides)
  local sess = session_handler.active()
  local c = comment_stub(overrides)
  c.id = 'c' .. (#sess.comments + 1)
  sess.comments[#sess.comments + 1] = c
  return c
end

local function review_tab()
  local st = ui_windows.state()
  return st and st.tab or nil
end

local function list_win()
  return commentlist.find_window(SLUG)
end

local function list_lines()
  local w = list_win()
  assert.is_not_nil(w, '一覧窓が無い')
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
end

local function focus_list_row(row)
  local w = list_win()
  assert.is_not_nil(w, '一覧窓が無い')
  vim.api.nvim_set_current_win(w)
  vim.api.nvim_win_set_cursor(w, { row, 0 })
end

local function head_buf_name()
  local w = ui_windows.win 'head'
  return w ~= nil and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) or nil
end

local function panel_row_for(kind, path)
  local filepanel = require 'review.ui.filepanel'
  local pw = ui_windows.win 'panel'
  local buf = vim.api.nvim_win_get_buf(pw)
  for row = 1, vim.api.nvim_buf_line_count(buf) do
    local entry = filepanel.row_entry(buf, row)
    if entry ~= nil and entry.kind == kind and entry.path == path then
      return row
    end
  end
  return nil
end

describe('comments_list.open', function()
  use_env()

  it(
    'open は current tab に vsplit で一覧を開き、行 / meta / winbar を付ける',
    function()
      start_done()
      add_comment { body = 'use map', line = 2 }

      local res = comments_list.open()

      assert.same({ __class = 'review.Result', ok = true }, res)
      -- 開いた直後は一覧窓が current (focus 済み)
      assert.equals(4, #vim.api.nvim_tabpage_list_wins(review_tab()))
      local w = list_win()
      assert.is_not_nil(w)
      assert.equals(w, vim.api.nvim_get_current_win())
      local buf = vim.api.nvim_win_get_buf(w)
      assert.equals(COMMENTS_BUF, vim.api.nvim_buf_get_name(buf))
      assert.equals('review-list', vim.bo[buf].filetype)
      assert.same({ kind = 'commentlist', session_id = SLUG }, vim.b[buf].review_meta)
      assert.same({ 'a.lua:2  [c1]  use map' }, list_lines())
      assert.equals('main..作業ツリー · 1 comment', vim.w[w].review_winbar)
    end
  )

  it(
    '既に開いていれば再 vsplit せずその窓へ focus し、内容を最新へ再 render する',
    function()
      start_done()
      add_comment { body = 'one' }
      comments_list.open()
      local w = list_win()

      add_comment { line = 2, body = 'two' }
      local res = comments_list.open()

      assert.equals(true, res.ok)
      assert.equals(w, list_win())
      assert.equals(4, #vim.api.nvim_tabpage_list_wins(review_tab()))
      assert.same({ 'a.lua:1  [c1]  one', 'a.lua:2  [c2]  two' }, list_lines())
    end
  )

  it(
    '一覧窓の内容が差し替わった (drift) 場合は新しい一覧窓を開く (壊れた窓は触らない)',
    function()
      start_done()
      add_comment { body = 'use map' }
      comments_list.open()
      local drifted = list_win()
      -- ユーザーの :edit 相当: 窓の中身を別バッファへ差し替える
      vim.api.nvim_win_set_buf(drifted, vim.api.nvim_create_buf(false, true))
      assert.is_nil(list_win())

      local res = comments_list.open()

      assert.equals(true, res.ok)
      local fresh = list_win()
      assert.is_not_nil(fresh)
      assert.is_not.equals(drifted, fresh)
      assert.same({ 'a.lua:1  [c1]  use map' }, list_lines())
    end
  )

  it('active 不在は E_NOT_ACTIVE を返し窓を開かない', function()
    local res = comments_list.open()

    assert.same({
      __class = 'review.Result',
      ok = false,
      error = 'review.nvim: アクティブなセッションがありません',
      code = 'E_NOT_ACTIVE',
    }, res)
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(state.tab))
    assert.is_nil(list_win())
  end)

  it(
    '折畳んだ dir・list 表示の panel state でも tree 順で全ファイルのコメントを出す',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'A' }
      add_comment { file = 'src/deep/new.lua', line = 1, body = 'D' }

      -- panel の view state: dir を折畳 + list 表示へ切替 (どちらも一覧には効かない)
      local row = panel_row_for('dir', 'src/deep')
      assert.is_not_nil(row, 'dir 行が見つからない')
      local pw = ui_windows.win 'panel'
      vim.api.nvim_set_current_win(pw)
      vim.api.nvim_win_set_cursor(pw, { row, 0 })
      session_handler.open_selected_file()
      session_handler.toggle_listing_style()

      comments_list.open()

      assert.same({
        'src/deep/new.lua:1  [c2]  D',
        'a.lua:1  [c1]  A',
      }, list_lines())
    end
  )

  it(
    '絞り込み (/) 適用後のファイル集合だけを出す (winbar の N もその件数)',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'A' }
      add_comment { file = 'src/deep/new.lua', line = 1, body = 'D' }

      state.input_answer = 'deep'
      session_handler.filter_sidebar()

      comments_list.open()

      assert.same({ 'src/deep/new.lua:1  [c2]  D' }, list_lines())
      assert.equals('main..作業ツリー · 1 comment', vim.w[list_win()].review_winbar)
    end
  )
end)

-- 位置契約 (issue #37): 一覧はレビュー tab の最下部に全幅で開く。押した窓や
-- splitright に位置が依存しないこと (旧実装の素の vsplit は押した窓と
-- splitright で位置が変わった) と、分割元から窓 diff opts を継承しないことを
-- win_screenpos / 窓 opts で pin する。
describe('comments_list.open の位置契約 (レビュー tab 最下部・全幅)', function()
  use_env()

  local function row_of(win)
    return vim.fn.win_screenpos(win)[1]
  end

  local function col_of(win)
    return vim.fn.win_screenpos(win)[2]
  end

  it(
    'head 窓から開いても一覧は最下部に全幅で開く (窓 diff opts を退避・winfixheight)',
    function()
      start_done()
      add_comment { body = 'use map' }
      local pw, bw, hw = ui_windows.win 'panel', ui_windows.win 'base', ui_windows.win 'head'
      vim.api.nvim_set_current_win(hw)

      local res = comments_list.open()

      assert.equals(true, res.ok)
      local w = list_win()
      assert.is_not_nil(w)
      -- 最下部: panel / base / head のどれよりも下の行に置かれる
      assert.is_true(row_of(w) > row_of(pw), '一覧が panel より下に無い')
      assert.is_true(row_of(w) > row_of(bw), '一覧が base より下に無い')
      assert.is_true(row_of(w) > row_of(hw), '一覧が head より下に無い')
      -- 全幅: 左端から tab 全幅
      assert.equals(1, col_of(w))
      assert.equals(vim.o.columns, vim.api.nvim_win_get_width(w))
      -- 分割元 (head 窓) の窓 diff opts を継承しない
      assert.equals(false, vim.wo[w].diff)
      assert.equals('manual', vim.wo[w].foldmethod)
      assert.equals(true, vim.wo[w].winfixheight)
      -- 分割元の窓は退避しない (head は窓 diff のまま)
      assert.equals(true, vim.wo[hw].diff)
    end
  )

  it('file panel から開いても位置は変わらない (最下部・全幅)', function()
    start_done()
    add_comment { body = 'use map' }
    vim.api.nvim_set_current_win(ui_windows.win 'panel')

    comments_list.open()

    local w = list_win()
    assert.is_not_nil(w)
    assert.is_true(row_of(w) > row_of(ui_windows.win 'head'), '一覧が最下部でない')
    assert.equals(1, col_of(w))
    assert.equals(vim.o.columns, vim.api.nvim_win_get_width(w))
  end)

  it(
    '別 tab から開いてもレビュー tab の最下部に開く (:Review comments は tab gate を持たない)',
    function()
      start_done()
      add_comment { body = 'use map' }
      vim.cmd 'tabnew'
      local user_tab = vim.api.nvim_get_current_tabpage()
      assert.is_not.equals(review_tab(), user_tab)

      comments_list.open()

      -- レビュー tab へ切替えてそこに開く (ユーザー tab には出さない)
      assert.equals(review_tab(), vim.api.nvim_get_current_tabpage())
      local w = list_win()
      assert.is_not_nil(w)
      assert.equals(review_tab(), vim.api.nvim_win_get_tabpage(w))
      assert.is_true(row_of(w) > row_of(ui_windows.win 'head'), '一覧が最下部でない')
      assert.equals(vim.o.columns, vim.api.nvim_win_get_width(w))
      vim.api.nvim_set_current_tabpage(user_tab)
      assert.equals(
        1,
        #vim.api.nvim_tabpage_list_wins(user_tab),
        'ユーザー tab に一覧を出した'
      )
    end
  )

  it('高さは config.comment_list_height で決まる', function()
    config.setup { comment_list_height = 6 }
    start_done()
    add_comment { body = 'use map' }

    comments_list.open()

    assert.equals(6, vim.api.nvim_win_get_height(list_win()))
  end)
end)

describe('comments_list.jump_current', function()
  use_env()

  it(
    '<CR>: 実ファイルは review tab へ切り替えて head 窓を記録行へ移動する',
    function()
      start_done()
      add_comment { body = 'use map', line = 2 }
      comments_list.open()
      -- 一覧を別 tab へ移してから <CR> (ジャンプ前の review tab 切替を pin する)
      vim.cmd 'wincmd T'
      local moved = vim.api.nvim_get_current_tabpage()
      assert.is_not.equals(review_tab(), moved)

      focus_list_row(1)
      comments_list.jump_current()

      assert.equals(review_tab(), vim.api.nvim_get_current_tabpage())
      assert.is_not.equals(moved, vim.api.nvim_get_current_tabpage())
      local hw = ui_windows.win 'head'
      assert.equals(state.repo .. '/a.lua', vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(hw)))
      assert.equals(2, vim.api.nvim_win_get_cursor(hw)[1])
    end
  )

  it('<CR>: 記録行が行数外なら最終行へクランプする', function()
    start_done()
    add_comment { line = 99, end_line = 99 }
    comments_list.open()

    focus_list_row(1)
    comments_list.jump_current()

    local hw = ui_windows.win 'head'
    local buf = vim.api.nvim_win_get_buf(hw)
    assert.equals(2, vim.api.nvim_buf_line_count(buf))
    assert.equals(2, vim.api.nvim_win_get_cursor(hw)[1])
  end)

  it('<CR>: 縮退 head (scratch) は git show 充填後に位置決めする', function()
    start_degraded()
    add_comment { line = 2 }
    add_comment { file = 'src/deep/new.lua', line = 3 }
    comments_list.open()

    -- 別ファイル (新規 scratch) への <CR>: 充填の前後どちらでも最終位置が記録行
    -- (bind 後にクランプ -> 充填完了時に移動 = 呼び出し側で待たない)
    focus_list_row(1)
    comments_list.jump_current()
    local hw = ui_windows.win 'head'
    local hb = vim.api.nvim_win_get_buf(hw)
    assert.equals('review://head/' .. SLUG .. '/src/deep/new.lua', vim.api.nvim_buf_get_name(hb))
    assert.same({ 'deep1', 'deep2', 'deep3' }, vim.api.nvim_buf_get_lines(hb, 0, -1, false))
    assert.equals(3, vim.api.nvim_win_get_cursor(hw)[1])

    -- 同一バッファ (a.lua) への <CR>: 行 2 へ
    focus_list_row(2)
    comments_list.jump_current()
    assert.equals(
      'review://head/' .. SLUG .. '/a.lua',
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(hw))
    )
    assert.same(
      { 'line1', 'line2' },
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(hw), 0, -1, false)
    )
    assert.equals(2, vim.api.nvim_win_get_cursor(hw)[1])
  end)

  it(
    '<CR>: outdated は記録行へ移動し INFO を出す (文言はコメント一覧の正本)',
    function()
      start_done()
      add_comment { line = 2, state = 'outdated' }
      comments_list.open()

      focus_list_row(1)
      comments_list.jump_current()

      assert.same({
        {
          msg = 'review.nvim: コメントは outdated です。記録された行へ移動します',
          level = vim.log.levels.INFO,
        },
      }, state.notifications)
      assert.equals(2, vim.api.nvim_win_get_cursor(ui_windows.win 'head')[1])
    end
  )

  it(
    '<CR>: binary / 削除の告知表示は移動せず WARN (head 窓は変わらない)',
    function()
      start_done()
      add_comment { file = 'bin.dat', line = 1, body = 'bin' }
      add_comment { file = 'c.lua', line = 1, body = 'gone' }
      comments_list.open()
      local before = head_buf_name()

      focus_list_row(1)
      comments_list.jump_current()
      assert.same({
        {
          msg = 'review.nvim: binary / 削除の告知表示のため移動できません',
          level = vim.log.levels.WARN,
        },
      }, state.notifications)

      focus_list_row(2)
      comments_list.jump_current()
      assert.same({
        {
          msg = 'review.nvim: binary / 削除の告知表示のため移動できません',
          level = vim.log.levels.WARN,
        },
        {
          msg = 'review.nvim: binary / 削除の告知表示のため移動できません',
          level = vim.log.levels.WARN,
        },
      }, state.notifications)
      assert.equals(before, head_buf_name())
    end
  )

  it(
    '<CR>: 現在の差分に無いファイルは移動せず WARN (outdated は末尾に出る)',
    function()
      start_done()
      add_comment { file = 'ghost.lua', line = 3, state = 'outdated', body = 'ghost' }
      comments_list.open()
      assert.same({ 'ghost.lua:3  [c1]  ghost ⚠ outdated' }, list_lines())

      focus_list_row(1)
      comments_list.jump_current()

      assert.same({
        {
          msg = 'review.nvim: このファイルは現在の差分に無いため移動できません',
          level = vim.log.levels.WARN,
        },
      }, state.notifications)
      assert.equals(state.repo .. '/a.lua', head_buf_name())
    end
  )

  it(
    '<CR>: active セッション不在は WARN «アクティブなセッションがありません»',
    function()
      -- active を立てずに一覧だけ描く (session close 後の残骸窓を模す)
      local session = {
        id = SLUG,
        base = 'main',
        head = 'feature',
        files = { ['a.lua'] = { viewed = false } },
        comments = {
          comment_stub { id = 'c1', file = 'a.lua', line = 1, body = 'x' },
        },
      }
      local buf = commentlist.render(session, { order = { 'a.lua' } })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })

      comments_list.jump_current()

      assert.same({
        {
          msg = 'review.nvim: アクティブなセッションがありません',
          level = vim.log.levels.WARN,
        },
      }, state.notifications)
    end
  )
end)

describe('comments_list の閉じ方と窓の掃除', function()
  use_env()

  it('q は一覧窓を閉じるだけ (セッション状態は変えない)', function()
    start_done()
    add_comment {}
    comments_list.open()
    local buf = vim.api.nvim_win_get_buf(list_win())
    focus_list_row(1)

    comments_list.close_current()

    assert.is_nil(list_win())
    assert.equals(3, #vim.api.nvim_tabpage_list_wins(review_tab()))
    assert.equals(-1, vim.fn.bufnr(COMMENTS_BUF))
    assert.equals(false, vim.api.nvim_buf_is_valid(buf))
    assert.is_not_nil(session_handler.active())
  end)

  it(
    'ユーザーが :close した後は BufUnload で state を掃除し、次回 open は新規 vsplit',
    function()
      start_done()
      add_comment {}
      comments_list.open()
      local buf1 = vim.api.nvim_win_get_buf(list_win())

      vim.cmd 'close'

      assert.is_nil(list_win())
      assert.equals(-1, vim.fn.bufnr(COMMENTS_BUF))
      assert.is_nil(commentlist.row_comment(buf1, 1)) -- BufUnload で state 掃除

      local res = comments_list.open()
      assert.equals(true, res.ok)
      local buf2 = vim.api.nvim_win_get_buf(list_win())
      assert.is_not.equals(buf1, buf2)
      assert.is_not_nil(commentlist.row_comment(buf2, 1))
      assert.equals(4, #vim.api.nvim_tabpage_list_wins(review_tab()))
    end
  )

  it(
    '一覧窓を別 tab へ移した場合、open はその tab へ切替えて focus (再 vsplit しない)',
    function()
      start_done()
      add_comment {}
      comments_list.open()
      vim.cmd 'wincmd T' -- 一覧窓を新規 tab へ移す
      local moved = vim.api.nvim_get_current_tabpage()

      local res = comments_list.open()

      assert.equals(true, res.ok)
      assert.equals(moved, vim.api.nvim_get_current_tabpage())
      assert.equals(list_win(), vim.api.nvim_get_current_win())
      assert.equals(1, #vim.api.nvim_tabpage_list_wins(moved))
      assert.equals(3, #vim.api.nvim_tabpage_list_wins(review_tab()))
    end
  )

  it(
    'セッション close (q) は開いている一覧窓も閉じる (残骸の窓を残さない)',
    function()
      start_done()
      add_comment {}
      comments_list.open()
      vim.cmd 'wincmd T' -- レビュー tab 以外へ移しても close 掃除が届く
      local moved = vim.api.nvim_get_current_tabpage()
      assert.equals(1, #vim.api.nvim_tabpage_list_wins(moved))

      -- コメント 1 件なので close は [y/N] 確認 (y 応答)
      state.input_answer = 'y'
      session_handler.close()

      assert.is_nil(list_win())
      assert.is_nil(session_handler.active())
      -- 一覧が唯一の窓だった tab は窓の close で消える (窓もバッファも残さない)
      local gone = true
      for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if tab == moved then
          gone = false
        end
      end
      assert.is_true(gone)
    end
  )
end)

describe('comments_list.delete_current (一覧専用 arming)', function()
  use_env()

  local function seed_two()
    start_done()
    add_comment { file = 'a.lua', line = 1, body = 'one' }
    add_comment { file = 'a.lua', line = 2, body = 'two' }
    comments_list.open()
    focus_list_row(1)
  end

  it(
    'd: 1 回目は arming の WARN で消さず、同じ行の 2 回目で削除 + save + INFO',
    function()
      seed_two()

      comments_list.delete_current()

      assert.same({
        {
          msg = 'review.nvim: コメント c1 を削除するには、この行で d をもう一度 (取り消しは他行へ移動 / 2 秒待機 / <Esc> 押下)',
          level = vim.log.levels.WARN,
        },
      }, state.notifications)
      assert.equals(2, #session_handler.active().comments)
      assert.same({ 'a.lua:1  [c1]  one', 'a.lua:2  [c2]  two' }, list_lines())

      comments_list.delete_current()

      assert.same({
        {
          msg = 'review.nvim: コメント c1 を削除するには、この行で d をもう一度 (取り消しは他行へ移動 / 2 秒待機 / <Esc> 押下)',
          level = vim.log.levels.WARN,
        },
        { msg = 'review.nvim: コメント c1 を削除しました', level = vim.log.levels.INFO },
      }, state.notifications)
      assert.same({ 'a.lua:2  [c2]  two' }, list_lines())
      -- INV-4: ディスクの session JSON を読んで判定する (メモリ状態は見ない)
      local disk = store.load(state.repo, SLUG).data
      assert.equals(1, #disk.comments)
      assert.equals('c2', disk.comments[1].id)
    end
  )

  it('d: 2 秒窓を過ぎた 2 回目は 1 目に戻る (削除しない)', function()
    seed_two()

    local clock = 100
    comments_list._set_now(function()
      return clock
    end)
    comments_list.delete_current() -- armed (clock=100)
    clock = clock + 3 -- DELETE_ARM_WINDOW_S=2.0 を過ぎる
    comments_list.delete_current() -- 窓外 = 1 目として再 armed、まだ消えない
    assert.equals(2, #session_handler.active().comments)

    comments_list.delete_current() -- 同一窓 2 回目で削除
    assert.equals(1, #session_handler.active().comments)
  end)

  it(
    'd: diff 窓の arming とは共有しない (diff で armed でも一覧の 1 回目は消さない)',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'one' }
      comments_list.open()

      -- diff 側の arming: head 窓 (a.lua) の同じ行で d を 1 回だけ押す
      local hw = ui_windows.win 'head'
      vim.api.nvim_set_current_win(hw)
      vim.api.nvim_win_set_cursor(hw, { 1, 0 })
      comments_handler.delete_current()
      assert.equals(1, #session_handler.active().comments)

      -- 一覧の d 1 回目: diff の arming を引き継がない (まだ削除されない)
      focus_list_row(1)
      comments_list.delete_current()
      assert.equals(1, #session_handler.active().comments)
      -- diff 側の arming WARN + 一覧側の arming WARN (削除は起きていない)
      assert.same({
        {
          msg = 'review.nvim: コメント c1 を削除するには、この行で d をもう一度 (取り消しは他行へ移動 / 2 秒待機 / <Esc> 押下)',
          level = vim.log.levels.WARN,
        },
        {
          msg = 'review.nvim: コメント c1 を削除するには、この行で d をもう一度 (取り消しは他行へ移動 / 2 秒待機 / <Esc> 押下)',
          level = vim.log.levels.WARN,
        },
      }, state.notifications)

      -- 一覧の 2 回目で確定削除 (一覧側の arming が独立に効いている)
      comments_list.delete_current()
      assert.equals(0, #session_handler.active().comments)
    end
  )

  it(
    'd: 削除後のカーソルは同じ行位置の次コメント・末尾は最終行・0 件は 1 行目',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'one' }
      add_comment { file = 'a.lua', line = 2, body = 'two' }
      add_comment { file = 'a.lua', line = 3, body = 'three' }
      comments_list.open()

      -- 2 行目 (c2) を削除 -> 同じ行位置の次コメント (c3) へ
      focus_list_row(2)
      comments_list.delete_current()
      comments_list.delete_current()
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(list_win()))
      assert.same({ 'a.lua:1  [c1]  one', 'a.lua:3  [c3]  three' }, list_lines())

      -- 末尾 (c3) を削除 -> 最終行へクランプ
      focus_list_row(2)
      comments_list.delete_current()
      comments_list.delete_current()
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(list_win()))
      assert.same({ 'a.lua:1  [c1]  one' }, list_lines())

      -- 0 件 -> «コメントはありません» の 1 行目
      focus_list_row(1)
      comments_list.delete_current()
      comments_list.delete_current()
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(list_win()))
      assert.same({ 'コメントはありません' }, list_lines())
    end
  )
end)

describe('comments_list.delete_all_current (一覧専用の一括 arming)', function()
  use_env()

  local function seed_open()
    start_done()
    add_comment { file = 'a.lua', line = 1, body = 'one' }
    add_comment { file = 'a.lua', line = 2, body = 'two', state = 'outdated' }
    comments_list.open()
    focus_list_row(1)
  end

  it(
    'D: 1 回目は arming の WARN で消さず、2 回目で全件削除 + save + «コメントはありません»',
    function()
      seed_open()

      comments_list.delete_all_current()
      assert.same({
        {
          msg = 'review.nvim: コメント全 2 件を削除するには、もう一度押してください (取り消しは 2 秒待機 / コメントの増減 / <Esc> 押下)',
          level = vim.log.levels.WARN,
        },
      }, state.notifications)
      assert.equals(2, #session_handler.active().comments)

      comments_list.delete_all_current()
      assert.same({
        {
          msg = 'review.nvim: コメント全 2 件を削除するには、もう一度押してください (取り消しは 2 秒待機 / コメントの増減 / <Esc> 押下)',
          level = vim.log.levels.WARN,
        },
        {
          msg = 'review.nvim: コメント全 2 件を削除しました',
          level = vim.log.levels.INFO,
        },
      }, state.notifications)
      assert.same({ 'コメントはありません' }, list_lines())
      -- INV-4: ディスクの session JSON が空
      assert.equals(0, #store.load(state.repo, SLUG).data.comments)
    end
  )

  it(
    'D: diff 窓の arming とは共有しない (diff で armed でも一覧の 1 回目は消さない)',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'one' }
      comments_list.open()

      -- diff 側の一括 arming を 1 回だけ立てる
      comments_handler.delete_all_arming()
      assert.equals(1, #session_handler.active().comments)

      -- 一覧の 1 回目は diff の arming を引き継がない
      focus_list_row(1)
      comments_list.delete_all_current()
      assert.equals(1, #session_handler.active().comments)

      -- 一覧の 2 回目で確定 (一覧側の arming が独立)
      comments_list.delete_all_current()
      assert.equals(0, #session_handler.active().comments)
    end
  )

  it('D: 0 件は INFO «コメントがありません» で一覧は変わらない', function()
    start_done()
    comments_list.open()
    state.notifications = {}

    comments_list.delete_all_current()

    assert.same({
      { msg = 'review.nvim: コメントがありません', level = vim.log.levels.INFO },
    }, state.notifications)
    assert.same({ 'コメントはありません' }, list_lines())
  end)
end)

describe('comments_list.<Esc> cancel_arming (一覧 arming の解除)', function()
  use_env()

  it(
    'd / D の一覧 arming を <Esc> で解除 (true + INFO)。diff 窓の状態は触らない',
    function()
      -- diff 側モジュールの arming 残骸 (別 spec・別テストから共有される) を吸う
      comments_handler.cancel_arming()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'one' }
      add_comment { file = 'a.lua', line = 2, body = 'two' }
      comments_list.open()
      focus_list_row(1)

      comments_list.delete_current() -- 一覧 d arming
      comments_list.delete_all_current() -- 一覧 D arming
      -- diff 側の arming も 1 回立てる (一覧の <Esc> が触らないことを pin する)
      comments_handler.delete_all_arming()
      state.notifications = {}

      assert.is_true(comments_list.cancel_arming())
      assert.same({
        {
          msg = 'review.nvim: 削除の arming を解除しました',
          level = vim.log.levels.INFO,
        },
      }, state.notifications)
      assert.equals(2, #session_handler.active().comments)

      -- 一覧は 1 目に戻る
      comments_list.delete_all_current()
      assert.equals(2, #session_handler.active().comments)
      -- diff の D arming は生きている (diff 側 2 回目で全消しされる)
      comments_handler.delete_all_arming()
      assert.equals(0, #session_handler.active().comments)
      -- 1 目で再 armed の一覧 D を解除、その次は false (built-in へ返す)
      assert.is_true(comments_list.cancel_arming())
      assert.is_false(comments_list.cancel_arming())
    end
  )
end)

describe('comments_list.edit_current / yank_current', function()
  use_env()

  it(
    'e: 入力 float (現 body + path:line hint) の確定で body 更新 + ディスク保存 + 追随',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 2, end_line = 2, body = 'orig' }
      comments_list.open()
      focus_list_row(1)

      comments_list.edit_current()

      -- 編集 float: 現在 body が事前入力され、title に対象行が出る
      assert.same({ 'orig' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      assert.equals(' Comment [a.lua:2]  <CR> 確定  q 閉じる ', title_text())
      type_into_float 'edited'

      -- INV-4: ディスクの session JSON を読んで body 更新を確認する
      local disk = store.load(state.repo, SLUG).data
      assert.equals(1, #disk.comments)
      assert.equals('edited', disk.comments[1].body)
      assert.same({ 'a.lua:2  [c1]  edited' }, list_lines())
    end
  )

  it(
    'e: 編集確定は一覧の delete arming を解除する (diff 窓と同じ規則)',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'orig' }
      comments_list.open()
      focus_list_row(1)

      comments_list.delete_current() -- arming
      comments_list.edit_current()
      type_into_float 'edited' -- 編集確定 = arming 解除
      comments_list.delete_current() -- 解除済み = 1 目、まだ消えない
      assert.equals(1, #session_handler.active().comments)

      comments_list.delete_current() -- 2 回目で削除
      assert.equals(0, #session_handler.active().comments)
    end
  )

  it('y: カーソル行 1 件の prompt を "0 へコピーする', function()
    start_done()
    add_comment { file = 'a.lua', line = 1, body = 'yank me' }
    comments_list.open()
    focus_list_row(1)

    comments_list.yank_current()

    assert.equals('@a.lua#L1\nyank me', vim.fn.getreg '0')
  end)

  it(
    'y: outdated 行はコピーせず INFO «outdated のためプロンプトに含めませんでした»',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'old', state = 'outdated' }
      comments_list.open()
      focus_list_row(1)
      vim.fn.setreg('0', 'sentinel')

      comments_list.yank_current()

      assert.same({
        {
          msg = 'review.nvim: outdated のためプロンプトに含めませんでした',
          level = vim.log.levels.INFO,
        },
      }, state.notifications)
      assert.equals('sentinel', vim.fn.getreg '0')
    end
  )
end)

describe('comments_list の追随 (再 render)', function()
  use_env()

  it(
    'コメント CRUD (diff 窓の c 追加) に追随して一覧が再 render される',
    function()
      start_done()
      add_comment { file = 'a.lua', line = 1, body = 'one' }
      comments_list.open()

      -- diff 窓からの追加経路 (commit_comment_change) を通す
      local hw = ui_windows.win 'head'
      vim.api.nvim_set_current_win(hw)
      vim.api.nvim_win_set_cursor(hw, { 2, 0 })
      comments_handler.add_normal()
      type_into_float 'added'

      assert.same({ 'a.lua:1  [c1]  one', 'a.lua:2  [c2]  added' }, list_lines())
    end
  )

  it('差分再取得 (refresh) に追随して一覧が再 render される', function()
    start_done()
    add_comment { file = 'a.lua', line = 1, body = 'one' }
    comments_list.open()
    assert.same({ 'a.lua:1  [c1]  one' }, list_lines())

    -- 差分がまるごと消滅する再取得 (apply_refresh が全コメントを outdated 化)
    install_git {
      function()
        return diff_ok ''
      end,
      sha(SAME_SHA),
      sha(SAME_SHA),
    }
    session_handler.refresh()

    assert.same({ 'a.lua:1  [c1]  one ⚠ outdated' }, list_lines())
    assert.equals('main..作業ツリー · 1 comment · ⚠1', vim.w[list_win()].review_winbar)
  end)

  it('絞り込み (/) の適用に追随して一覧の対象集合が変わる', function()
    start_done()
    add_comment { file = 'a.lua', line = 1, body = 'A' }
    add_comment { file = 'src/deep/new.lua', line = 1, body = 'D' }
    comments_list.open()
    assert.same({ 'src/deep/new.lua:1  [c2]  D', 'a.lua:1  [c1]  A' }, list_lines())

    state.input_answer = 'deep'
    session_handler.filter_sidebar()

    assert.same({ 'src/deep/new.lua:1  [c2]  D' }, list_lines())
  end)
end)
