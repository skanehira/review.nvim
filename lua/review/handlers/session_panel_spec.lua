-- handlers/session: file panel の操作 (open_file / viewed / <Tab> <S-Tab> [F ]F /
-- drift 復旧)、絞り込み (`/`)、ツリー表示と view state (diff-review.md「file panel」)。
-- 共有の開始部品は tests/helpers/session_fixtures.lua (session_spec と同じ土俵)。
local paths = require 'review.store.paths'
local session_handler = require 'review.handlers.session'
local ui_windows = require 'review.ui.windows'
local nvim_env = require 'helpers.nvim_env'
local session_env = require 'helpers.session_env'
local sf = require 'helpers.session_fixtures'

local SLUG = sf.SLUG
local RAW_DIFF_A_B = sf.RAW_DIFF_A_B
local state = sf.state
local install_git = sf.install_git
local top_ok = sf.top_ok
local diff_ok = sf.diff_ok
local load_saved = sf.load_saved
local has_call = sf.has_call
local panel_row_for = sf.panel_row_for
local focus_panel_file = sf.focus_panel_file
local inject_outdated = sf.inject_outdated
local use_env = sf.use_env
local RP_HEAD_MATCH = sf.RP_HEAD_MATCH
local start_done = sf.start_done
local REAL_INPUT = nvim_env.REAL_INPUT
local review_tab = session_env.review_tab
local head_buf_name = session_env.head_buf_name

-- 現在開いているファイルを panel カーソルの entry 写像から取る (deleted 等の
-- 告知 scratch では head 窓 buf 名が前のファイルのまま残るため、head_buf_name
-- ではなく移動系の契約である panel 追従から見る)。
local function panel_current_path()
  local pw = ui_windows.win 'panel'
  local buf = vim.api.nvim_win_get_buf(pw)
  local entry = require('review.ui.filepanel').row_entry(buf, vim.api.nvim_win_get_cursor(pw)[1])
  return entry ~= nil and entry.path or nil
end

describe('panel 操作 (open_file / viewed) と移動系', function()
  use_env()

  -- 移動系で「開いているファイル」= head 窓のバッファ (開通 focus は panel なので
  -- current 窓 (= panel) の buf 名は使えない — head 窓を明示する)。
  local function ex_bufname()
    local w = ui_windows.win 'head'
    return w ~= nil and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) or nil
  end

  it(
    '<CR> open は diff 窓を張り替えるがレビュー完了マークを付けない (A は head のみ)',
    function()
      start_done('main', 'feature')
      focus_panel_file 'b.lua'

      session_handler.open_selected_file()

      assert.equals(false, load_saved().files['b.lua'].viewed)
      -- b.lua は追加 (A): base 窓は閉じ、head だけの 2 窓
      assert.is_nil(ui_windows.win 'base')
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(review_tab()))
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
    'panel 起点の移動系 (<Tab>/<S-Tab>/[F/]F) も focus を panel に維持する (<CR> と同じ)',
    function()
      start_done('main', 'feature')

      -- <Tab>: 現対象 a.lua の次 = b.lua
      focus_panel_file 'a.lua'
      session_handler.next_file()
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      assert.equals(
        panel_row_for('file', 'b.lua'),
        vim.api.nvim_win_get_cursor(ui_windows.win 'panel')[1]
      )

      -- [F]: b.lua -> a.lua
      session_handler.first_file()
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
      assert.equals(state.repo .. '/a.lua', head_buf_name())
      assert.equals(
        panel_row_for('file', 'a.lua'),
        vim.api.nvim_win_get_cursor(ui_windows.win 'panel')[1]
      )

      -- ]F: a.lua -> b.lua
      session_handler.last_file()
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      assert.equals(
        panel_row_for('file', 'b.lua'),
        vim.api.nvim_win_get_cursor(ui_windows.win 'panel')[1]
      )

      -- <S-Tab>: b.lua -> a.lua
      session_handler.prev_file()
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
      assert.equals(state.repo .. '/a.lua', head_buf_name())
      assert.equals(
        panel_row_for('file', 'a.lua'),
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

      -- b.lua は追加 (A): head を再建して張り、base 窓は閉じたまま (2 窓)
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(review_tab()))
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

  it('<Tab> で次ファイルへ open_file (マークは触らない)', function()
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
      -- 開通 focus = panel なので移動系は panel 起点 (focus は panel に残る)
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
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
      -- x 後はカーソルが次のファイルへ動くので、解除は対象を再フォーカスしてから
      focus_panel_file 'b.lua'
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
        'Showing changes for: main..working tree',
        'M a.lua +1 -0',
        'A b.lua +1 -0',
        '',
        'Reviewed (0)',
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

      -- x 後はカーソルが次のファイル (b.lua) へ動くので、解除は対象を再フォーカス
      focus_panel_file 'a.lua'
      session_handler.toggle_viewed_current()
      assert.equals(false, load_saved().files['a.lua'].viewed)
    end
  )

  it(
    'x 後は diff 窓がカーソル位置の次のファイルへ張り替わる (移動済みファイルの表示が残らない)',
    function()
      start_done('main', 'feature') -- a.lua 開始 open
      assert.equals(state.repo .. '/a.lua', head_buf_name())

      focus_panel_file 'a.lua'
      session_handler.toggle_viewed_current() -- a.lua -> Reviewed、カーソルは次 = b.lua

      assert.equals(true, load_saved().files['a.lua'].viewed)
      assert.equals(state.repo .. '/b.lua', head_buf_name())
      -- focus は panel に残る (<CR>/<Tab> と同じ契約)
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
      assert.equals(
        panel_row_for('file', 'b.lua'),
        vim.api.nvim_win_get_cursor(ui_windows.win 'panel')[1]
      )
    end
  )

  it(
    'x で Reviewed セクションへ移動し、再 x で Changes へ戻る (再描画 + 両方向 + 両方向とも diff 追随)',
    function()
      start_done('main', 'feature') -- 開封だけでは Reviewed に移らない前提
      focus_panel_file 'b.lua'
      session_handler.toggle_viewed_current()

      local sb = vim.api.nvim_win_get_buf(ui_windows.win 'panel')
      assert.same({
        'Changes (1)',
        'Showing changes for: main..working tree',
        'M a.lua +1 -0',
        '',
        'Reviewed (1)',
        'A b.lua +1 -0',
      }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))

      -- カーソルは Reviewed に追従せず「表示上の次のファイル」= a.lua (b.lua は最後
      -- だったので先頭へ戻る) を指す。diff 窓も同じ a.lua へ張り替わる
      local pw = ui_windows.win 'panel'
      assert.equals(panel_row_for('file', 'a.lua'), vim.api.nvim_win_get_cursor(pw)[1])
      assert.equals(state.repo .. '/a.lua', head_buf_name())

      -- 解除方向も同様: b.lua (Reviewed) で x -> 次のファイルロジックで a.lua を指す
      focus_panel_file 'b.lua'
      session_handler.toggle_viewed_current() -- 解除方向も再描画される
      assert.same({
        'Changes (2)',
        'Showing changes for: main..working tree',
        'M a.lua +1 -0',
        'A b.lua +1 -0',
        '',
        'Reviewed (0)',
      }, vim.api.nvim_buf_get_lines(sb, 0, -1, false))
      assert.equals(panel_row_for('file', 'a.lua'), vim.api.nvim_win_get_cursor(pw)[1])
      -- 解除方向でも diff はカーソル位置の a.lua のまま (既に表示中 = 再バインドなし)
      assert.equals(state.repo .. '/a.lua', head_buf_name())
    end
  )

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
      'Showing changes for: main..working tree',
      'M a.lua +1 -0',
      '',
      'Reviewed (0)',
    }, panel_lines())
    assert.equals('main..feature · 1 file · 0 comments · filter=a.lua', panel_winbar())
  end)

  it('空入力で解除 (全行戻る・winbar から filter 消える)', function()
    start_done('main', 'feature')
    inputs.result = 'a.lua'
    session_handler.filter_sidebar()
    assert.equals(5, #panel_lines())
    inputs.result = ''
    session_handler.filter_sidebar()
    assert.equals(6, #panel_lines())
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
      'Showing changes for: main..working tree',
      'M a.lua +1 -0',
      '',
      'Reviewed (0)',
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
        'main..feature · 0 files · 0 comments · filter=zzz (empty input clears)',
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
-- 3 窓構造での観測面: winbar は w:review_winbar (窓変数)、panel 行は
-- Changes / Reviewed の 2 セクション (viewed = x で Reviewed へ移動。open では移らない)
-- 表記、threads は head 実バッファ extmark、再取得で消えたファイルは files map と
-- 一覧から落ち panel winbar 末尾 ⚠N で可視化 (#16 契約、persistence-restore
-- 「anchor 検証」)。
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

-- パネル表示順先頭 (ツリーは dir 先行 = app/x.lua) とパス昇順先頭 (a.txt) が
-- 乖離する差分 (開始時初期開きの対象が「パネルの一番上」であることの pin 用)。
local RAW_DIFF_PANEL_FIRST = table.concat({
  'diff --git a/a.txt b/a.txt',
  'index 111..222 100644',
  '--- a/a.txt',
  '+++ b/a.txt',
  '@@ -1 +1,2 @@',
  ' line1',
  '+line2',
  'diff --git a/app/x.lua b/app/x.lua',
  'index 333..444 100644',
  '--- a/app/x.lua',
  '+++ b/app/x.lua',
  '@@ -1 +1,2 @@',
  ' x1',
  '+x2',
  'diff --git a/z.txt b/z.txt',
  'index 555..666 100644',
  '--- a/z.txt',
  '+++ b/z.txt',
  '@@ -1 +1,2 @@',
  ' z1',
  '+z2',
  '',
}, '\n')

local function start_panel_first()
  -- head 実ファイル経路 (:edit 相当) はディスク実在が前提なので、diff に出る
  -- ファイルを自前で書き出す (use_env は root の a.lua 等しか作らない)。
  local app = vim.fs.joinpath(state.repo, 'app')
  vim.fn.mkdir(app, 'p')
  for _, n in ipairs { 'a.txt', 'app/x.lua', 'z.txt' } do
    local f = io.open(vim.fs.joinpath(state.repo, n), 'w')
    f:write 'line1\nline2\n'
    f:close()
  end
  install_git {
    top_ok,
    RP_HEAD_MATCH[1],
    RP_HEAD_MATCH[2],
    function()
      return diff_ok(RAW_DIFF_PANEL_FIRST)
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
    'Showing changes for: main..working tree',
    '* app/',
    '  M util/',
    '    M x.lua +1 -0',
    '  A y.lua +1 -0',
    'A cmd/',
    '  A main.go +1 -0',
    'D cmd +0 -1',
    'M z.txt +1 -0',
    '',
    'Reviewed (0)',
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

  it(
    '開始時の初期開きはパネル表示順 (ツリー上→下) の先頭ファイル (パス昇順ではない)',
    function()
      -- パス昇順先頭 = a.txt、パネル表示順先頭 = app/x.lua (dir 先行) で乖離する。
      start_panel_first()
      assert.equals('app/x.lua', panel_current_path())
      -- head 窓の current もパネル表示順先頭 (実ファイル) に張られている
      local hw = ui_windows.win 'head'
      local real = vim.uv.fs_realpath(vim.fs.joinpath(state.repo, 'app/x.lua'))
      assert.equals(real, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(hw)))
      -- 現対象が表示順先頭なので [F は no-op (初期開きと移動系が同一順序)
      session_handler.first_file()
      assert.equals('app/x.lua', panel_current_path())
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
        'Changes (5)',
        'M app/util/x.lua +1 -0',
        'A app/y.lua +1 -0',
        'D cmd +0 -1',
        'A cmd/main.go +1 -0',
        'M z.txt +1 -0',
        '',
        'Reviewed (0)',
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
        'Showing changes for: main..working tree',
        '▸ * app/',
        'A cmd/',
        '  A main.go +1 -0',
        'D cmd +0 -1',
        'M z.txt +1 -0',
        '',
        'Reviewed (0)',
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

  it(
    'x (toggle_viewed_current) は dir / ヘッダ行では無動作 (viewed はファイルの状態。file 行のトグルは陽性対照)',
    function()
      start_trees()
      local before = load_saved().files
      local pw = ui_windows.win 'panel'
      vim.api.nvim_set_current_win(pw)

      vim.api.nvim_win_set_cursor(pw, { panel_row_for('dir', 'app'), 0 })
      session_handler.toggle_viewed_current()
      vim.api.nvim_win_set_cursor(pw, { 1, 0 }) -- «Changes (N)» ヘッダ行
      session_handler.toggle_viewed_current()

      -- ガード除去なら dir path / 行頭語が files に混入する (全体比較で検出)
      assert.same(before, load_saved().files)

      -- 陽性対照: 同じ入口の file 行トグルは効く (無条件 return の空実装を通さない)
      vim.api.nvim_win_set_cursor(pw, { panel_row_for('file', 'app/util/x.lua'), 0 })
      session_handler.toggle_viewed_current()
      assert.equals(true, load_saved().files['app/util/x.lua'].viewed)
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

  it(
    'x 後はカーソルが表示順の次のファイルを指す (dir 行を跨いで Reviewed には追従しない)',
    function()
      start_trees()
      local pw = ui_windows.win 'panel'
      vim.api.nvim_set_current_win(pw)
      vim.api.nvim_win_set_cursor(pw, { panel_row_for('file', 'app/y.lua'), 0 })
      session_handler.toggle_viewed_current()
      -- app/y.lua の下は dir cmd/ を跨いで cmd/main.go (表示順の次のファイル)
      assert.equals(panel_row_for('file', 'cmd/main.go'), vim.api.nvim_win_get_cursor(pw)[1])
      assert.equals(true, load_saved().files['app/y.lua'].viewed)
      -- diff 窓も同じ cmd/main.go へ張り替わる (focus は panel のまま)。cmd/main.go は
      -- fixture 上ディスク未実在の A なので head は削除告知 scratch になる
      assert.equals('review://deleted/' .. SLUG .. '/cmd/main.go', head_buf_name())
      assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
    end
  )

  it(
    '<C-f> / <C-b> (page_down / page_up): panel に focus したまま head (diff) 窓を半ページ分スクロール (fold は変えない)',
    function()
      -- 40 行・20 行目のみ変更の a.lua を用意する (windows_spec の陽性対照と同じ
      -- 形状: 窓 diff の fold が確実に閉じる帯 = hunk の foldcontext の外)。
      local lines = {}
      for i = 1, 40 do
        lines[i] = 'l' .. i
      end
      lines[20] = 'CHANGED-20'
      local base_lines = {}
      for i = 1, 40 do
        base_lines[i] = 'l' .. i
      end
      local f = io.open(vim.fs.joinpath(state.repo, 'a.lua'), 'w')
      f:write(table.concat(lines, '\n') .. '\n')
      f:close()
      local raw = table.concat({
        'diff --git a/a.lua b/a.lua',
        'index 1111111..2222222 100644',
        '--- a/a.lua',
        '+++ b/a.lua',
        '@@ -20,1 +20,1 @@',
        '-l20',
        '+CHANGED-20',
        '',
      }, '\n')
      install_git {
        top_ok,
        RP_HEAD_MATCH[1],
        RP_HEAD_MATCH[2],
        function()
          return diff_ok(raw)
        end,
        function(cmd)
          assert.same({ 'git', 'show', 'main:a.lua' }, cmd)
          return { code = 0, stdout = table.concat(base_lines, '\n') .. '\n', stderr = '' }
        end,
      }
      session_handler.start { base = 'main', head = 'feature' }
      local hw = ui_windows.win 'head'
      local pw = ui_windows.win 'panel'
      vim.api.nvim_win_set_cursor(hw, { 1, 0 })
      vim.api.nvim_set_current_win(pw)
      vim.api.nvim_win_set_cursor(pw, { 1, 0 })

      -- fold 状態の pin: 窓 diff の fold (hunk の foldcontext の外の帯) を閉じ、
      -- スクロール後も不変であることを確認する (旧実装の zv は押下ごとにカーソル
      -- 位置の fold を開いていた = 折りたたみが崩れる副作用)。スクロールコマンド
      -- (<C-e>/<C-y>) は fold 状態を一切変えない。foldclosed は窓ローカルなので
      -- head 窓を nvim_win_call で明示する (current は panel)。
      local function fold_state()
        return vim.api.nvim_win_call(hw, function()
          local s = {}
          for l = 1, 40 do
            local fc = vim.fn.foldclosed(l)
            if fc >= 1 then
              s[#s + 1] = fc
            end
          end
          return s
        end)
      end
      local before = fold_state()
      -- 陽性対照: 窓 diff の fold が実際に閉じていること (空なら検証が無効)
      assert.is_true(#before > 0, '窓 diff の fold が閉じていない (検証無効)')

      session_handler.page_down()
      assert.equals(
        'panel',
        ui_windows.role_of(vim.api.nvim_get_current_win()),
        'focus は panel に残る'
      )
      local row = vim.api.nvim_win_get_cursor(hw)[1]
      local w0 = vim.api.nvim_win_call(hw, function()
        return vim.fn.line 'w0'
      end)
      assert.is_true(
        w0 > 1,
        'head 窓のビューが下へスクロールしていない (w0=' .. w0 .. ')'
      )
      -- カーソルは画面外に出ないよう追従する (スクロールコマンドの標準挙動。
      -- 旧実装の zt による「カーソル行を窓先頭に」とは違う)
      assert.is_true(row > 1, 'head 窓のカーソルが追従していない (row=' .. row .. ')')
      assert.same(before, fold_state(), 'page_down が fold 状態を変えた')

      session_handler.page_up()
      assert.equals(
        'panel',
        ui_windows.role_of(vim.api.nvim_get_current_win()),
        'focus は panel に残る'
      )
      local w0b = vim.api.nvim_win_call(hw, function()
        return vim.fn.line 'w0'
      end)
      assert.is_true(w0b < w0, 'head 窓のビューが上へ戻っていない (w0=' .. w0b .. ')')
      assert.same(before, fold_state(), 'page_up が fold 状態を変えた')
    end
  )

  it('<C-f> / <C-b>: 端では clamp (head 窓は動かない)', function()
    local f = io.open(vim.fs.joinpath(state.repo, 'a.lua'), 'w')
    local lines = {}
    for i = 1, 60 do
      lines[i] = 'line' .. i
    end
    f:write(table.concat(lines, '\n') .. '\n')
    f:close()
    install_git {
      top_ok,
      RP_HEAD_MATCH[1],
      RP_HEAD_MATCH[2],
      function()
        return diff_ok(RAW_DIFF_A_B)
      end,
      function()
        return { code = 0, stdout = table.concat(lines, '\n') .. '\n', stderr = '' }
      end,
    }
    session_handler.start { base = 'main', head = 'feature' }
    local hw = ui_windows.win 'head'
    local pw = ui_windows.win 'panel'
    vim.api.nvim_set_current_win(pw)
    vim.api.nvim_win_set_cursor(pw, { 1, 0 })

    vim.api.nvim_win_set_cursor(hw, { 1, 0 })
    session_handler.page_up() -- 先頭より上 = no-op
    assert.equals(1, vim.api.nvim_win_get_cursor(hw)[1])

    vim.api.nvim_win_set_cursor(hw, { 60, 0 })
    session_handler.page_down() -- 末尾より下 = no-op
    assert.equals(60, vim.api.nvim_win_get_cursor(hw)[1])
    assert.equals('panel', ui_windows.role_of(vim.api.nvim_get_current_win()))
  end)
end)
