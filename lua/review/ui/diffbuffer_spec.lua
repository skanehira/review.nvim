-- ui/diffbuffer: diff バッファ描画・extmark・fold (diff-review.md「diff バッファ」)。
-- 検証の中心は「コメント位置 = new 側ファイル行番号の写像」(DESIGN.md 既知の制約:
-- 変換はパーサ 1 箇所、表示行番号の漂移バグを検出するため行番号完全一致で照らす) と
-- virt text / 下線 / outdated 表示の契約。
local comment_model = require 'review.core.comment'
local core_diff = require 'review.core.diff'
local diffbuffer = require 'review.ui.diffbuffer'

local RAW_DIFF = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1,3 +1,4 @@',
  ' local a = 1',
  '+local b = 2',
  ' local c = 3',
  ' local d = 4',
  '@@ -10,2 +11,3 @@ function f()',
  ' local e = 5',
  '+local g = 6',
  ' return f',
  '',
}, '\n')

local EXPECTED_LINES = {
  '■ M a.lua +2 -0',
  '@@ -1,3 +1,4 @@',
  ' local a = 1',
  '+local b = 2',
  ' local c = 3',
  ' local d = 4',
  '@@ -10,2 +11,3 @@ function f()',
  ' local e = 5',
  '+local g = 6',
  ' return f',
}

local state = {}

-- 各テストは専用 tabpage + 単独の diff File で走る (他 spec との窓 extmark 干渉排除)。
local function use_render_env()
  before_each(function()
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    state.win = vim.api.nvim_get_current_win()
    local files = core_diff.parse(RAW_DIFF)
    state.file = files[1]
    state.session = {
      version = 1,
      id = 'main--feature',
      repo = '/repo',
      mode = 'branch',
      base = 'main',
      head = 'feature',
      pr = vim.NIL,
      worktree = vim.NIL,
      status = 'open',
      files = {},
      comments = {},
      created_at = 1,
      updated_at = 1,
    }
  end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
  end)
end

local function render()
  local buf = diffbuffer.render(state.session, state.file, { winid = state.win })
  -- foldexpr など "表示されている前提" の挙動を検証するため実際に window に載せる。
  vim.api.nvim_win_set_buf(state.win, buf)
  state.buf = buf
  return buf
end

-- review_comment ns の extmark 一覧 { {start_row, end_row, virt, hl}, ... }。
-- 同一開始行に複数の下線 extmark が載りうるので list のまま返す。
local function comment_marks(buf)
  local ns = vim.api.nvim_get_namespaces()['review_comment']
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local out = {}
  for _, m in ipairs(marks) do
    local d = m[4]
    out[#out + 1] = {
      start_row = m[2],
      end_row = d.end_row,
      virt = d.virt_text and d.virt_text[1] and d.virt_text[1][1] or nil,
      hl = d.hl_group,
      vlines = d.virt_lines,
    }
  end
  return out
end

local function thread_at(marks, row)
  -- virt_lines は行の配列で、各行は chunk { {text, hl}, ... }。text を連結して返す
  for _, m in ipairs(marks) do
    if m.start_row == row and m.vlines ~= nil then
      local out = {}
      for _, chunks in ipairs(m.vlines) do
        local text = ''
        for _, ch in ipairs(chunks) do
          text = text .. ch[1]
        end
        out[#out + 1] = text
      end
      return out
    end
  end
  return nil
end

local function virt_at(marks, row)
  for _, m in ipairs(marks) do
    if m.start_row == row and m.virt ~= nil then
      return m.virt
    end
  end
  return nil
end

local function count_starting(marks, row)
  local n = 0
  for _, m in ipairs(marks) do
    if m.start_row == row then
      n = n + 1
    end
  end
  return n
end

local function max_end_row(marks, row)
  local found = nil
  for _, m in ipairs(marks) do
    if m.start_row == row and m.end_row ~= nil and (found == nil or m.end_row > found) then
      found = m.end_row
    end
  end
  return found
end

describe('diffbuffer.render 描画', function()
  use_render_env()

  it(
    'ヘッダ + hunk 行 + 本文の完全一致で、buffer 名/filetype/meta が契約通り',
    function()
      local buf = render()
      assert.same(EXPECTED_LINES, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.equals('review://diff/main--feature/a.lua', vim.api.nvim_buf_get_name(buf))
      assert.equals('diff', vim.bo[buf].filetype)
      assert.same(
        { kind = 'diff', session_id = 'main--feature', path = 'a.lua' },
        vim.b[buf].review_meta
      )
      assert.is_false(vim.bo[buf].modifiable)
    end
  )

  it(
    'wrap=off / foldmethod=expr を window に強制する (既知の制約: virt text と wrap)',
    function()
      render()
      assert.is_false(vim.wo[state.win].wrap)
      assert.equals('expr', vim.wo[state.win].foldmethod)
    end
  )

  it('b:review_winbar に refs/path/増減/コメント数が入る', function()
    local buf = render()
    assert.equals('main..feature · a.lua · +2 -0 · 0 comments', vim.b[buf].review_winbar)
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 2,
      body = 'x',
      anchor = vim.NIL,
      created_at = 1,
    })
    local buf2 = render()
    assert.equals('main..feature · a.lua · +2 -0 · 1 comment', vim.b[buf2].review_winbar)
  end)

  it(
    'binary ファイルはヘッダと (binary files differ) のみでコメント対象行が無い',
    function()
      local binfile = {
        path = 'x.png',
        status = 'M',
        binary = true,
        added = 0,
        deleted = 0,
        hunks = {},
      }
      local buf = diffbuffer.render(state.session, binfile, { winid = state.win })
      assert.same(
        { '■ M x.png +0 -0', '(binary files differ)' },
        vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      )
      assert.is_nil(diffbuffer.new_line_at(buf, 2))
    end
  )

  it(
    '再 render は行と extmark を状態から再構成する (描画を捨てて再構成)',
    function()
      comment_model.add(state.session.comments, {
        file = 'a.lua',
        line = 2,
        body = 'first',
        anchor = vim.NIL,
        created_at = 1,
      })
      local buf = render()
      assert.equals(1, #comment_marks(buf))
      -- コメントを消して再 render → mark も消える (状態の唯一の真実はセッション側)
      comment_model.remove(state.session.comments, 'c1')
      local buf2 = render()
      assert.equals(buf, buf2)
      assert.equals(0, #comment_marks(buf2))
    end
  )
end)

describe('diffbuffer 行写像 (new 側行番号 ↔ buffer 行)', function()
  use_render_env()

  it('add/context 行は new 側行番号を持ち、ヘッダ hunk 行は持たない', function()
    local buf = render()
    -- new_to_row の期待値 (hunk2 の new_start=11 が起点の累計であることまで検証)
    local expect = {
      [1] = 3,
      [2] = 4,
      [3] = 5,
      [4] = 6,
      [11] = 8,
      [12] = 9,
      [13] = 10,
    }
    for new_line, row in pairs(expect) do
      assert.equals(row, diffbuffer.row_at(buf, new_line), 'new_line=' .. new_line)
    end
    for row, new_line in pairs { [3] = 1, [4] = 2, [8] = 11, [10] = 13 } do
      assert.equals(new_line, diffbuffer.new_line_at(buf, row), 'row=' .. row)
    end
    -- ヘッダ行 / hunk 見出し行は new 側行番号を持たない (コメント不可)
    assert.is_nil(diffbuffer.new_line_at(buf, 1))
    assert.is_nil(diffbuffer.new_line_at(buf, 2))
    assert.is_nil(diffbuffer.new_line_at(buf, 7))
    assert.is_nil(diffbuffer.row_at(buf, 999))
  end)

  it('fold 判定: hunk 本文行のみ畳める (foldexpr)', function()
    render()
    assert.equals('0', tostring(diffbuffer.foldexpr(1))) -- file header
    assert.equals('0', tostring(diffbuffer.foldexpr(2))) -- hunk 見出し
    assert.equals('1', tostring(diffbuffer.foldexpr(4))) -- hunk 本文
    assert.equals('1', tostring(diffbuffer.foldexpr(9)))
    assert.equals('0', tostring(diffbuffer.foldexpr(999)))
  end)

  it(
    'new_side_text は可視 new 側行テキストを返し、非可視行は nil (anchor 生成用)',
    function()
      local buf = render()
      assert.equals('local b = 2', diffbuffer.new_side_text(buf, 2))
      assert.equals('local a = 1', diffbuffer.new_side_text(buf, 1))
      assert.is_nil(diffbuffer.new_side_text(buf, 999))
    end
  )
end)

describe('diffbuffer コメント extmark 表示', function()
  use_render_env()

  it('単一コメント: eol は 💬 1、本文は行下 thread に全文', function()
    local body = string.rep('あ', 45)
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 2,
      body = body,
      anchor = vim.NIL,
      created_at = 1,
    })
    local buf = render()
    local marks = comment_marks(buf)
    -- eol は件数表示のみ。本文は行下 thread (virt_lines) に全文出る (GitHub 風)。
    assert.same({
      start_row = 3,
      end_row = 3,
      virt = ' 💬 1',
      hl = 'ReviewCommentLine',
    }, {
      start_row = marks[1].start_row,
      end_row = marks[1].end_row,
      virt = marks[1].virt,
      hl = marks[1].hl,
    })
    assert.same({ '  [c1] ' .. string.rep('あ', 45) }, thread_at(marks, 3))
  end)

  it('複数行 range コメントは先頭〜末尾行跨ぎの下線', function()
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 11,
      end_line = 12,
      body = 'span',
      anchor = vim.NIL,
      created_at = 1,
    })
    local buf = render()
    local marks = comment_marks(buf)
    assert.equals(1, #marks)
    assert.equals(7, marks[1].start_row)
    assert.equals(8, marks[1].end_row)
  end)

  it('同一行複数コメントは先頭行 virt text が 💬 N になる', function()
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 2,
      body = 'one',
      anchor = vim.NIL,
      created_at = 1,
    })
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 2,
      end_line = 3,
      body = 'two spanning',
      anchor = vim.NIL,
      created_at = 1,
    })
    local buf = render()
    local marks = comment_marks(buf)
    -- 開始行 3 (0-based) に 2 本の下線、virt text は 1 本だけ 💬 2、thread は 2 件
    assert.equals(2, count_starting(marks, 3))
    assert.equals(' 💬 2', virt_at(marks, 3))
    local th2 = thread_at(marks, 3)
    assert.same({ '  [c1] one', ' ', '  [c2] two spanning' }, th2)
    assert.equals(4, max_end_row(marks, 3)) -- 2 件目の range 2..3 = row 4..5 (0-based 3..4)
  end)

  it('outdated でも行が可視なら先頭 ⚠ 付き extmark', function()
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 3,
      body = 'kept',
      anchor = vim.NIL,
      created_at = 1,
    })
    state.session.comments[1].state = 'outdated'
    local buf = render()
    local marks = comment_marks(buf)
    assert.equals(' 💬 1 (⚠1)', virt_at(marks, 4))
    assert.equals('⚠ [c1] kept', thread_at(marks, 4)[1])
  end)

  it('thread は 10 行で打ち切り、全文は i 窓へ導線を残す', function()
    local long = {}
    for i = 1, 13 do
      long[#long + 1] = 'line' .. i
    end
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 3,
      body = table.concat(long, '\n'),
      anchor = vim.NIL,
      created_at = 1,
    })
    local buf = render()
    local th = thread_at(comment_marks(buf), 4)
    assert.equals('  [c1] line1', th[1])
    assert.equals('       line10', th[10])
    assert.equals('       … (i で全文)', th[11])
    assert.equals(11, #th)
  end)

  it('複数行本文は continuation 行にインデントを揃える', function()
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 3,
      body = 'first\nsecond',
      anchor = vim.NIL,
      created_at = 1,
    })
    local buf = render()
    assert.same({ '  [c1] first', '       second' }, thread_at(comment_marks(buf), 4))
  end)

  it('複数グループの件数表示に outdated 数を含める (💬 N (⚠M))', function()
    -- 同 new 行に active + outdated の 2 件 (UX review F7: 複数だと active と
    -- 無区別になり prompt から黙って除外されるのが見えなかった)
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 2,
      body = 'mixed first',
      anchor = vim.NIL,
      created_at = 1,
    })
    comment_model.add(state.session.comments, {
      file = 'a.lua',
      line = 2,
      body = 'mixed second',
      anchor = vim.NIL,
      created_at = 2,
    })
    state.session.comments[1].state = 'outdated'
    local buf = render()
    -- 0-based row 3 = new 2 (both comments 同一行)
    assert.equals(' 💬 2 (⚠1)', virt_at(comment_marks(buf), 3))
  end)

  it(
    'outdated で行が new 側差分に存在しない分はファイルヘッダ行 virt text に一覧',
    function()
      comment_model.add(state.session.comments, {
        file = 'a.lua',
        line = 999,
        body = 'gone',
        anchor = vim.NIL,
        created_at = 1,
      })
      state.session.comments[1].state = 'outdated'
      comment_model.add(state.session.comments, {
        file = 'a.lua',
        line = 998,
        body = 'also gone',
        anchor = vim.NIL,
        created_at = 1,
      })
      state.session.comments[2].state = 'outdated'
      local buf = render()
      local marks = comment_marks(buf)
      -- new 側行に居ない outdated はファイルヘッダ行 (row 0) に集約 (カウント eol + thread 一覧)
      assert.equals(' ⚠ 2 outdated (prompt 除外中)', virt_at(marks, 0))
      assert.same({ '⚠ [c1] gone', ' ', '⚠ [c2] also gone' }, thread_at(marks, 0))
    end
  )

  it('他ファイルのコメントは描画しない (path フィルタ)', function()
    comment_model.add(state.session.comments, {
      file = 'other.lua',
      line = 2,
      body = 'elsewhere',
      anchor = vim.NIL,
      created_at = 1,
    })
    local buf = render()
    assert.equals(0, #comment_marks(buf))
  end)
end)

describe('diffbuffer キーマップ', function()
  use_render_env()

  it('diff キー (c/e/d/y/o/q/<F1>) が buffer-local に silent nowait で付く', function()
    local buf = render()
    local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
    local lhs = {}
    for _, m in ipairs(maps) do
      lhs[m.lhs] = true
    end
    for _, key in ipairs { 'c', 'e', 'd', 'y', 'o', 'q', '<F1>' } do
      assert.is_true(lhs[key] == true, 'missing mapping: ' .. key)
    end
    local vmaps = vim.api.nvim_buf_get_keymap(buf, 'v')
    local vlhs = {}
    for _, m in ipairs(vmaps) do
      vlhs[m.lhs] = true
    end
    assert.is_true(vlhs['c'] == true)
  end)

  it(
    'diff 全キーの rhs は実関数として解決できる (未実装 dangling rhs の検出)',
    function()
      local buf = render()
      local function check(mode, key)
        local rhs
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
          if m.lhs == key then
            rhs = m.rhs
          end
        end
        assert.is_not_nil(rhs, 'missing mapping: ' .. key)
        local mod_path, func_name = rhs:match "require%('([^']+)'%)%.([%w_]+)%("
        assert.is_not_nil(mod_path, ('rhs が require 呼び出し形でない: %s'):format(key))
        local ok_mod, mod = pcall(require, mod_path)
        assert.is_true(ok_mod, 'rhs の require が解決できない: ' .. mod_path)
        assert.equals(
          'function',
          type(mod[func_name]),
          ('%s.%s が関数として解決できない (key=%s)'):format(mod_path, func_name, key)
        )
      end
      for _, key in ipairs { 'c', 'e', 'd', 'y', 'o', 'q', '<F1>' } do
        check('n', key)
      end
      check('v', 'c')
    end
  )
end)
