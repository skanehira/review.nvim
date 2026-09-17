-- ui/commentlist: コメント一覧 (横断) の描画 (docs/design/features/comment-list.md
-- 「表示」/ docs/design/DESIGN.md 決定表「コメント一覧 (横断)」)。
-- 行の組み立て・並び (呼び出し側が渡す tree 表示順 order 起点)・hl span・winbar・
-- カーソル追従・buffer-local キーを、バッファ側の真実 (行 / extmark / meta /
-- keymap) で検証する。折畳・絞り込みの file 集合解決は order を作る handlers の
-- 責務なので、ここは order 入力に対する並びと除外規則だけを pin する。
local config = require 'review.config'
local commentlist = require 'review.ui.commentlist'

local SLUG = 'main--feature'
local BUF_NAME = 'review://comments/' .. SLUG

local state = {}

-- UI 系 spec の隔離 tab パターン (AGENTS「UI 系 spec は tabnew で隔離 tab」)。
-- review://* バッファは name 一致で再利用されるため test 間は force delete で掃除する。
local function use_env()
  before_each(function()
    config.reset()
    vim.cmd 'tabnew'
    state.tab = vim.api.nvim_get_current_tabpage()
    state.win = vim.api.nvim_get_current_win()
  end)
  after_each(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match '^review://' then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd 'tabclose!'
    end
    state.win = nil
  end)
end

local function comment(overrides)
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

local function session_stub(overrides)
  local s = {
    version = 1,
    id = SLUG,
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
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe('commentlist.render 行整形', function()
  use_env()

  it(
    'path:line[-end]  [id]  body 1 行目[ ⚠ outdated] の行と buffer 契約 (review-list / meta)',
    function()
      local session = session_stub {
        files = { ['a.lua'] = { viewed = false }, ['b.lua'] = { viewed = false } },
        comments = {
          comment { file = 'a.lua', line = 2, end_line = 2, body = 'use map' },
          comment { id = 'c2', file = 'b.lua', line = 3, end_line = 5, body = 'second\nignored' },
          comment {
            id = 'c3',
            file = 'b.lua',
            line = 7,
            end_line = 7,
            body = 'old',
            state = 'outdated',
          },
        },
      }
      local buf = commentlist.render(
        session,
        { order = { 'a.lua', 'b.lua' }, head_display = '作業ツリー' }
      )
      assert.equals(BUF_NAME, vim.api.nvim_buf_get_name(buf))
      assert.equals('review-list', vim.bo[buf].filetype)
      assert.same({ kind = 'commentlist', session_id = SLUG }, vim.b[buf].review_meta)
      assert.same({
        'a.lua:2  [c1]  use map',
        'b.lua:3-5  [c2]  second',
        'b.lua:7  [c3]  old ⚠ outdated',
      }, lines_of(buf))
    end
  )

  it(
    'body は 60 文字を超えるときだけ 60 文字 + … に切り詰める (UTF-8 非分断)',
    function()
      local long = string.rep('あ', 61)
      local exact = string.rep('い', 60)
      local session = session_stub {
        files = { ['a.lua'] = { viewed = false }, ['b.lua'] = { viewed = false } },
        comments = {
          comment { body = long },
          comment { id = 'c2', file = 'b.lua', line = 2, body = exact },
        },
      }
      local buf = commentlist.render(session, { order = { 'a.lua', 'b.lua' } })
      assert.same({
        'a.lua:1  [c1]  ' .. string.rep('あ', 60) .. '…',
        'b.lua:2  [c2]  ' .. exact,
      }, lines_of(buf))
    end
  )

  it(
    'コメント 0 件は «コメントはありません» 1 行 (空でも開ける)',
    function()
      local session = session_stub { files = { ['a.lua'] = { viewed = false } } }
      local buf = commentlist.render(session, { order = { 'a.lua' } })
      assert.same({ 'コメントはありません' }, lines_of(buf))
      assert.is_nil(commentlist.row_comment(buf, 1))
    end
  )

  it('同一 buffer への再構成 (名前一致で再利用し内容は置換)', function()
    local session = session_stub {
      files = { ['a.lua'] = { viewed = false } },
      comments = { comment { body = 'one' } },
    }
    local buf = commentlist.render(session, { order = { 'a.lua' } })
    session.comments = { comment { body = 'two' }, comment { id = 'c2', line = 4, body = 'three' } }
    local buf2 = commentlist.render(session, { order = { 'a.lua' } })
    assert.equals(buf, buf2)
    assert.same({ 'a.lua:1  [c1]  two', 'a.lua:4  [c2]  three' }, lines_of(buf2))
  end)
end)

describe('commentlist.visible_comments 並び', function()
  it(
    'order のファイル順 -> 同一ファイル内 line 昇順 -> 同一 line はセッション配列順',
    function()
      local session = session_stub {
        files = { ['a.lua'] = { viewed = false }, ['b.lua'] = { viewed = false } },
        comments = {
          comment { id = 'c1', file = 'a.lua', line = 5 },
          comment { id = 'c2', file = 'b.lua', line = 2 },
          comment { id = 'c3', file = 'a.lua', line = 2 },
          comment { id = 'c4', file = 'a.lua', line = 2 },
        },
      }
      local shown = commentlist.visible_comments(session, { 'b.lua', 'a.lua' })
      local ids = {}
      for i, c in ipairs(shown) do
        ids[i] = c.id
      end
      assert.same({ 'c2', 'c3', 'c4', 'c1' }, ids)
    end
  )

  it(
    '絞り込み外 (order に無く差分にはある) ファイルのコメントは末尾にも出さない',
    function()
      local session = session_stub {
        files = { ['a.lua'] = { viewed = false }, ['c.lua'] = { viewed = false } },
        comments = {
          comment { id = 'c1', file = 'a.lua', line = 1 },
          comment { id = 'c2', file = 'c.lua', line = 1 },
        },
      }
      local shown = commentlist.visible_comments(session, { 'a.lua' })
      local ids = {}
      for i, c in ipairs(shown) do
        ids[i] = c.id
      end
      assert.same({ 'c1' }, ids)
    end
  )

  it(
    '直近 parse の files map に無いファイルは末尾へ path 昇順 (outdated を含めて出す)',
    function()
      local session = session_stub {
        files = { ['a.lua'] = { viewed = false } },
        comments = {
          comment { id = 'c1', file = 'a.lua', line = 1 },
          comment { id = 'c2', file = 'z.lua', line = 9, state = 'outdated' },
          comment { id = 'c3', file = 'm.lua', line = 3, state = 'outdated' },
        },
      }
      local shown = commentlist.visible_comments(session, { 'a.lua' })
      local ids = {}
      for i, c in ipairs(shown) do
        ids[i] = c.id
      end
      assert.same({ 'c1', 'c3', 'c2' }, ids)
    end
  )
end)

describe('commentlist.render hl span', function()
  use_env()

  it('path span は ReviewPanelFile、outdated 印 span は ReviewCommentOutdated', function()
    local session = session_stub {
      files = { ['a.lua'] = { viewed = false } },
      comments = { comment { file = 'a.lua', line = 2, body = 'b', state = 'outdated' } },
    }
    local buf = commentlist.render(session, { order = { 'a.lua' } })
    local text = lines_of(buf)[1]
    local out_start = #text - #'⚠ outdated'
    assert.same({
      { row = 0, from = 0, to = #'a.lua', group = 'ReviewPanelFile' },
      { row = 0, from = out_start, to = #text, group = 'ReviewCommentOutdated' },
    }, commentlist.hl_spans(buf))
  end)
end)

describe('commentlist.winbar', function()
  it(
    'N = 表示行数 / 表示中 outdated が 1 件以上なら ⚠M を末尾に付ける',
    function()
      local session = session_stub()
      local shown = {
        comment { id = 'c1', state = 'active' },
        comment { id = 'c2', state = 'outdated' },
        comment { id = 'c3', state = 'outdated' },
      }
      assert.equals(
        'main..作業ツリー · 3 comments · ⚠2',
        commentlist.winbar(session, shown, { head_display = '作業ツリー' })
      )
      assert.equals(
        'main..作業ツリー · 1 comment',
        commentlist.winbar(session, { comment { id = 'c1' } }, { head_display = '作業ツリー' })
      )
      assert.equals(
        'main..作業ツリー · 0 comments',
        commentlist.winbar(session, {}, { head_display = '作業ツリー' })
      )
    end
  )

  it('scratch 縮退は ref 名を head 表示名に使う', function()
    local session = session_stub()
    assert.equals(
      'main..feature · 0 comments',
      commentlist.winbar(session, {}, { head_display = 'feature' })
    )
  end)
end)

describe('commentlist.render カーソル追従', function()
  use_env()

  local function render_shown(session)
    local buf = commentlist.render(session, { order = { 'a.lua' } })
    vim.api.nvim_win_set_buf(state.win, buf)
    return buf
  end

  it('カーソル行の comment id を再 render 後も行で追う', function()
    local session = session_stub {
      files = { ['a.lua'] = { viewed = false } },
      comments = {
        comment { id = 'c1', line = 1 },
        comment { id = 'c2', line = 2 },
        comment { id = 'c3', line = 3 },
      },
    }
    local buf = render_shown(session)
    vim.api.nvim_win_set_cursor(state.win, { 2, 0 })
    commentlist.render(session, { order = { 'a.lua' } })
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(state.win))
    assert.equals('c2', commentlist.row_comment(buf, 2).id)
  end)

  it(
    '選択行のコメントが消えたら同じ行位置の次コメント・末尾なら最終行・0 件は 1 行目',
    function()
      local session = session_stub {
        files = { ['a.lua'] = { viewed = false } },
        comments = {
          comment { id = 'c1', line = 1 },
          comment { id = 'c2', line = 2 },
          comment { id = 'c3', line = 3 },
        },
      }
      render_shown(session)
      vim.api.nvim_win_set_cursor(state.win, { 2, 0 })

      session.comments = {
        comment { id = 'c1', line = 1 },
        comment { id = 'c3', line = 3 },
      }
      commentlist.render(session, { order = { 'a.lua' } })
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(state.win))

      -- 最終行の comment が消えたら clamp (= 残る最終行)
      vim.api.nvim_win_set_cursor(state.win, { 2, 0 })
      session.comments = { comment { id = 'c1', line = 1 } }
      commentlist.render(session, { order = { 'a.lua' } })
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(state.win))

      -- 0 件は «コメントはありません» の 1 行目
      session.comments = {}
      commentlist.render(session, { order = { 'a.lua' } })
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(state.win))
    end
  )
end)

describe('commentlist の buffer-local キー', function()
  use_env()

  it(
    'config.keymaps.commentlist の jump / close が張られ rhs が実関数として解決できる',
    function()
      local session = session_stub { files = { ['a.lua'] = { viewed = false } } }
      local buf = commentlist.render(session, { order = { 'a.lua' } })
      local by_lhs = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        by_lhs[m.lhs] = m.rhs
      end
      local k = config.get().keymaps.commentlist
      for _, name in ipairs { 'jump', 'close' } do
        local lhs = k[name]
        assert.is_not_nil(lhs, 'config.keymaps.commentlist.' .. name .. ' が無い')
        local rhs = by_lhs[lhs]
        assert.is_not_nil(rhs, 'keymap 未張付: ' .. name .. ' (' .. lhs .. ')')
        local mod_path, func_name = tostring(rhs):match "require%('([^']+)'%)%.([%w_]+)%("
        assert.is_not_nil(mod_path, 'rhs が require 呼び出し形でない: ' .. lhs)
        local ok_mod, mod = pcall(require, mod_path)
        assert.is_true(ok_mod, 'rhs の require が解決できない: ' .. mod_path)
        assert.equals(
          'function',
          type(mod[func_name]),
          ('%s.%s が関数として解決できない (key=%s)'):format(mod_path, func_name, lhs)
        )
      end
    end
  )

  it('config.keymaps.commentlist.jump の override が張付キーに反映される', function()
    config.setup { keymaps = { commentlist = { jump = 'o' } } }
    local session = session_stub { files = { ['a.lua'] = { viewed = false } } }
    local buf = commentlist.render(session, { order = { 'a.lua' } })
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if m.lhs == 'o' then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)
