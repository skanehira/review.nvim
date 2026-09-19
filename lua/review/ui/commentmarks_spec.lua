-- ui/commentmarks: コメントの head バッファ extmark 表示 (docs/design/features/
-- diff-review.md「コメント表示 (head バッファの extmark)」)。
-- 契約の要点:
--   * 見出し (eol 件数) と行下スレッド (virt_lines) は 1 extmark に併合する
--     (同一位置に mark を二つ作ると取得順不定で spec 契約にできない — 実測教訓)
--   * 真実は session.comments 側に置く (apply は常に捨てて再構成)
--   * 位置を解けない outdated (= head バッファ行数を超える行) は 1 行目の
--     virt_lines_above に集約する
--   * close / 掃除では張った全バッファの namespace を明示 clear し、残骸 0 を
--     pin する (DESIGN「UI」横断規約。ユーザー窓にもスレッドは見える仕様)
local commentmarks = require 'review.ui.commentmarks'

-- virt_lines の 1 行は hl の異なる chunk に分割されうる (outdated の id 接頭辞と
-- 本文の分離など)。表示文字列の契約は chunk 全体の連結で見る (chunk 数や分割位置は
-- 実装細部)。
local function line_text(chunks)
  local out = {}
  for _, chunk in ipairs(chunks or {}) do
    out[#out + 1] = chunk[1]
  end
  return table.concat(out)
end

local function comment(over)
  local c = {
    id = 'c1',
    file = 'a.lua',
    line = 2,
    end_line = 2,
    body = 'first thought',
    anchor = { before = 'line1', line = 'line2', after = 'line3' },
    state = 'active',
    created_at = 1,
  }
  for k, v in pairs(over or {}) do
    c[k] = v
  end
  return c
end

local function session_of(comments)
  return { id = 'sx', base = 'main', head = 'feature', comments = comments }
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, commentmarks.ns(), 0, -1, { details = true })
end

local state = {}

local function mk_buf(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if name ~= nil then
    vim.api.nvim_buf_set_name(buf, name)
  end
  table.insert(state.buf_list, buf)
  return buf
end

local function use_bufs()
  before_each(function()
    state = { buf_list = {} }
  end)
  after_each(function()
    commentmarks.clear_tracked()
    for _, buf in ipairs(state.buf_list) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)
end

describe('commentmarks.apply: 併合 extmark', function()
  use_bufs()

  it(
    '単一コメント = 見出し virt_text と行下 virt_lines が 1 mark に併合される',
    function()
      local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/a.lua')
      commentmarks.apply(session_of { comment() }, buf, 'a.lua')
      -- 下線 mark を除いた「表示 mark」を探す: virt_text を持つ mark は 1 個
      local heads = {}
      for _, m in ipairs(marks(buf)) do
        if m[4].virt_text ~= nil then
          heads[#heads + 1] = m
        end
      end
      assert.equals(1, #heads, 'virt_text mark が 1 個ではない')
      local h = heads[1]
      assert.equals(1, h[2], 'row は line-1 (0-based)')
      local vt = h[4].virt_text[1][1]
      assert.is_true(
        vt:find('\u{EA6B}', 1, true) ~= nil,
        '件数 eol 表示が無い: ' .. tostring(vt)
      )
      assert.equals('ReviewPanelComment', h[4].virt_text[1][2])
      local vl = h[4].virt_lines
      assert.is_true(#vl >= 1, '行下スレッド本文が無い')
      local body = line_text(vl[1])
      assert.is_true(body:find('first thought', 1, true) ~= nil)
      assert.is_true(body:find('[c1]', 1, true) ~= nil, 'id 接頭辞が無い: ' .. body)
    end
  )

  it(
    'コメント本文は markdown 構文色を付けず、ReviewCommentBody の chunk で表示する',
    function()
      local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/md.lua')
      commentmarks.apply(
        session_of { comment { body = '**bold** and `code` 日本語' } },
        buf,
        'a.lua'
      )
      local line = nil
      for _, m in ipairs(marks(buf)) do
        if m[4].virt_text ~= nil then
          line = (m[4].virt_lines or {})[1]
        end
      end
      assert.is_not_nil(line, '行下スレッド本文が無い')
      assert.same({ { '  [c1] **bold** and `code` 日本語', 'ReviewCommentBody' } }, line)
    end
  )

  it('同一開始行の複数コメントは 1 mark に併合 (id 行 + continuation)', function()
    local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/b.lua')
    commentmarks.apply(
      session_of {
        comment { id = 'c1' },
        comment { id = 'c2', body = 'second' },
      },
      buf,
      'a.lua'
    )
    local heads = 0
    local thread_len = 0
    for _, m in ipairs(marks(buf)) do
      if m[4].virt_text ~= nil then
        heads = heads + 1
        thread_len = #(m[4].virt_lines or {})
        assert.is_true(
          m[4].virt_text[1][1]:find('\u{EA6B} 2', 1, true) ~= nil,
          m[4].virt_text[1][1]
        )
      end
    end
    assert.equals(1, heads, '併合されずに mark が二つある')
    assert.is_true(thread_len >= 2, '両コメント本文行が無い: ' .. thread_len)
  end)

  it('eol anchor + right_gravity=true: 前行挿入で mark が行に追従する', function()
    local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/c.lua')
    commentmarks.apply(session_of { comment() }, buf, 'a.lua')
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted' })
    local row = nil
    for _, m in ipairs(marks(buf)) do
      if m[4].virt_text ~= nil then
        row = m[2]
      end
    end
    assert.equals(2, row, '行移動に extmark が追従していない')
  end)

  it(
    '範囲コメント (line..end_line) は併合 mark の下線が範囲全体を覆う',
    function()
      local buf = mk_buf({ 'l1', 'l2', 'l3', 'l4' }, 'commentmarks-spec/d.lua')
      commentmarks.apply(session_of { comment { line = 2, end_line = 3 } }, buf, 'a.lua')
      local found = nil
      for _, m in ipairs(marks(buf)) do
        if m[4].hl_group == 'ReviewCommentLine' then
          found = m
        end
      end
      assert.is_not_nil(found, '下線 hl が無い')
      assert.equals(1, found[2], '開始行が line-1 でない')
      assert.equals(2, found[4].end_row, 'end_row が end_line-1 (行 2..3 を覆う) でない')
    end
  )

  it('outdated 混在群の件数表示はコメントアイコン N のみ', function()
    local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/e.lua')
    commentmarks.apply(
      session_of {
        comment(),
        comment { id = 'c2', state = 'outdated' },
      },
      buf,
      'a.lua'
    )
    local text = nil
    for _, m in ipairs(marks(buf)) do
      if m[4].virt_text then
        text = m[4].virt_text[1][1]
      end
    end
    assert.equals(' \u{EA6B} 2', text)
  end)
end)

describe('commentmarks.apply: outdated 集約', function()
  use_bufs()

  it(
    'no-changes placeholder path では全 outdated を問わない file で 1 行目に集約',
    function()
      local buf = mk_buf({ '変更なし' }, 'commentmarks-spec/f0.lua')
      commentmarks.apply(
        session_of {
          comment { file = 'a.lua', line = 5, state = 'outdated', body = 'was here' },
          comment { file = 'b.lua', line = 9, state = 'outdated', id = 'c2', body = 'gone' },
        },
        buf,
        '(no-changes)'
      )
      local above = nil
      for _, m in ipairs(marks(buf)) do
        if m[4].virt_lines_above then
          above = m
        end
      end
      assert.is_not_nil(above, 'placeholder に outdated 集約が無い')
      -- 見出し行 + 本文一覧を virt_lines_above の先頭に並べる
      -- (diff-review「コメント表示」の文言どおり eol にしない — 1 行目が実ファイルの
      -- 先頭行なので編集でずれる)
      local text = ''
      for _, chunk in ipairs(above[4].virt_lines[1] or {}) do
        text = text .. chunk[1]
      end
      assert.equals(' 2 outdated (prompt 除外中)', text)
    end
  )

  it('行番号が解けない outdated は 1 行目の virt_lines_above に集約', function()
    local buf = mk_buf({ 'only' }, 'commentmarks-spec/f.lua')
    commentmarks.apply(
      session_of {
        comment { line = 9, end_line = 9, state = 'outdated', body = 'gone place' },
        comment { line = 9, end_line = 9, state = 'outdated', id = 'c2', body = 'also gone' },
      },
      buf,
      'a.lua'
    )
    local above = nil
    for _, m in ipairs(marks(buf)) do
      if m[4].virt_lines_above then
        above = m
      end
    end
    assert.is_not_nil(above, 'virt_lines_above の集約 mark が無い')
    assert.equals(0, above[2], '集約は 1 行目 (row 0)')
    -- 見出し行 = virt_lines[1]、本文 = その続く行 (1 extmark 併合のまま)
    assert.equals(' 2 outdated (prompt 除外中)', (above[4].virt_lines[1] or { {} })[1][1])
    local joined = {}
    for i = 2, #(above[4].virt_lines or {}) do
      joined[#joined + 1] = above[4].virt_lines[i][1][1]
    end
    -- 本文行 + 区切り (continuation) 行を group thread で積む (見出しを除く 3 行)
    assert.equals(
      3,
      #joined,
      '2 件の本文 + 区切り行が集約されていない: ' .. vim.inspect(joined)
    )
  end)

  it('apply は毎回全捨て再構成 (本文変更後の残 mark なし)', function()
    local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/g.lua')
    commentmarks.apply(session_of { comment() }, buf, 'a.lua')
    commentmarks.apply(session_of {}, buf, 'a.lua')
    assert.equals(0, #marks(buf), '再 apply で残骸が残った')
  end)
end)

describe(
  'commentmarks.apply: 打ち切り / continuation / outdated 本文 / path 限定',
  function()
    use_bufs()

    local function head_virt_lines(buf)
      for _, m in ipairs(marks(buf)) do
        if m[4].virt_text ~= nil then
          return m[4].virt_lines or {}, m[4].virt_text[1][1]
        end
      end
      return nil, nil
    end

    it(
      '本文は 10 行で打ち切り、11 行目に i 全文 float への導線を残す',
      function()
        local long = {}
        for i = 1, 13 do
          long[#long + 1] = 'line' .. i
        end
        local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/trunc.lua')
        commentmarks.apply(session_of { comment { body = table.concat(long, '\n') } }, buf, 'a.lua')
        local vl = head_virt_lines(buf)
        assert.equals(11, #vl, '10 行 + 導線 1 行で無い: ' .. tostring(#vl))
        assert.equals('  [c1] line1', line_text(vl[1]))
        assert.equals('       line10', line_text(vl[10]))
        assert.equals('       … (i で全文)', line_text(vl[11]))
      end
    )

    it(
      '複数行本文の continuation 行は id 接頭辞の分インデントを揃える',
      function()
        local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/cont.lua')
        commentmarks.apply(session_of { comment { body = 'first\nsecond' } }, buf, 'a.lua')
        local vl = head_virt_lines(buf)
        assert.same({ '  [c1] first', '       second' }, { line_text(vl[1]), line_text(vl[2]) })
      end
    )

    it(
      'outdated でも行が可視なら ⚠ なしの id 接頭辞 + ReviewCommentBody 本文 / 件数は N のみ',
      function()
        local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/ov.lua')
        commentmarks.apply(
          session_of { comment { state = 'outdated', body = 'kept' } },
          buf,
          'a.lua'
        )
        local vl, vt = head_virt_lines(buf)
        assert.equals(' \u{EA6B} 1', vt)
        assert.same(
          { { '  [c1] ', 'ReviewCommentOutdated' }, { 'kept', 'ReviewCommentBody' } },
          vl[1]
        )
      end
    )

    it(
      'outdated の continuation 行は警告色を id 接頭辞に限定し、本文行は ReviewCommentBody で出す',
      function()
        local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/ov2.lua')
        commentmarks.apply(
          session_of { comment { state = 'outdated', body = 'first\nsecond' } },
          buf,
          'a.lua'
        )
        local vl = head_virt_lines(buf)
        assert.same(
          { { '  [c1] ', 'ReviewCommentOutdated' }, { 'first', 'ReviewCommentBody' } },
          vl[1]
        )
        assert.same({ { '       second', 'ReviewCommentBody' } }, vl[2])
      end
    )

    it(
      'outdated の打ち切り導線は pad を本文色、文言のみ警告色にする',
      function()
        local long = {}
        for i = 1, 13 do
          long[#long + 1] = 'line' .. i
        end
        local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/ovtrunc.lua')
        commentmarks.apply(
          session_of { comment { state = 'outdated', body = table.concat(long, '\n') } },
          buf,
          'a.lua'
        )
        local vl = head_virt_lines(buf)
        assert.same(
          { { '       ', 'ReviewCommentBody' }, { '… (i で全文)', 'ReviewCommentOutdated' } },
          vl[11]
        )
      end
    )

    it('他ファイルのコメントは張らない (path フィルタ)', function()
      local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/pf.lua')
      commentmarks.apply(
        session_of { comment { file = 'other.lua', body = 'elsewhere' } },
        buf,
        'a.lua'
      )
      assert.equals(0, #marks(buf))
    end)
  end
)

describe('commentmarks.clear_tracked: close 収集と残骸 0', function()
  use_bufs()

  it('apply した全バッファの namespace を clear して残骸 0', function()
    local b1 = mk_buf({ 'line1', 'line2' }, 'commentmarks-spec/h1.lua')
    local b2 = mk_buf({ 'line1', 'line2' }, 'commentmarks-spec/h2.lua')
    commentmarks.apply(session_of { comment() }, b1, 'a.lua')
    commentmarks.apply(session_of { comment() }, b2, 'a.lua')
    assert.is_true(#marks(b1) > 0)
    commentmarks.clear_tracked()
    assert.equals(0, #marks(b1))
    assert.equals(0, #marks(b2))
  end)
end)
