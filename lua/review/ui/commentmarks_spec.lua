-- ui/commentmarks: コメントの head バッファ extmark 表示 (docs/design/features/
-- diff-review.md「コメント表示 (head バッファの extmark)」)。
-- 契約の要点:
--   * 表示要素 (件数 virt_text + 行下スレッド virt_lines) は群につき 1 extmark。
--     単一行コメントは下線と併合した 1 mark、範囲コメントは下線 mark と
--     分かれた 2 mark (spec は index でなく details で mark を識別する —
--     同一位置 tie は残るため)
--   * スレッドは罫線の箱で囲まれる (各行 = 先頭 '│ ' Border + 中身 + 右寄せ pad
--     Body + ' │' Border)。spec の行完全一致は両端 chunk を除いた中身で見る
--   * 真実は session.comments 側に置く (apply は常に捨てて再構成)
--   * 位置を解けない outdated (= head バッファ行数を超える行) は 1 行目の
--     virt_lines_above に見出しを箱 1 行目にした箱で集約する
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

-- 箱行の両端 (左ボーダー chunk と右 pad + 右ボーダー chunk) を除いた中身
local function inner_chunks(line)
  local t = {}
  for i = 2, #line - 2 do
    t[#t + 1] = line[i]
  end
  return t
end

-- 箱の全行の表示文字列 (chunk 連結)
local function box_texts(vl)
  return vim.tbl_map(line_text, vl or {})
end

-- 罫線の箱の期待行 (外幅 = 内側幅 + 4)。rows は中身 (左寄せ・右は空白 pad)、
-- '├' はコメント間の区切り罫線。箱の配置そのものが表示契約なので行全体で比較する。
local function box(inner_width, rows)
  local rule = ('─'):rep(inner_width + 2)
  local out = { '┌' .. rule .. '┐' }
  for _, r in ipairs(rows) do
    if r == '├' then
      out[#out + 1] = '├' .. rule .. '┤'
    else
      out[#out + 1] = '│ ' .. r .. (' '):rep(inner_width - vim.fn.strdisplaywidth(r)) .. ' │'
    end
  end
  out[#out + 1] = '└' .. rule .. '┘'
  return out
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
      -- 件数 eol 表示 (nf-cod-comment + 件数)
      assert.same({ { ' \u{EA6B} 1', 'ReviewPanelComment' } }, h[4].virt_text)
      -- 箱: 上罫線 + メタデータ行 (id のみ) + 本文 + 下罫線
      assert.same(box(16, { '  [c1]', 'first thought' }), box_texts(h[4].virt_lines))
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
      local vl = nil
      for _, m in ipairs(marks(buf)) do
        if m[4].virt_text ~= nil then
          vl = m[4].virt_lines or {}
        end
      end
      assert.is_not_nil(vl, '行下スレッド本文が無い')
      -- 1 行目 = メタデータ行 / 2 行目 = 本文 (どちらも ReviewCommentBody)
      assert.same({ { '  [c1]', 'ReviewCommentBody' } }, inner_chunks(vl[2]))
      assert.same({ { '**bold** and `code` 日本語', 'ReviewCommentBody' } }, inner_chunks(vl[3]))
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
    local heads = {}
    for _, m in ipairs(marks(buf)) do
      if m[4].virt_text ~= nil then
        heads[#heads + 1] = m
      end
    end
    assert.equals(1, #heads, '併合されずに mark が二つある')
    assert.same({ { ' \u{EA6B} 2', 'ReviewPanelComment' } }, heads[1][4].virt_text)
    assert.same(
      box(16, { '  [c1]', 'first thought', '├', '  [c2]', 'second' }),
      box_texts(heads[1][4].virt_lines)
    )
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

describe('commentmarks.apply: 範囲コメントの anchor (最終行の下)', function()
  use_bufs()

  local function virt_text_marks(buf)
    local out = {}
    for _, m in ipairs(marks(buf)) do
      if m[4].virt_text ~= nil then
        out[#out + 1] = m
      end
    end
    return out
  end

  local function underline_marks(buf)
    local out = {}
    for _, m in ipairs(marks(buf)) do
      if m[4].hl_group == 'ReviewCommentLine' and m[4].virt_text == nil then
        out[#out + 1] = m
      end
    end
    return out
  end

  it(
    '範囲コメント (2..4) はスレッドを最終行の下に置き、下線 mark と分かれる',
    function()
      local buf = mk_buf({ 'l1', 'l2', 'l3', 'l4', 'l5' }, 'commentmarks-spec/r1.lua')
      commentmarks.apply(session_of { comment { line = 2, end_line = 4 } }, buf, 'a.lua')
      local heads = virt_text_marks(buf)
      assert.equals(1, #heads, 'スレッド mark が 1 個でない')
      assert.equals(3, heads[1][2], 'スレッドが最終行 (end_line-1) の下にない')
      local underlines = underline_marks(buf)
      assert.equals(1, #underlines, '下線 mark が 1 個でない')
      assert.equals(1, underlines[1][2], '下線が開始行 (top-1) にない')
      assert.equals(3, underlines[1][4].end_row, '下線が end_line-1 まで覆っていない')
      assert.equals(2, #marks(buf), '範囲コメントは下線とスレッドの 2 mark')
    end
  )

  it('単一行コメントは下線 + virt_text + virt_lines の 1 mark のまま', function()
    local buf = mk_buf({ 'l1', 'l2', 'l3' }, 'commentmarks-spec/r2.lua')
    commentmarks.apply(session_of { comment() }, buf, 'a.lua')
    assert.equals(1, #marks(buf), '単一行コメントの mark 数が 1 でない')
    local m = marks(buf)[1]
    assert.equals(1, m[2], 'row が line-1 でない')
    assert.equals('ReviewCommentLine', m[4].hl_group, '下線 hl が無い')
    assert.same({ { ' \u{EA6B} 1', 'ReviewPanelComment' } }, m[4].virt_text)
    assert.same(box(16, { '  [c1]', 'first thought' }), box_texts(m[4].virt_lines))
  end)

  it(
    '同じ最終行・異なる開始行の 2 件は 1 箱 (├─┤ 区切り) にまとまり、下線は 1 本',
    function()
      local buf = mk_buf({ 'l1', 'l2', 'l3', 'l4', 'l5' }, 'commentmarks-spec/r3.lua')
      commentmarks.apply(
        session_of {
          comment { line = 2, end_line = 4, body = 'first thought' },
          comment { line = 4, end_line = 4, id = 'c2', body = 'second' },
        },
        buf,
        'a.lua'
      )
      local heads = virt_text_marks(buf)
      assert.equals(1, #heads, '同じ最終行の群が 1 mark にまとまっていない')
      assert.equals(3, heads[1][2], '群の行が最終行 (end_line-1) でない')
      assert.same({ { ' \u{EA6B} 2', 'ReviewPanelComment' } }, heads[1][4].virt_text)
      local underlines = underline_marks(buf)
      assert.equals(1, #underlines, '下線が群につき 1 本でない')
      assert.equals(1, underlines[1][2], '下線の開始が min(line)-1 でない')
      assert.equals(3, underlines[1][4].end_row, '下線の終端が end_line-1 でない')
      -- 箱: 上罫線 + c1 (メタデータ + 本文) + 区切り + c2 (メタデータ + 本文) + 下罫線
      assert.same(
        box(16, { '  [c1]', 'first thought', '├', '  [c2]', 'second' }),
        box_texts(heads[1][4].virt_lines)
      )
    end
  )

  it(
    'end_line がバッファ末尾を超える範囲は末尾行に clamp され outdated に落ちない',
    function()
      local buf = mk_buf({ 'l1', 'l2', 'l3' }, 'commentmarks-spec/r4.lua')
      commentmarks.apply(session_of { comment { line = 2, end_line = 99 } }, buf, 'a.lua')
      local heads = virt_text_marks(buf)
      assert.equals(1, #heads, 'clamp された範囲のスレッド mark が無い')
      assert.equals(2, heads[1][2], 'スレッドが末尾行 (line_count-1) にない')
      local underlines = underline_marks(buf)
      assert.equals(1, #underlines, 'clamp 後の下線 mark が無い')
      assert.equals(2, underlines[1][4].end_row, '下線が末尾行まで覆っていない')
      for _, m in ipairs(marks(buf)) do
        assert.is_not_true(
          m[4].virt_lines_above == true,
          'clamp は outdated 集約に落ちてはいけない'
        )
      end
    end
  )
end)

describe('commentmarks.apply: 罫線の箱', function()
  use_bufs()

  local function row_width(chunks)
    local w = 0
    for _, chunk in ipairs(chunks) do
      w = w + vim.fn.strdisplaywidth(chunk[1])
    end
    return w
  end

  local function head_virt_lines(buf)
    for _, m in ipairs(marks(buf)) do
      if m[4].virt_text ~= nil then
        return m[4].virt_lines or {}
      end
    end
    return {}
  end

  it(
    '箱の各行は完全一致し、CJK を含む本文で右辺が揃う (pad 幅 = strdisplaywidth)',
    function()
      local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/box1.lua')
      commentmarks.apply(session_of { comment { body = '日本語\nテスト' } }, buf, 'a.lua')
      local vl = head_virt_lines(buf)
      -- 自然幅 6 (メタデータ行 '  [c1]' / 本文 '日本語' も 6) + 罫線と padding は下限 20 に底上げ
      local border = '┌' .. string.rep('─', 18) .. '┐'
      assert.same({ { border, 'ReviewCommentBorder' } }, vl[1])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { '  [c1]', 'ReviewCommentBody' },
        { string.rep(' ', 10), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[2])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { '日本語', 'ReviewCommentBody' },
        { string.rep(' ', 10), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[3])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { 'テスト', 'ReviewCommentBody' },
        { string.rep(' ', 10), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[4])
      assert.same({ { '└' .. string.rep('─', 18) .. '┘', 'ReviewCommentBorder' } }, vl[5])
      assert.equals(5, #vl)
      for i, line in ipairs(vl) do
        assert.equals(
          20,
          row_width(line),
          ('箱の %d 行目の表示幅が右辺で揃っていない'):format(i)
        )
      end
    end
  )

  it(
    'opts.width の外幅を超える本文は内側幅で折り返され、折り返し行は左寄せ (pad なし) で内側幅いっぱいを使う',
    function()
      local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/box2.lua')
      commentmarks.apply(
        session_of { comment { body = string.rep('a', 30) } },
        buf,
        'a.lua',
        { width = 24 }
      )
      local vl = head_virt_lines(buf)
      -- 内側幅 = 24 - strdisplaywidth('│ ') - strdisplaywidth(' │') = 20。
      -- メタデータ行 '  [c1]' + 本文 30 文字 = 20 + 10 の 2 表示行 (左寄せ)。
      assert.equals(5, #vl, '上罫線 + 3 行 + 下罫線でない: ' .. tostring(#vl))
      assert.same({ { '┌' .. string.rep('─', 22) .. '┐', 'ReviewCommentBorder' } }, vl[1])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { '  [c1]', 'ReviewCommentBody' },
        { string.rep(' ', 14), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[2])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { string.rep('a', 20), 'ReviewCommentBody' },
        { '', 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[3])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { string.rep('a', 10), 'ReviewCommentBody' },
        { string.rep(' ', 10), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[4])
      for i, line in ipairs(vl) do
        assert.equals(
          24,
          row_width(line),
          ('箱の %d 行目が上限幅で揃っていない'):format(i)
        )
      end
    end
  )

  it('折り返しを含めて 11 行目で … (press i for full text) に打ち切る', function()
    local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/box3.lua')
    -- 30 字の本文 6 行 = 1 行目 2 表示行 (13 + 17) + 5 行 × 2 表示行 (20 + 10)
    -- = 12 表示行 -> 10 行で打ち切り
    local body = {}
    for _ = 1, 6 do
      body[#body + 1] = string.rep('b', 30)
    end
    commentmarks.apply(
      session_of { comment { body = table.concat(body, '\n') } },
      buf,
      'a.lua',
      { width = 24 }
    )
    local vl = head_virt_lines(buf)
    assert.equals(
      14,
      #vl,
      '上罫線 + 10 行 + 打ち切り 2 行 + 下罫線でない: ' .. tostring(#vl)
    )
    -- 10 表示行目 = 5 本文行目の折り返し先頭 (左寄せで 20 文字。メタデータ行 1 +
    -- 本文 4 行 × 2 表示行 = 9 で頭打ちし、次は 5 行目の先頭)
    assert.same({ { string.rep('b', 20), 'ReviewCommentBody' } }, inner_chunks(vl[11]))
    -- 打ち切り導線は英語文言 (表示幅 25) が内側幅 20 で 2 行に折り返される (左寄せ)
    assert.same({ { '… (press i for full ', 'ReviewCommentBody' } }, inner_chunks(vl[12]))
    assert.same({ { 'text)', 'ReviewCommentBody' } }, inner_chunks(vl[13]))
  end)

  it(
    'outdated は prefix と打ち切り文言だけ ReviewCommentOutdated、罫線 chunk は ReviewCommentBorder',
    function()
      local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/box4.lua')
      local body = {}
      for i = 1, 11 do
        body[#body + 1] = 'line' .. i
      end
      commentmarks.apply(
        session_of { comment { state = 'outdated', body = table.concat(body, '\n') } },
        buf,
        'a.lua'
      )
      local vl = head_virt_lines(buf)
      -- 打ち切り導線 (表示幅 25) が 1 行で収まる自然幅 29 へ拡大。続き行は左寄せ。
      assert.same({ { '┌' .. string.rep('─', 27) .. '┐', 'ReviewCommentBorder' } }, vl[1])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { '  [c1]', 'ReviewCommentOutdated' },
        { string.rep(' ', 19), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[2])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { 'line1', 'ReviewCommentBody' },
        { string.rep(' ', 20), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[3])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { '… (press i for full text)', 'ReviewCommentOutdated' },
        { '', 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[12])
      assert.equals(
        13,
        #vl,
        '上罫線 + 10 行 + 打ち切り + 下罫線でない: ' .. tostring(#vl)
      )
      assert.equals('ReviewCommentBorder', vl[13][1][2], '下罫線 chunk が Border 色でない')
      for i, line in ipairs(vl) do
        assert.equals(
          'ReviewCommentBorder',
          line[1][2],
          ('%d 行目の先頭 chunk が Border 色でない'):format(i)
        )
        assert.equals(
          'ReviewCommentBorder',
          line[#line][2],
          ('%d 行目の末尾 chunk が Border 色でない'):format(i)
        )
        assert.equals(29, row_width(line), ('%d 行目の表示幅が揃っていない'):format(i))
      end
    end
  )

  it(
    '打ち切り導線行も内側幅で折り返され、箱の右辺からはみ出さない',
    function()
      local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/box6.lua')
      local body = {}
      for _ = 1, 11 do
        body[#body + 1] = 'a'
      end
      commentmarks.apply(
        session_of { comment { body = table.concat(body, '\n') } },
        buf,
        'a.lua',
        { width = 20 }
      )
      local vl = head_virt_lines(buf)
      -- 上限 20 で内側幅 16。打ち切り文言 (表示幅 25) も左寄せで折り返される
      assert.equals(
        14,
        #vl,
        '上罫線 + 10 行 + 打ち切り 2 行 + 下罫線でない: ' .. tostring(#vl)
      )
      assert.equals('… (press i for f', line_text(inner_chunks(vl[12])))
      assert.equals('ull text)', line_text(inner_chunks(vl[13])))
      for i, line in ipairs(vl) do
        assert.equals(
          20,
          row_width(line),
          ('箱の %d 行目が下限幅で揃っていない'):format(i)
        )
      end
    end
  )

  it(
    '解けない outdated の集約は箱で描かれ、箱 1 行目に見出しを持つ',
    function()
      local buf = mk_buf({ 'only' }, 'commentmarks-spec/box5.lua')
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
      local vl = above[4].virt_lines or {}
      -- 上罫線 + 見出し + c1 (メタデータ + 本文) + 区切り + c2 (メタデータ + 本文) + 下罫線
      assert.equals(8, #vl, '集約の箱が期待の行数でない: ' .. vim.inspect(vl))
      assert.equals('ReviewCommentBorder', vl[1][1][2], '集約の 1 行目が上罫線でない')
      -- 見出しも箱の中身行: 本文と同じく左寄せ (pad なし) で見出し文言 (警告色)
      assert.same({
        { ' 2 outdated (excluded from prompt)', 'ReviewCommentOutdated' },
      }, inner_chunks(vl[2]))
      assert.same({ { '  [c1]', 'ReviewCommentOutdated' } }, inner_chunks(vl[3]))
      assert.same({ { 'gone place', 'ReviewCommentBody' } }, inner_chunks(vl[4]))
      assert.equals(
        '├' .. ('─'):rep(36) .. '┤',
        line_text(vl[5]),
        'コメント間の区切り罫線'
      )
      assert.same({ { '  [c2]', 'ReviewCommentOutdated' } }, inner_chunks(vl[6]))
      assert.same({ { 'also gone', 'ReviewCommentBody' } }, inner_chunks(vl[7]))
      assert.equals('ReviewCommentBorder', vl[8][1][2], '集約の末行が下罫線でない')
      for i, line in ipairs(vl) do
        assert.equals(
          38,
          row_width(line),
          ('集約の箱の %d 行目が右辺で揃っていない'):format(i)
        )
      end
    end
  )

  it(
    '短い本文 1 行の箱が width の外幅で右辺揃え (全行が pad で埋まり、各行の strdisplaywidth == width)',
    function()
      local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/w1.lua')
      commentmarks.apply(session_of { comment { body = 'hi' } }, buf, 'a.lua', { width = 40 })
      local vl = head_virt_lines(buf)
      -- 外幅 40 = width そのもの (自然幅に縮まない)。メタデータ行と本文の 2 行。
      -- 内側幅 36 まで pad で埋まり、右辺が窓右端で揃う
      assert.equals(4, #vl, '上罫線 + 本文 2 行 + 下罫線でない: ' .. tostring(#vl))
      assert.same({ { '┌' .. string.rep('─', 38) .. '┐', 'ReviewCommentBorder' } }, vl[1])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { '  [c1]', 'ReviewCommentBody' },
        { string.rep(' ', 30), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[2])
      assert.same({
        { '│ ', 'ReviewCommentBorder' },
        { 'hi', 'ReviewCommentBody' },
        { string.rep(' ', 34), 'ReviewCommentBody' },
        { ' │', 'ReviewCommentBorder' },
      }, vl[3])
      assert.same({ { '└' .. string.rep('─', 38) .. '┘', 'ReviewCommentBorder' } }, vl[4])
      for i, line in ipairs(vl) do
        assert.equals(
          40,
          row_width(line),
          ('箱の %d 行目の表示幅が width の外幅で揃っていない'):format(i)
        )
      end
    end
  )

  it(
    '集約見出し行が内側幅で折り返され、見出し幅 > 内側幅の width でも箱の右辺がはみ出さない',
    function()
      local buf = mk_buf({ 'only' }, 'commentmarks-spec/w2.lua')
      commentmarks.apply(
        session_of {
          comment { line = 9, end_line = 9, state = 'outdated', body = 'gone' },
          comment { line = 9, end_line = 9, state = 'outdated', id = 'c2', body = 'also gone' },
        },
        buf,
        'a.lua',
        { width = 20 }
      )
      local above = nil
      for _, m in ipairs(marks(buf)) do
        if m[4].virt_lines_above then
          above = m
        end
      end
      assert.is_not_nil(above, 'virt_lines_above の集約 mark が無い')
      local vl = above[4].virt_lines or {}
      -- 外幅 20 = 内側幅 16。見出し (« 2 outdated (excluded from prompt)» 表示幅
      -- 34) は budget 16 で 3 行に折り返される (単語境界は考慮しない)
      assert.equals(
        10,
        #vl,
        '上罫線 + 見出し 3 行 + c1 (メタデータ + 本文) + 区切り + c2 (メタデータ + 本文) + 下罫線でない: '
          .. vim.inspect(vl)
      )
      assert.same({ { ' 2 outdated (exc', 'ReviewCommentOutdated' } }, inner_chunks(vl[2]))
      assert.same({ { 'luded from promp', 'ReviewCommentOutdated' } }, inner_chunks(vl[3]))
      assert.same({ { 't)', 'ReviewCommentOutdated' } }, inner_chunks(vl[4]))
      assert.same({ { '  [c1]', 'ReviewCommentOutdated' } }, inner_chunks(vl[5]))
      assert.same({ { 'gone', 'ReviewCommentBody' } }, inner_chunks(vl[6]))
      assert.equals('├' .. ('─'):rep(18) .. '┤', line_text(vl[7]), '区切り罫線')
      assert.same({ { '  [c2]', 'ReviewCommentOutdated' } }, inner_chunks(vl[8]))
      assert.same({ { 'also gone', 'ReviewCommentBody' } }, inner_chunks(vl[9]))
      assert.equals('ReviewCommentBorder', vl[10][1][2], '集約の末行が下罫線でない')
      for i, line in ipairs(vl) do
        assert.equals(
          20,
          row_width(line),
          ('集約の箱の %d 行目が width の外幅で揃っていない'):format(i)
        )
      end
    end
  )
end)

describe('commentmarks.apply: outdated 集約', function()
  use_bufs()

  it(
    'no-changes placeholder path では全 outdated を問わない file で 1 行目に集約',
    function()
      local buf = mk_buf({ 'No changes' }, 'commentmarks-spec/f0.lua')
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
      -- 集約は箱で描かれ、見出しは箱 1 行目 (virt_lines[2] = 上罫線の次)。
      -- eol virt_text にしない — 1 行目が実ファイルの先頭行なので編集でずれる
      assert.equals(
        'ReviewCommentBorder',
        above[4].virt_lines[1][1][2],
        '集約 1 行目が上罫線でない'
      )
      assert.same({
        { ' 2 outdated (excluded from prompt)', 'ReviewCommentOutdated' },
      }, inner_chunks(above[4].virt_lines[2]))
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
    -- 集約は箱: 上罫線 / 見出し (箱 1 行目) / 本文 (区切り罫線で分離) / 下罫線
    local vl = above[4].virt_lines or {}
    assert.equals('ReviewCommentBorder', vl[1][1][2], '集約の 1 行目が上罫線でない')
    -- 見出し行 = 左寄せの見出し文言 chunk (警告色)
    assert.equals(' 2 outdated (excluded from prompt)', inner_chunks(vl[2])[1][1])
    local joined = {}
    for i = 3, #vl - 1 do
      joined[#joined + 1] = line_text(vl[i])
    end
    -- 各コメントのメタデータ行 + 本文行 + 区切り罫線行 (見出しと下罫線を除く 5 行)
    assert.equals(
      5,
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
        -- 箱: 上罫線 + メタデータ行 + 本文 9 行 + 導線 1 行 + 下罫線
        assert.equals(
          13,
          #vl,
          '上罫線 + 10 行 + 導線 1 行 + 下罫線で無い: ' .. tostring(#vl)
        )
        assert.equals('  [c1]', line_text(inner_chunks(vl[2])))
        assert.equals('line1', line_text(inner_chunks(vl[3])))
        assert.equals('line9', line_text(inner_chunks(vl[11])))
        assert.equals('… (press i for full text)', line_text(inner_chunks(vl[12])))
      end
    )

    it(
      '複数行本文はメタデータ行の次 (2 行目) から左寄せで始まる',
      function()
        local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/cont.lua')
        commentmarks.apply(session_of { comment { body = 'first\nsecond' } }, buf, 'a.lua')
        local vl = head_virt_lines(buf)
        assert.same({ '  [c1]', 'first', 'second' }, {
          line_text(inner_chunks(vl[2])),
          line_text(inner_chunks(vl[3])),
          line_text(inner_chunks(vl[4])),
        })
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
        assert.same({ { '  [c1]', 'ReviewCommentOutdated' } }, inner_chunks(vl[2]))
        assert.same({ { 'kept', 'ReviewCommentBody' } }, inner_chunks(vl[3]))
      end
    )

    it(
      'outdated でもメタデータ行は警告色、本文行は ReviewCommentBody で出す',
      function()
        local buf = mk_buf({ 'line1', 'line2', 'line3' }, 'commentmarks-spec/ov2.lua')
        commentmarks.apply(
          session_of { comment { state = 'outdated', body = 'first\nsecond' } },
          buf,
          'a.lua'
        )
        local vl = head_virt_lines(buf)
        assert.same({ { '  [c1]', 'ReviewCommentOutdated' } }, inner_chunks(vl[2]))
        assert.same({ { 'first', 'ReviewCommentBody' } }, inner_chunks(vl[3]))
        assert.same({ { 'second', 'ReviewCommentBody' } }, inner_chunks(vl[4]))
      end
    )

    it('outdated の打ち切り導線は文言のみ警告色で左寄せする', function()
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
      assert.same({
        { '… (press i for full text)', 'ReviewCommentOutdated' },
      }, inner_chunks(vl[12]))
    end)

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

describe(
  'commentmarks: PR コメントの表示 (作者 / pending / ファイルレベル)',
  function()
    use_bufs()

    local function pr_session(comments)
      local s = session_of(comments)
      s.mode = 'pr'
      return s
    end

    local function thread_lines(buf)
      for _, m in ipairs(marks(buf)) do
        if m[4].virt_lines ~= nil then
          return m[4].virt_lines
        end
      end
      return {}
    end

    it('gh コメントは作者 login を接頭辞に表示する', function()
      local buf = mk_buf { 'line1', 'line2', 'line3' }
      local gh_c = comment { origin = 'gh', gh_id = 10, gh_user = 'octocat' }
      commentmarks.apply(pr_session { gh_c }, buf, 'a.lua')
      assert.same(box(16, { '  [octocat]', 'first thought' }), box_texts(thread_lines(buf)))
    end)

    it('gh の未 submit コメントには ⚠ マーカーを付ける', function()
      local buf = mk_buf { 'line1', 'line2', 'line3' }
      local gh_pending =
        comment { origin = 'gh', gh_id = 10, gh_user = 'octocat', gh_state = 'pending' }
      commentmarks.apply(pr_session { gh_pending }, buf, 'a.lua')
      assert.same(
        box(16, { '  [octocat \u{26A0}]', 'first thought' }),
        box_texts(thread_lines(buf))
      )
    end)

    it(
      'pr モードの local 未 push コメントには ⚠ を付ける (branch には付けない)',
      function()
        local buf = mk_buf { 'line1', 'line2', 'line3' }
        local local_pending = comment { origin = 'local', id = 'c2' }
        commentmarks.apply(pr_session { local_pending }, buf, 'a.lua')
        assert.same(box(16, { '  [c2 \u{26A0}]', 'first thought' }), box_texts(thread_lines(buf)))

        -- branch モードでは local コメントに ⚠ を付けない (旧表示のまま)
        local buf2 = mk_buf { 'line1', 'line2', 'line3' }
        commentmarks.apply(session_of { comment { origin = 'local', id = 'c2' } }, buf2, 'a.lua')
        assert.same(box(16, { '  [c2]', 'first thought' }), box_texts(thread_lines(buf2)))
      end
    )

    it(
      'ファイルレベルコメントは 1 行目上 (virt_lines_above) に [file] <path> 見出しで表示する',
      function()
        local buf = mk_buf { 'line1', 'line2' }
        local fc = comment {
          subject_type = 'file',
          origin = 'gh',
          gh_id = 20,
          gh_user = 'alice',
          line = nil,
          end_line = nil,
        }
        commentmarks.apply(pr_session { fc }, buf, 'a.lua')
        local above = {}
        for _, m in ipairs(marks(buf)) do
          if m[4].virt_lines_above == true and m[4].virt_lines ~= nil then
            above = m[4].virt_lines
          end
        end
        assert.same(box(16, { '[file] a.lua', '  [alice]', 'first thought' }), box_texts(above))
      end
    )

    it(
      'ファイルレベルと outdated 集約は 1 行目上に 2 つスタックされる',
      function()
        local buf = mk_buf { 'line1', 'line2' }
        local fc = comment {
          subject_type = 'file',
          origin = 'gh',
          gh_id = 20,
          gh_user = 'a',
          line = nil,
          end_line = nil,
        }
        local stale = comment { id = 'c9', line = 99, state = 'outdated' }
        commentmarks.apply(pr_session { fc, stale }, buf, 'a.lua')
        local above_marks = 0
        for _, m in ipairs(marks(buf)) do
          if m[4].virt_lines_above == true then
            above_marks = above_marks + 1
          end
        end
        assert.equals(2, above_marks)
      end
    )
  end
)
