-- ui/filepanel: file panel (review://sidebar/<session>、filetype review-list) の
-- 描画・相互追従・view state (docs/design/features/diff-review.md「file panel」/
-- DESIGN.md「file panel 表示」「UI」)。list/tree 行の組み立て自体は ui/treelist
-- が純ロジックで持つので、ここでは «バッファへの反映・hl span・カーソル・キー»
-- を検証する。末尾の describe は実 FS + 実 git の正誤表 (多段パス・同名 file/dir
-- 併存・viewed 混在・filter 併用) を全体一致で pin する。
local config = require 'review.config'
local filepanel = require 'review.ui.filepanel'
local nvim_env = require 'helpers.nvim_env'
local fixtures = require 'helpers.fixtures'

local SLUG = 'main--feature'
local BUF_NAME = 'review://sidebar/' .. SLUG

local session_stub = fixtures.session_stub

local function f(path, status, added, deleted)
  return { path = path, status = status, added = added, deleted = deleted, hunks = {} }
end

local TREE_OPTS = { base = 'main', head_display = 'working tree' }

local state = {}

-- UI 系 spec の隔離 tab パターン (AGENTS「UI 系 spec は tabnew で隔離 tab」)。
-- review://* バッファは render ごとに名前一致で再利用されるので、test 間は
-- force delete で確実に掃除する (bufhidden=wipe の残骸混入防止)。
local function use_env()
  before_each(function()
    config.reset()
    nvim_env.isolate_tab(state)
    state.win = vim.api.nvim_get_current_win()
  end)
  after_each(function()
    nvim_env.wipe_review_buffers()
    filepanel._set_icon_resolver(nil)
    nvim_env.close_tab(state.tab)
    state.win = nil
  end)
end

local function panel_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function hl_ns()
  return vim.api.nvim_get_namespaces().review_panel_hl
end

-- 窓に panel buf を张って表示状態にする (render 単体では未表示 = 開通前の実経路)。
local function show(buf)
  vim.api.nvim_win_set_buf(state.win, buf)
  return buf
end

describe('filepanel.render tree (既定)', function()
  use_env()

  local function files2()
    return { f('a.lua', 'M', 1, 0), f('src/deep/new.lua', 'A', 2, 0) }
  end

  it(
    '同一 buffer への再構成: bufnr 安定・filetype/meta・行は treelist 通り',
    function()
      local session = session_stub()
      local buf = filepanel.render(session, files2(), TREE_OPTS)
      assert.equals(BUF_NAME, vim.api.nvim_buf_get_name(buf))
      assert.equals('review-list', vim.bo[buf].filetype)
      assert.same({ kind = 'sidebar', session_id = SLUG }, vim.b[buf].review_meta)
      assert.same({
        'Changes (2)',
        'Showing changes for: main..working tree',
        'A src/deep/',
        '    A new.lua +2 -0',
        'M a.lua +1 -0',
        '',
        'Reviewed (0)',
      }, panel_lines(buf))

      -- viewed が変わっても同一 buffer を再構成する (append ではなく置換)。
      -- a.lua は Reviewed セクションへ移動する (行頭 [✓] は出さない)
      session.files['a.lua'] = { viewed = true }
      local buf2 = filepanel.render(session, files2(), TREE_OPTS)
      assert.equals(buf, buf2)
      assert.same({
        'Changes (1)',
        'Showing changes for: main..working tree',
        'A src/deep/',
        '    A new.lua +2 -0',
        '',
        'Reviewed (1)',
        'M a.lua +1 -0',
      }, panel_lines(buf2))
    end
  )

  it(
    'コメントありファイルの行にコメントアイコン (U+EA6B) が出る (session.comments から解決)',
    function()
      local session = session_stub { comments = { { file = 'a.lua', body = 'x' } } }
      local buf =
        filepanel.render(session, { f('a.lua', 'M', 1, 0), f('b.lua', 'A', 1, 0) }, TREE_OPTS)
      assert.same({
        'Changes (2)',
        'Showing changes for: main..working tree',
        'M \u{EA6B} a.lua +1 -0',
        'A b.lua +1 -0',
        '',
        'Reviewed (0)',
      }, panel_lines(buf))
    end
  )

  it(
    'コメントアイコン (U+EA6B) の hl span は ReviewPanelComment (実 extmark)',
    function()
      local session = session_stub { comments = { { file = 'a.lua', body = 'x' } } }
      local buf = filepanel.render(session, { f('a.lua', 'M', 1, 0) }, TREE_OPTS)
      local lines = panel_lines(buf)
      local found
      for _, s in ipairs(filepanel.hl_spans(buf)) do
        if s.group == 'ReviewPanelComment' then
          found = lines[s.row + 1]:sub(s.from + 1, s.to)
        end
      end
      assert.equals('\u{EA6B}', found)
    end
  )

  it(
    'hl span extmark が treelist の spans と同じ位置に入る (dir span / file span / meta)',
    function()
      local buf = filepanel.render(session_stub(), files2(), TREE_OPTS)
      local lines = panel_lines(buf)
      local by_row = {}
      for _, s in ipairs(filepanel.hl_spans(buf)) do
        local r = s.row + 1
        by_row[r] = by_row[r] or {}
        table.insert(by_row[r], {
          text = lines[r]:sub(s.from + 1, s.to),
          group = s.group,
        })
      end
      assert.same({
        { text = 'A', group = 'ReviewPanelStatus' },
        { text = 'src/deep/', group = 'ReviewPanelDir' },
      }, by_row[3])
      assert.same({
        { text = 'M', group = 'ReviewPanelStatus' },
        { text = 'a.lua', group = 'ReviewPanelFile' },
        { text = '+1', group = 'ReviewPanelAdd' },
        { text = '-0', group = 'ReviewPanelRemove' },
      }, by_row[5])

      -- 再 render で古い span extmark が残らない (捨てて再構成契約)
      filepanel.render(session_stub(), { f('other.lua', 'M', 1, 1) }, TREE_OPTS)
      local dir_marks = 0
      for _, s in ipairs(filepanel.hl_spans(buf)) do
        if s.group == 'ReviewPanelDir' then
          dir_marks = dir_marks + 1
        end
      end
      assert.equals(0, dir_marks, 'dir span extmark が再 render 後も残骸')
    end
  )

  it('選択行 hl: カーソル行に ReviewPanelSelection line hl + 窓 cursorline', function()
    -- 本番フローと同じ順: 初回 render (窓なし) -> 表示 -> refresh 相当の再 render
    local session = session_stub()
    show(filepanel.render(session, files2(), TREE_OPTS))
    local buf = filepanel.render(session, files2(), TREE_OPTS)
    vim.api.nvim_win_set_cursor(state.win, { 5, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf, modeline = false })
    local sel = filepanel.selection_mark(buf)
    assert.equals(4, sel.row)
    -- 選択行は CursorLine link の専用 group (背景を持つ ReviewPanelFile は
    -- cursorline 背景を打ち消すので選択行には張らない — issue #35)
    assert.equals('ReviewPanelSelection', sel.group)
    assert.equals(true, vim.wo[state.win].cursorline)
  end)

  it(
    'panel 窓の cursorlineopt は line (number 派ユーザーでも行が着色される)',
    function()
      -- cursorlineopt=number の環境では cursorline だけでは行背景が出ないため、
      -- panel 窓は明示で line に固定する契約 (issue #35)
      vim.wo[state.win].cursorlineopt = 'number'
      local session = session_stub()
      show(filepanel.render(session, files2(), TREE_OPTS))
      local buf = filepanel.render(session, files2(), TREE_OPTS)
      assert.equals('line', vim.wo[state.win].cursorlineopt)
      assert.equals(true, vim.wo[state.win].cursorline)
      -- 着色の素が揃っていることの陽性対照: 選択行 extmark も生きている
      vim.api.nvim_win_set_cursor(state.win, { 5, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf, modeline = false })
      assert.equals(4, filepanel.selection_mark(buf).row)
    end
  )

  it(
    'panel 窓に未表示 (開通順: render -> 窓) でも error なく buffer ができる',
    function()
      local buf = filepanel.render(session_stub(), files2(), TREE_OPTS)
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
      -- spans は extmark (buffer 資源) なので未表示でも張れている
      assert.is_true(#filepanel.hl_spans(buf) > 0)
    end
  )
end)

describe('filepanel.render list モード', function()
  use_env()

  it('mode=list は 2 セクション (viewed は Reviewed 側・行頭 [✓] なし)', function()
    local session = session_stub { files = { ['b.lua'] = { viewed = true } } }
    local buf = filepanel.render(
      session,
      { f('b.lua', 'M', 2, 1), f('src/x.lua', 'A', 1, 0) },
      { mode = 'list', base = 'main', head_display = 'working tree' }
    )
    assert.same({
      'Changes (1)',
      'A src/x.lua +1 -0',
      '',
      'Reviewed (1)',
      'M b.lua +2 -1',
    }, panel_lines(buf))
  end)

  it('tree -> list 再 render も同一 buffer (mode 切替で行だけ差替わる)', function()
    local session = session_stub()
    local buf = filepanel.render(session, { f('a.lua', 'M', 1, 0) }, TREE_OPTS)
    local buf2 = filepanel.render(
      session,
      { f('a.lua', 'M', 1, 0) },
      { mode = 'list', base = 'main' }
    )
    assert.equals(buf, buf2)
    assert.same({ 'Changes (1)', 'M a.lua +1 -0', '', 'Reviewed (0)' }, panel_lines(buf2))
  end)
end)

describe('filepanel.row_entry / winbar', function()
  use_env()

  local function files2()
    return { f('a.lua', 'M', 1, 0), f('src/deep/new.lua', 'A', 2, 0) }
  end

  it('header/dir/file の行 -> データ写像 (範囲外・header は nil)', function()
    local buf = filepanel.render(session_stub(), files2(), TREE_OPTS)
    assert.is_nil(filepanel.row_entry(buf, 1))
    assert.is_nil(filepanel.row_entry(buf, 2))
    assert.same({ kind = 'dir', path = 'src/deep' }, filepanel.row_entry(buf, 3))
    assert.same({ kind = 'file', path = 'src/deep/new.lua' }, filepanel.row_entry(buf, 4))
    assert.same({ kind = 'file', path = 'a.lua' }, filepanel.row_entry(buf, 5))
    assert.is_nil(filepanel.row_entry(buf, 6))
  end)

  it('同名 file と dir の併存で行データが kind で区別できる', function()
    local buf = filepanel.render(
      session_stub(),
      { f('cmd/main.go', 'A', 2, 0), f('cmd', 'M', 1, 0) },
      TREE_OPTS
    )
    assert.same({ kind = 'dir', path = 'cmd' }, filepanel.row_entry(buf, 3))
    assert.same({ kind = 'file', path = 'cmd' }, filepanel.row_entry(buf, 5))
  end)

  it('winbar は base..head · N files · M comments [· filter] [· ⚠N]', function()
    local session = session_stub { comments = { { id = 'c1' } } }
    local files = { f('a.lua', 'M', 1, 0) }
    assert.equals('main..feature · 1 file · 1 comment', filepanel.winbar(session, files))
    assert.equals(
      'main..feature · 1 file · 1 comment · ⚠2',
      filepanel.winbar(session, files, { hidden_outdated = 2 })
    )
    assert.equals(
      'main..feature · 1 file · 1 comment · filter=a · ⚠1',
      filepanel.winbar(session, files, { filter = 'a', hidden_outdated = 1 })
    )
  end)

  it('winbar 文字列は b: 変数に持たない (窓変数 only 契約)', function()
    local session = session_stub()
    local buf = filepanel.render(session, files2(), TREE_OPTS)
    -- 対照: render が b: に置くのはセッション識別の meta だけ
    assert.same({ kind = 'sidebar', session_id = session.id }, vim.b[buf].review_meta)
    assert.is_nil(vim.b[buf].review_winbar)
  end)
end)

describe('filepanel カーソル追従・折込 contract', function()
  use_env()

  local function files3()
    return {
      f('a.lua', 'M', 1, 0),
      f('src/deep/new.lua', 'A', 1, 0),
      f('src/deep/other.lua', 'M', 1, 1),
    }
  end

  it('opts.cursor で head 窓のファイルへ panel カーソルが逆追従する', function()
    local buf = show(filepanel.render(session_stub(), files3(), TREE_OPTS))
    filepanel.render(session_stub(), files3(), {
      base = 'main',
      head_display = 'working tree',
      cursor = { kind = 'file', path = 'src/deep/other.lua' },
    })
    assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(state.win))
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf, modeline = false })
    assert.equals(4, filepanel.selection_mark(buf).row)
  end)

  it(
    '再 render は前回選択 entry を維持する (viewed 切替で Reviewed セクションへ追従)',
    function()
      local session = session_stub()
      local buf = show(filepanel.render(session, files3(), TREE_OPTS))
      vim.api.nvim_win_set_cursor(state.win, { 6, 0 }) -- a.lua 行 (Changes)
      session.files['a.lua'] = { viewed = true }
      filepanel.render(session, files3(), TREE_OPTS)
      -- a.lua は Reviewed セクションへ移動するが、カーソルは同じ entry を追いかける
      assert.same({ 8, 0 }, vim.api.nvim_win_get_cursor(state.win))
      assert.same({ kind = 'file', path = 'a.lua' }, filepanel.row_entry(buf, 8))
    end
  )

  it('collapsed で選択 entry が隠れたら行内に clamp する', function()
    local session = session_stub()
    local buf = show(filepanel.render(session, files3(), TREE_OPTS))
    vim.api.nvim_win_set_cursor(state.win, { 5, 0 }) -- src/deep/other.lua
    filepanel.render(session, files3(), {
      base = 'main',
      head_display = 'working tree',
      collapsed = { ['src/deep'] = true },
    })
    -- 隠れた選択行は行内に clamp (Reviewed セクションが下に増えても範囲外には出ない。
    -- 旧構成 (セクションなし) では prev 行がそのまま末尾 = a.lua だったが、今は
    -- 空行 (separator) 行に留まる — 範囲内 clamp は変わらない)
    local row = vim.api.nvim_win_get_cursor(state.win)[1]
    assert.equals(5, row)
    assert.is_nil(filepanel.row_entry(buf, row)) -- separator (空行) は写像なし
  end)

  it(
    'dir 折り畳み後も dir 行が残るのでカーソルは同じ entry に留まる',
    function()
      local session = session_stub()
      local buf = show(filepanel.render(session, files3(), TREE_OPTS))
      vim.api.nvim_win_set_cursor(state.win, { 3, 0 }) -- * src/deep/ dir 行
      filepanel.render(session, files3(), {
        base = 'main',
        head_display = 'working tree',
        collapsed = { ['src/deep'] = true },
      })
      assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(state.win))
      assert.same({ kind = 'dir', path = 'src/deep' }, filepanel.row_entry(buf, 3))
      assert.equals('▸', panel_lines(buf)[3]:sub(1, #'▸'))
    end
  )
end)

describe('filepanel icon (devicons 自動検出)', function()
  use_env()

  it('_set_icon_resolver 注入時は <status> <icon> <basename>', function()
    filepanel._set_icon_resolver(function(path)
      return path:match '%.[mh]$' and 'C' or nil
    end)
    local buf =
      filepanel.render(session_stub(), { f('x.m', 'M', 1, 0), f('y.lua', 'A', 1, 0) }, TREE_OPTS)
    assert.same({
      'Changes (2)',
      'Showing changes for: main..working tree',
      'M C x.m +1 -0',
      'A y.lua +1 -0',
      '',
      'Reviewed (0)',
    }, panel_lines(buf))
  end)

  it(
    'resolver の hl は icon span のみ。ファイル名 span は無色 (=ReviewPanelFile)',
    function()
      -- diffview と同方式: icon は DevIcon* 色、basename は無色 (active のみ着色)。
      filepanel._set_icon_resolver(function(path)
        if path:match '%.lua$' then
          return 'L', 'DevIconLuaStub'
        end
        return nil
      end)
      local buf = filepanel.render(session_stub(), { f('a.lua', 'M', 1, 0) }, TREE_OPTS)
      local marks = vim.api.nvim_buf_get_extmarks(buf, hl_ns(), 0, -1, { details = true })
      local icon_hit, name_wrong = false, nil
      for _, m in ipairs(marks) do
        if m[4].hl_group == 'DevIconLuaStub' then
          -- 'M L a.lua +1 -0': icon 起点 col=2 (0-based)
          if m[3] == 2 then
            icon_hit = true
          end
        end
        -- 名前 span (col 4-9) に resolver hl が乗っていたら契約違反
        if m[3] == 4 and m[4].end_col == 9 and m[4].hl_group ~= 'ReviewPanelFile' then
          name_wrong = m[4].hl_group
        end
      end
      assert.is_true(
        icon_hit,
        'icon span に resolver hl が張られていない: ' .. vim.inspect(marks)
      )
      assert.is_nil(
        name_wrong,
        'ファイル名 span に色が張られている: ' .. tostring(name_wrong)
      )
    end
  )

  it('list モードでも icon span だけ resolver hl (file 名 span は無色)', function()
    filepanel._set_icon_resolver(function(path)
      if path:match '%.lua$' then
        return 'L', 'DevIconLuaStub'
      end
      return nil
    end)
    local buf = filepanel.render(
      session_stub(),
      { f('src/a.lua', 'M', 1, 0) },
      { mode = 'list', base = 'main', head_display = 'working tree' }
    )
    local lines = panel_lines(buf)
    assert.equals('M src/a.lua +1 -0', lines[2])
    local marks = vim.api.nvim_buf_get_extmarks(buf, hl_ns(), 0, -1, { details = true })
    local name_wrong = nil
    for _, m in ipairs(marks) do
      if m[4].hl_group == 'DevIconLuaStub' then
        name_wrong = m[4].hl_group
      end
    end
    assert.is_nil(
      name_wrong,
      'list 名に resolver hl が張られている: ' .. vim.inspect(marks)
    )
  end)

  it(
    'opts.active_path の行の basename span だけ ReviewPanelActive (diffview file.active 相当)',
    function()
      filepanel._set_icon_resolver(function(path)
        if path:match '%.lua$' then
          return 'L', 'DevIconLuaStub'
        end
        return nil
      end)
      local buf = filepanel.render(
        session_stub(),
        { f('a.lua', 'M', 1, 0), f('b.lua', 'M', 1, 0) },
        vim.tbl_extend('force', TREE_OPTS, { active_path = 'b.lua' })
      )
      local marks = vim.api.nvim_buf_get_extmarks(buf, hl_ns(), 0, -1, { details = true })
      -- 行構成 (0-based): 0=Changes, 1=subtitle, 2='M a.lua…', 3='M b.lua…'
      local active_rows, a_active, b_plain = {}, nil, nil
      for _, m in ipairs(marks) do
        if m[4].hl_group == 'ReviewPanelActive' then
          active_rows[m[2]] = true
        end
        if m[2] == 2 and m[4].hl_group == 'ReviewPanelActive' then
          a_active = true
        end
        if m[2] == 3 and m[4].hl_group == 'ReviewPanelFile' then
          b_plain = true
        end
      end
      assert.is_nil(active_rows[2], '非 active 行に active 色が付いている')
      assert.is_truthy(active_rows[3], 'active 行の basename に色が付いていない')
      assert.is_nil(a_active, '非 active 行 (a.lua) に active 色が付いている')
      assert.is_nil(b_plain, 'active 行 (b.lua) に無色 span が残っている')
    end
  )

  it(
    'devicons 不在環境 (plenary みの test rtp) ではアイコンなしのテキスト表示',
    function()
      -- runtime 依存ゼロ契約: require 失敗を exceptions にしない (無音で無 icon)
      assert.is_not_nil(pcall(require, 'review.ui.filepanel'))
      local buf = filepanel.render(session_stub(), { f('x.m', 'M', 1, 0) }, TREE_OPTS)
      local lines = panel_lines(buf)
      assert.equals('M x.m +1 -0', lines[3])
    end
  )
end)

describe('filepanel キー割り当て', function()
  use_env()

  it(
    'g? / <F1> で help float が開く (panel 上の config 値は help が markdown 表示)',
    function()
      local buf = show(filepanel.render(session_stub(), { f('a.lua', 'M', 1, 0) }, TREE_OPTS))
      local present = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        present[m.lhs] = true
      end
      assert.is_true(present['g?'] == true, 'panel の g? が無い')
      assert.is_true(present['<F1>'] == true, 'panel の <F1> が無い')

      vim.cmd 'normal g?'
      local floats = {}
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= '' then
          floats[#floats + 1] = w
        end
      end
      assert.equals(1, #floats, 'help float が 1 枚開くこと')
      local hb = vim.api.nvim_win_get_buf(floats[1])
      assert.equals('markdown', vim.bo[hb].filetype)
      local flines = vim.api.nvim_buf_get_lines(hb, 0, -1, false)
      local found = false
      for _, l in ipairs(flines) do
        if
          l
          == '- **<CR>** open the file in the head/base windows '
            .. '(cursor stays in the panel; dir rows toggle fold)'
        then
          found = true
        end
      end
      assert.is_true(found, 'config 値の markdown 行が無い: ' .. vim.inspect(flines))
      vim.cmd 'normal q' -- help 自身の q で閉じる (現在窓 = float)
    end
  )

  it(
    'DESIGN キー表の file panel 全キーが buffer-local に張り付き rhs が実関数として解決できる',
    function()
      local buf = filepanel.render(session_stub(), { f('a.lua', 'M', 1, 0) }, TREE_OPTS)
      local by_lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        by_lhs[m.lhs] = m.rhs
      end
      -- get_keymap の lhs は <leader> 展開済みの実キーで返る (<leader>c → \c)
      local function expand_lhs(key)
        if key:sub(1, 8) == '<leader>' then
          return (vim.g.mapleader or '\\') .. key:sub(9)
        end
        return key
      end
      local k = config.get().keymaps.sidebar
      for _, name in ipairs {
        'open_diff',
        'open_file',
        'open_entry',
        'next_file',
        'prev_file',
        'first_file',
        'last_file',
        'refresh',
        'toggle_viewed',
        'filter',
        'close',
        'toggle_style',
        'comments_list',
      } do
        local lhs = k[name]
        assert.is_not_nil(lhs, 'config.keymaps.sidebar.' .. name .. ' が無い')
        local stored = expand_lhs(lhs)
        assert.is_not_nil(by_lhs[stored], 'keymap 未張付: ' .. name .. ' (' .. lhs .. ')')
        local mod_path, func_name =
          tostring(by_lhs[stored]):match "require%('([^']+)'%)%.([%w_]+)%("
        assert.is_not_nil(mod_path, 'rhs が require 呼び出し形でない: ' .. lhs)
        local ok_mod, mod = pcall(require, mod_path)
        assert.is_true(ok_mod, 'rhs の require が解決できない: ' .. mod_path)
        assert.equals(
          'function',
          type(mod[func_name]),
          ('%s.%s が関数として解決できない (key=%s)'):format(mod_path, func_name, lhs)
        )
      end
      assert.equals('i', k.toggle_style)
    end
  )

  it(
    'entry 開く <CR>/o/l は open_selected_file を指す (panel o = 開く。実ファイル o ではない)',
    function()
      local buf = filepanel.render(session_stub(), { f('a.lua', 'M', 1, 0) }, TREE_OPTS)
      local by_lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        by_lhs[m.lhs] = m.rhs
      end
      local k = config.get().keymaps.sidebar
      for _, name in ipairs { 'open_diff', 'open_file', 'open_entry' } do
        local rhs = by_lhs[k[name]]
        assert.is_not_nil(rhs, 'keymap 未張付: ' .. name)
        assert.is_true(
          rhs:find('open_selected_file', 1, true) ~= nil,
          name .. ' の rhs が open_selected_file でない: ' .. rhs
        )
      end
    end
  )

  it('移動系 <Tab>/<S-Tab>/[F/]F と R は handlers.session の対応関数を指す', function()
    local buf = filepanel.render(session_stub(), { f('a.lua', 'M', 1, 0) }, TREE_OPTS)
    local by_lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      by_lhs[m.lhs] = m.rhs
    end
    local k = config.get().keymaps.sidebar
    local want = {
      next_file = 'next_file',
      prev_file = 'prev_file',
      first_file = 'first_file',
      last_file = 'last_file',
      refresh = 'refresh',
    }
    for name, fn in pairs(want) do
      local rhs = by_lhs[k[name]]
      assert.is_not_nil(rhs, 'keymap 未張付: ' .. name .. ' (' .. k[name] .. ')')
      assert.is_true(
        rhs:find('.' .. fn .. '()', 1, true) ~= nil,
        ('%s の rhs が %s を指さない: %s'):format(name, fn, rhs)
      )
    end
  end)

  it(
    'config.keymaps.sidebar.toggle_style の override が張付キーに反映される',
    function()
      config.setup { keymaps = { sidebar = { toggle_style = 'I' } } }
      local buf = filepanel.render(session_stub(), { f('a.lua', 'M', 1, 0) }, TREE_OPTS)
      local found = false
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == 'I' then
          found = true
        end
      end
      assert.is_true(found)
    end
  )

  it(
    'i の rhs は toggle_listing_style を指す (keygate の i と衝突していない)',
    function()
      local buf = filepanel.render(session_stub(), { f('a.lua', 'M', 1, 0) }, TREE_OPTS)
      -- handlers が実在する (dangling rhs 検出は上で実施済み)。ここでは keygate 側の
      -- view_comments (head 窓の i) が panel では上書きされていること = 張付回数の契約。
      local count = 0
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if m.lhs == 'i' then
          count = count + 1
          assert.is_not_nil(m.rhs:find('toggle_listing_style', 1, true))
        end
      end
      assert.equals(1, count)
    end
  )
end)

-- ===========================================================================
-- 実 FS + 実 git 正誤表 (multi-段パス・同名 file/dir 併存・viewed 混在・filter 併用)。
-- panel_lines 全体一致 + row_entry 写像 + collapsed 反映を同時検証するので、
-- ツリー組み立て・連結・集約・行フォーマットのどれか一つ欠けても FAIL する。
-- ===========================================================================
describe('filepanel 実 FS 正誤表 (temp repo + 実 git)', function()
  local repo

  before_each(function()
    local run = function(args)
      local r = vim.system(args, { cwd = repo, text = true }):wait(10000)
      assert.equals(0, r.code, table.concat(args, ' ') .. ' -> ' .. (r.stderr or ''))
    end
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, 'p')
    local write = function(rel, body)
      if rel ~= 'cmd' then
        vim.fn.mkdir(vim.fs.dirname(vim.fs.joinpath(repo, rel)), 'p')
      end
      local fh = assert(io.open(vim.fs.joinpath(repo, rel), 'w'))
      fh:write(body)
      fh:close()
    end
    run { 'git', 'init', '-q', '-b', 'main', '.' }
    run { 'git', 'config', 'user.email', 'spec@example.com' }
    run { 'git', 'config', 'user.name', 'spec' }
    -- base 側。`cmd` はファイル (feature で削除して同名 dir に化かす =
    -- «同名のファイルと dir が同時差分に出る» は FS 上は置換でしか作れない)
    write('a.lua', 'one\n')
    write('cmd', 'base\n')
    write('src/deep/old.lua', 'one\n') -- 無変更 (差分に出ない)
    run { 'git', 'add', '-A' }
    run { 'git', 'commit', '-qm', 'base' }
    run { 'git', 'checkout', '-qb', 'feature' }
    -- feature 相当: cmd ファイル削除 + cmd/ dir 作成 (混在)/ 単一 child 連結
    os.remove(vim.fs.joinpath(repo, 'cmd'))
    write('a.lua', 'two\n')
    write('cmd/helper.go', 'package main // new\n')
    write('cmd/main.go', 'package main\n')
    write('src/deep/mid/fin.lua', 'fin\n')
    write('top.md', '# new\n')
    run { 'git', 'add', '-A' }
    run { 'git', 'commit', '-qm', 'feature' }
  end)

  after_each(function()
    vim.system({ 'rm', '-rf', repo }):wait(10000)
  end)

  it(
    'git diff 実出力 -> parse -> render の全行が正誤表と一致し行写像が引ける',
    function()
      local diff = require 'review.core.diff'
      local out = vim
        .system({ 'git', 'diff', 'main', 'feature' }, {
          cwd = repo,
          text = true,
        })
        :wait(10000)
      assert.equals(0, out.code)
      local files = diff.parse(out.stdout)

      local session = session_stub {
        repo = repo,
        files = { ['cmd/main.go'] = { viewed = true }, ['a.lua'] = { viewed = true } },
      }
      local buf = filepanel.render(session, files, TREE_OPTS)

      assert.same({
        'Changes (4)',
        'Showing changes for: main..working tree',
        -- dir 先行 (名前のバイト順: cmd < src) -> root file 昇順 (cmd < top.md。a.lua は
        -- viewed=true で Reviewed 側へ)
        'A cmd/',
        '  A helper.go +1 -0',
        'A src/deep/mid/',
        '      A fin.lua +1 -0',
        'D cmd +0 -1',
        'A top.md +1 -0',
        '',
        'Reviewed (2)',
        'A cmd/',
        '  A main.go +1 -0',
        'M a.lua +1 -1',
      }, panel_lines(buf))
      -- 行 -> entry 写像 (同名 file/dir が kind で区別できること含む: 3 dir cmd / 7 file cmd
      -- / 11 dir cmd (Reviewed) / 12 file cmd/main.go)
      assert.same({ kind = 'dir', path = 'cmd' }, filepanel.row_entry(buf, 3))
      assert.same({ kind = 'file', path = 'cmd/helper.go' }, filepanel.row_entry(buf, 4))
      assert.same({ kind = 'dir', path = 'src/deep/mid' }, filepanel.row_entry(buf, 5))
      assert.same({ kind = 'file', path = 'src/deep/mid/fin.lua' }, filepanel.row_entry(buf, 6))
      assert.same({ kind = 'file', path = 'cmd' }, filepanel.row_entry(buf, 7))
      assert.same({ kind = 'file', path = 'top.md' }, filepanel.row_entry(buf, 8))
      assert.is_nil(filepanel.row_entry(buf, 9)) -- 空行 (separator) は写像なし
      assert.is_nil(filepanel.row_entry(buf, 10)) -- Reviewed ヘッダも写像なし
      assert.same({ kind = 'dir', path = 'cmd' }, filepanel.row_entry(buf, 11))
      assert.same({ kind = 'file', path = 'cmd/main.go' }, filepanel.row_entry(buf, 12))
      assert.same({ kind = 'file', path = 'a.lua' }, filepanel.row_entry(buf, 13))

      -- collapsed: dir 先行の先頭 dir と連結 chain の dir を同時に畳む
      -- (collapsed 集合はセクション共通なので Reviewed 側の cmd/ も畳まれる)
      local buf2 = filepanel.render(session, files, {
        base = 'main',
        head_display = 'working tree',
        collapsed = { ['cmd'] = true, ['src/deep/mid'] = true },
      })
      assert.equals(buf, buf2)
      assert.same({
        'Changes (4)',
        'Showing changes for: main..working tree',
        '▸ A cmd/',
        '▸ A src/deep/mid/',
        'D cmd +0 -1',
        'A top.md +1 -0',
        '',
        'Reviewed (2)',
        '▸ A cmd/',
        'M a.lua +1 -1',
      }, panel_lines(buf2))

      -- filter 併用: 'mid' は連結 chain だけ残す (祖先 dir は自動で出る)
      local buf3 =
        filepanel.render(session, require('review.ui.treelist').visible(files, 'mid'), TREE_OPTS)
      assert.same({
        'Changes (1)',
        'Showing changes for: main..working tree',
        'A src/deep/mid/',
        '      A fin.lua +1 -0',
        '',
        'Reviewed (0)',
      }, panel_lines(buf3))
    end
  )
end)
