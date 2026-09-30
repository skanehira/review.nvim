-- ui/commentview: `i` 全文閲覧 float の描画 (`i` 操作の統合テストは
-- handlers/comments_spec)。契約:
--   * 罫線は nvim の float border (`border='rounded'` + title) が描く固定要素。
--     buffer に罫線文字を置かない (カーソルが罫線に乗らない)
--   * 中身が窓高を超えたら buffer だけがスクロールし、border / window は動かない
--   * コメント間の区切りは内容幅いっぱいの `─` 罫線行 (行ごとに左右辺を
--     `├`/`┤` へ置換できないため。左右は border の │ がそのまま残る)
local commentview = require 'review.ui.commentview'

local function open(lines, opts)
  local win = commentview.open(lines, opts)
  local buf = vim.api.nvim_win_get_buf(win)
  return win, buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- 右寄せ pad を除いた中身
local function trimmed(line)
  return (line:gsub('%s+$', ''))
end

describe('commentview.open: nvim border + buffer 中身', function()
  local wins = {}
  after_each(function()
    for _, w in ipairs(wins) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    wins = {}
  end)

  it(
    '罫線は nvim の float border (rounded + title) が描き、buffer に罫線文字が無い',
    function()
      local win, _, lines = open({ 'a.lua:2 [c1]', 'view me' }, { title = ' Comment a.lua' })
      table.insert(wins, win)
      local cfg = vim.api.nvim_win_get_config(win)
      assert.same({ '╭', '─', '╮', '│', '╯', '─', '╰', '│' }, cfg.border)
      assert.equals(' Comment a.lua q close ', cfg.title[1][1])
      for _, line in ipairs(lines) do
        assert.is_true(line:find('│', 1, true) == nil, 'buffer に罫線 │ がある')
        assert.is_true(line:find('╭', 1, true) == nil, 'buffer に罫線 ╭ がある')
        assert.is_true(line:find('╰', 1, true) == nil, 'buffer に罫線 ╰ がある')
      end
      -- カーソルは buffer の先頭セル = 本文 (罫線は buffer 外なので乗りようがない)
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(win))
    end
  )

  it('コメント間の区切りは内容幅いっぱいの ─ 罫線行 (罫線色)', function()
    local win, buf, lines = open(
      { 'a.lua:2 [c1]', 'view me', '─', 'a.lua:2 [c2]', '[must]', 'text' },
      { title = ' Comment a.lua' }
    )
    table.insert(wins, win)
    assert.equals('', (lines[3]:gsub('─', '')))
    assert.equals(vim.api.nvim_win_get_width(win), vim.fn.strdisplaywidth(lines[3]))
    assert.is_true(vim.fn.strchars(lines[3]) > 3, '区切りが全幅展開されていない')
    local ns = vim.api.nvim_get_namespaces()['review-commentview']
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.equals(1, #marks, '区切り行以外に hl mark が付いている')
    assert.equals('FloatBorder', marks[1][4].hl_group)
    assert.equals(2, marks[1][2], '区切り行 (0-based row 2) に hl が無い')
  end)

  it(
    '中身はメタデータ行 + 本文 (左寄せ) で、長い本文は折り返し全文を欠かない',
    function()
      local body = string.rep('x', 300)
      local win, _, lines = open({ 'a.lua:1 [c1]', body }, { title = ' Comment a.lua' })
      table.insert(wins, win)
      local w = vim.api.nvim_win_get_width(win)
      for i, line in ipairs(lines) do
        assert.equals(
          w,
          vim.fn.strdisplaywidth(line),
          ('%d 行目の表示幅が窓幅と違う'):format(i)
        )
      end
      assert.equals('a.lua:1 [c1]', trimmed(lines[1]))
      -- 本文の折り返し片 (x で始まる行) を連結すると元の本文に戻る
      local joined = {}
      for _, line in ipairs(lines) do
        if line:find '^x' ~= nil then
          joined[#joined + 1] = trimmed(line)
        end
      end
      assert.is_true(#joined >= 2, '本文が折り返されていない: ' .. #joined)
      assert.equals(body, table.concat(joined))
    end
  )

  it(
    '中身が窓より短いときの空きは buffer に置かず nvim の ~ に任せる',
    function()
      local win, _, lines = open({ 'a.lua:1 [c1]', 'x' }, { title = ' Comment a.lua' })
      table.insert(wins, win)
      -- buffer は中身 2 行だけ (filler 行を持たない)。表示は border 内側の ~ が埋める
      assert.equals(2, #lines)
      assert.is_true(vim.api.nvim_win_get_height(win) > #lines, '窓高が中身と同じ')
    end
  )

  it(
    '中身が窓より長いときは buffer がスクロールし、border / window は動かない',
    function()
      local long = {}
      for i = 1, 40 do
        long[i] = 'line' .. i
      end
      local win = open(long, { title = ' Comment a.lua' })
      table.insert(wins, win)
      local before = vim.api.nvim_win_get_config(win)
      local w = vim.api.nvim_win_get_width(win)
      vim.api.nvim_win_call(win, function()
        vim.cmd 'normal! G'
      end)
      assert.is_true(vim.fn.line('w0', win) > 1, '中身がスクロールしていない')
      assert.is_true(vim.api.nvim_win_is_valid(win), 'スクロールで window が消えた')
      assert.equals(w, vim.api.nvim_win_get_width(win))
      assert.same(
        before,
        vim.api.nvim_win_get_config(win),
        '罫線・サイズ・位置が動いた'
      )
    end
  )

  it(
    '長いタイトルでも中身の幅は崩れない (切り詰めは nvim の描画)',
    function()
      local win, _, lines = open(
        { 'a.lua:1 [c1]', 'x' },
        { title = ' Comment ' .. string.rep('p', 400) }
      )
      table.insert(wins, win)
      assert.equals(vim.api.nvim_win_get_width(win), vim.fn.strdisplaywidth(lines[1]))
      assert.is_not_nil(vim.api.nvim_win_get_config(win).title)
    end
  )

  it('read-only (modifiable=false) で、q 単打で閉じる', function()
    local win, buf = open({ 'a.lua:1 [c1]', 'x' }, { title = ' Comment a.lua' })
    assert.is_false(vim.bo[buf].modifiable)
    vim.cmd 'normal q'
    assert.is_false(vim.api.nvim_win_is_valid(win), 'q で閉じていない')
  end)
end)
