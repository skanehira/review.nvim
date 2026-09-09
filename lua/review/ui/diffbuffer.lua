-- diff バッファ描画・extmark・fold (docs/design/features/diff-review.md「diff バッファ」)。
-- 行番号写像 (new 側ファイル行 ↔ buffer 行) は core/diff の parse 結果の new_line だけから
-- 作る (DESIGN.md「既知の制約」: 行番号変換はパーサ起点の 1 系統に置く)。
-- コメントの真実は常に session.comments 側にあり、render は描画を捨てて再構成する
-- (「右ペインのファイル切替」エッジケース)。
-- キーマップの rhs は require を"発火時"に解決する文字列で、ui → handlers の
-- module-load 循環を避ける (読み込み順の依存を作らない)。
local config = require 'review.config'
local highlight = require 'review.ui.highlight'

local M = {}

local comment_ns = vim.api.nvim_create_namespace 'review_comment'
local diff_ns = vim.api.nvim_create_namespace 'review_diff'

-- bufnr -> { new_to_row, row_to_new, body_rows (hunk 本文の buffer 行集合), path }
local rendered = {}

-- Neovim に BufWipedout は無い。wipe でも BufUnload が走るためこれで状態を掃除する。
vim.api.nvim_create_autocmd('BufUnload', {
  callback = function(ev)
    rendered[ev.buf] = nil
  end,
})

local function buffer_for(session, file)
  local name = ('review://diff/%s/%s'):format(session.id, file.path)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

-- excerpt: 先頭 40 文字 (DESIGN 表示契約)。改行は 1 空間に縮め、溢れは … を付ける
-- (決定: 抜粋の桁計数は strcharpart の表示文字数)。
local function excerpt(body)
  local one = (body:gsub('\n', ' '))
  if vim.fn.strchars(one) > 40 then
    return vim.fn.strcharpart(one, 0, 40) .. '…'
  end
  return one
end

-- 復元時に差分がまるごと消滅しファイル単位の新側差分が無いときのプレースホルダ
-- 経路が使う擬似パス (実リポジトリのパスとは衝突しない括弧付き固定名)。
M.NO_DIFF_PATH = '(no-diff)'

-- 構築した行・写像を buffer へ反映する。
local function build_lines(file)
  local lines = { ('■ %s %s +%d -%d'):format(file.status, file.path, file.added, file.deleted) }
  local st = { new_to_row = {}, row_to_new = {}, body_rows = {}, path = file.path }
  if file.vanished then
    -- 差分消滅復元: このファイルの新側差分は無い (persistence-restore.md)。
    table.insert(lines, '変更なし')
    return lines, st
  end
  if file.binary then
    table.insert(lines, '(binary files differ)')
    return lines, st
  end
  for _, hunk in ipairs(file.hunks) do
    table.insert(lines, hunk.header)
    for _, line in ipairs(hunk.lines) do
      local prefix = line.kind == 'add' and '+' or (line.kind == 'del' and '-' or ' ')
      table.insert(lines, prefix .. line.text)
      local row = #lines
      st.body_rows[row] = true
      if line.new_line ~= nil then
        st.new_to_row[line.new_line] = row
        st.row_to_new[row] = line.new_line
      end
    end
  end
  return lines, st
end

-- buffer-local keymaps (silent nowait、DESIGN.md「操作」表)。
local function apply_keymaps(buf)
  local k = config.get().keymaps.diff
  local function map(mode, lhs, call)
    vim.api.nvim_buf_set_keymap(
      buf,
      mode,
      lhs,
      (':lua %s<CR>'):format(call),
      { noremap = true, silent = true, nowait = true }
    )
  end
  map('n', k.add_comment, "require('review.handlers.comments').add_normal()")
  map('v', k.add_comment, "require('review.handlers.comments').add_visual_marks()")
  map('n', k.edit_comment, "require('review.handlers.comments').edit_current()")
  map('n', k.delete_comment, "require('review.handlers.comments').delete_current()")
  map('n', k.open_file, "require('review.handlers.session').open_file_current()")
  map('n', k.close, "require('review.handlers.session').close_by_key()")
  map('n', k.help, "require('review.ui.help').open()")
end

--- session の file を winid に描画し bufnr を返す。opts = { winid? }。
--- 既存同名バッファがあれば再利用し、行も extmark も全面的に再構成する。
function M.render(session, file, opts)
  opts = opts or {}
  highlight.setup()
  local buf = buffer_for(session, file)

  local lines, st = build_lines(file)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'diff'
  vim.b[buf].review_meta = { kind = 'diff', session_id = session.id, path = file.path }
  rendered[buf] = st

  -- 前回描画を捨てて再構成
  vim.api.nvim_buf_clear_namespace(buf, comment_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)

  -- diff 種別の色づけ (ReviewDiff* は Syntax より前面の独立 namespace、既知の制約)。
  for row, line in ipairs(lines) do
    local hl
    local prefix = line:sub(1, 1)
    if prefix == '+' then
      hl = 'ReviewDiffAdd'
    elseif prefix == '-' then
      hl = 'ReviewDiffDelete'
    elseif line:sub(1, 2) == '@@' then
      hl = 'ReviewDiffHunk'
    end
    if hl ~= nil then
      -- extmark の end_col は行末バイト数を明示 (-1 は add_highlight 専用の記法)。
      vim.api.nvim_buf_set_extmark(buf, diff_ns, row - 1, 0, {
        end_row = row - 1,
        end_col = #line,
        hl_group = hl,
      })
    end
  end

  local outdated_hidden = {}
  local group_by_row = {}
  local visible = {}
  for _, c in ipairs(session.comments) do
    if c.file == file.path then
      local start_row = st.new_to_row[c.line]
      if start_row ~= nil then
        group_by_row[start_row] = (group_by_row[start_row] or 0) + 1
        visible[#visible + 1] = { c = c, start_row = start_row }
      elseif c.state == 'outdated' then
        outdated_hidden[#outdated_hidden + 1] = excerpt(c.body)
      end
    end
  end

  local annotated = {}
  for _, v in ipairs(visible) do
    local c = v.c
    local first = not annotated[v.start_row]
    annotated[v.start_row] = true
    local end_row = st.new_to_row[c.end_line] or v.start_row
    if end_row < v.start_row then
      end_row = v.start_row
    end
    -- virt text は開始行の group 先頭 extmark のみ: 1 件 = 40 文字抜粋、複数 = 💬 N、
    -- outdated の 1 件は先頭 ⚠ (diff-review.md「コメント表示」)。
    local annotation
    if first then
      local count = group_by_row[v.start_row]
      local excerpt_text
      if count > 1 then
        excerpt_text = ' 💬 ' .. count
      elseif c.state == 'outdated' then
        excerpt_text = ' ⚠ 💬 ' .. excerpt(c.body)
      else
        excerpt_text = ' 💬 ' .. excerpt(c.body)
      end
      annotation = excerpt_text
    end
    vim.api.nvim_buf_set_extmark(buf, comment_ns, v.start_row - 1, 0, {
      end_row = end_row - 1,
      end_col = #lines[end_row],
      hl_group = 'ReviewCommentLine',
      virt_text = annotation and { { annotation, 'Comment' } } or nil,
      virt_text_pos = 'eol',
    })
  end

  if #outdated_hidden > 0 then
    vim.api.nvim_buf_set_extmark(buf, comment_ns, 0, 0, {
      virt_text = {
        { ' ⚠ outdated: ' .. table.concat(outdated_hidden, ' | '), 'Comment' },
      },
      virt_text_pos = 'eol',
    })
  end

  if opts.winid ~= nil and vim.api.nvim_win_is_valid(opts.winid) then
    vim.wo[opts.winid].wrap = false -- extmark virt text と wrap の干渉 (既知の制約)
    vim.wo[opts.winid].foldmethod = 'expr'
    vim.wo[opts.winid].foldexpr = 'v:lua.require("review.ui.diffbuffer").foldexpr(v:lnum)'
  end

  apply_keymaps(buf)
  return buf
end

--- 復元時に差分が 0 ファイルだったときの右ペイン placeholder (persistence-restore.md
--- 「差分がまるごと消滅…UI を開く (diff バッファは『変更なし』表示)」)。
--- 行番号写像は空 = c / o 等の行参照操作は new_line nil で拒否される。
function M.render_no_changes(session, opts)
  opts = opts or {}
  highlight.setup()
  local buf = buffer_for(session, { path = M.NO_DIFF_PATH })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '変更なし' })
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'diff'
  vim.b[buf].review_meta = { kind = 'diff', session_id = session.id, path = M.NO_DIFF_PATH }
  rendered[buf] = { new_to_row = {}, row_to_new = {}, body_rows = {}, path = M.NO_DIFF_PATH }
  vim.api.nvim_buf_clear_namespace(buf, comment_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  if opts.winid ~= nil and vim.api.nvim_win_is_valid(opts.winid) then
    vim.wo[opts.winid].wrap = false -- extmark virt text と wrap の干渉 (既知の制約)
  end
  apply_keymaps(buf)
  return buf
end

--- hunk 本文行のみ fold 可能 ('1')、それ以外 '0' (foldmethod=expr と併用)。
function M.foldexpr(lnum)
  local st = rendered[vim.api.nvim_get_current_buf()]
  if st ~= nil and st.body_rows[lnum] then
    return '1'
  end
  return '0'
end

--- new 側ファイル行 -> buffer 行 (1 始まり)。差分に存在しない行は nil。
function M.row_at(bufnr, new_line)
  local st = rendered[bufnr]
  return st and st.new_to_row[new_line] or nil
end

--- buffer 行 -> new 側ファイル行。`-` 行・ヘッダ行は nil。
function M.new_line_at(bufnr, row)
  local st = rendered[bufnr]
  return st and st.row_to_new[row] or nil
end

--- hunk 本文の `-` 行 (new 側に該当行が無い) か。ヘッダ行は false
--- (pr-worktree.md「実ファイル参照」の削除行 = WARN 判定に使う)。
function M.row_is_deleted(bufnr, row)
  local st = rendered[bufnr]
  if st == nil then
    return false
  end
  return st.body_rows[row] == true and st.row_to_new[row] == nil
end

--- 可視 new 側行のファイルテキスト (anchor 生成用)。非可視なら nil。
function M.new_side_text(bufnr, new_line)
  local row = M.row_at(bufnr, new_line)
  if row == nil then
    return nil
  end
  local line = (vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {})[1]
  if line == nil then
    return nil
  end
  return line:sub(2)
end

return M
