-- diff バッファ描画・extmark・fold (docs/design/features/diff-review.md「diff バッファ」)。
-- 行番号写像 (new 側ファイル行 ↔ buffer 行) は core/diff の parse 結果の new_line だけから
-- 作る (DESIGN.md「既知の制約」: 行番号変換はパーサ起点の 1 系統に置く)。
-- コメントの真実は常に session.comments 側にあり、render は描画を捨てて再構成する
-- (「右ペインのファイル切替」エッジケース)。
-- キーマップの rhs は require を"発火時"に解決する文字列で、ui → handlers の
-- module-load 循環を避ける (読み込み順の依存を作らない)。
local config = require 'review.config'
local chrome = require 'review.ui.chrome'
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

M.NO_DIFF_PATH = '(no-diff)'

-- winbar 表示文字列 (b:review_winbar 経由 / ui/chrome 参照)。件数は単複を分ける。
local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

local function set_winbar(buf, session, file)
  local refs = ('%s..%s'):format(session.base or '', session.head or '')
  local text
  if file.path == M.NO_DIFF_PATH then
    text = refs .. ' · 変更なし'
  else
    local n = 0
    for _, c in ipairs(session.comments or {}) do
      if c.file == file.path then
        n = n + 1
      end
    end
    text = ('%s · %s · +%d -%d · %s'):format(
      refs,
      file.path,
      file.added or 0,
      file.deleted or 0,
      plural(n, 'comment')
    )
  end
  chrome.bar(buf, text)
end

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
  map('n', k.yank_prompt, "require('review.handlers.comments').yank_current()")
  map('n', k.open_file, "require('review.handlers.session').open_file_current()")
  map('n', k.close, "require('review.handlers.session').close_by_key()")
  map('n', k.help, "require('review.ui.help').open()")
  map('n', k.next_file, "require('review.handlers.session').next_file()")
  map('n', k.prev_file, "require('review.handlers.session').prev_file()")
  map('n', k.focus_sidebar, "require('review.handlers.session').focus_sidebar()")
  map('n', k.view_comments, "require('review.handlers.comments').view_current()")
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

  -- 行下スレッド表示 (GitHub Files changed 風)。eol には件数だけ置き、本文は
  -- virt_lines でコメント範囲末尾行の下に出す。virt_lines は buffer 行を占有
  -- しないので new 側行番号写像 (c/e/d/o の位置契約) は不変、fold 時は自動で
  -- 非表示になり wrap と干渉しない (既知の制約は wrap=off 強制で解消済み)。
  -- 長文は MAX_THREAD_LINES で打ち切り、全文は `i` 窓 (read-only) が正しい経路。
  local MAX_THREAD_LINES = 10
  local function thread_lines(c)
    local out = {}
    local prefix = c.state == 'outdated' and ('⚠ [%s] '):format(c.id) or ('  [%s] '):format(c.id)
    local pad = string.rep(' ', vim.fn.strchars(prefix))
    local hl = c.state == 'outdated' and 'ReviewCommentOutdated' or 'ReviewCommentBody'
    local blines = vim.split(c.body, '\n', { plain = true })
    for i, bl in ipairs(blines) do
      if i > MAX_THREAD_LINES then
        out[#out + 1] = { { pad .. '… (i で全文)', hl } }
        break
      end
      out[#out + 1] = { { (i == 1 and prefix or pad) .. bl, hl } }
    end
    return out
  end

  local function group_thread(comments)
    local acc = {}
    for _, c in ipairs(comments) do
      local t = thread_lines(c)
      for i = 1, #t do
        if i == 1 and #acc > 0 then
          acc[#acc + 1] = { { ' ', 'ReviewCommentBody' } }
        end
        acc[#acc + 1] = t[i]
      end
    end
    return acc
  end

  local outdated_hidden = {}
  local group_by_row = {}
  local outdated_by_row = {}
  local groups = {}
  local group_order = {}
  for _, c in ipairs(session.comments) do
    if c.file == file.path then
      local start_row = st.new_to_row[c.line]
      if start_row ~= nil then
        local g = groups[start_row]
        if g == nil then
          g = { comments = {}, end_row = nil }
          groups[start_row] = g
          group_order[#group_order + 1] = start_row
        end
        g.comments[#g.comments + 1] = c
        group_by_row[start_row] = (group_by_row[start_row] or 0) + 1
        if c.state == 'outdated' then
          outdated_by_row[start_row] = (outdated_by_row[start_row] or 0) + 1
        end
        local er = st.new_to_row[c.end_line] or start_row
        if er < start_row then
          er = start_row
        end
        if g.end_row == nil or er > g.end_row then
          g.end_row = er
        end
      elseif c.state == 'outdated' then
        -- new 側の行番号が解決できない (差分が消えた) outdated。行位置が無いので
        -- ファイルヘッダ行に集約する (本文は thread、プロンプトから除外中)。
        outdated_hidden[#outdated_hidden + 1] = c
      end
    end
  end

  local seen_head = {}
  for _, sr in ipairs(group_order) do
    local g = groups[sr]
    -- thread は group の見出し extmark (start 行) に併合する (同一位置に
    -- マークを二つ作ると取得順序が不定で spec/契約が保てない)。
    local thr = group_thread(g.comments)
    for _, c in ipairs(g.comments) do
      local v_start = st.new_to_row[c.line]
      local end_row = st.new_to_row[c.end_line] or v_start
      if end_row < v_start then
        end_row = v_start
      end
      local annotation
      if not seen_head[v_start] then
        seen_head[v_start] = true
        local n_out = outdated_by_row[v_start] or 0
        annotation = ' 💬 '
          .. group_by_row[v_start]
          .. (n_out > 0 and (' (⚠' .. n_out .. ')') or '')
      end
      vim.api.nvim_buf_set_extmark(buf, comment_ns, v_start - 1, 0, {
        end_row = end_row - 1,
        end_col = #lines[end_row],
        hl_group = 'ReviewCommentLine',
        virt_text = annotation and { { annotation, 'Comment' } } or nil,
        virt_text_pos = annotation and 'eol' or nil,
        virt_lines = (annotation and #thr > 0 and thr) or nil,
      })
    end
  end

  if #outdated_hidden > 0 then
    vim.api.nvim_buf_set_extmark(buf, comment_ns, 0, 0, {
      virt_text = {
        {
          (' ⚠ %d outdated (prompt 除外中)'):format(#outdated_hidden),
          'Comment',
        },
      },
      virt_text_pos = 'eol',
      virt_lines = group_thread(outdated_hidden),
    })
  end

  if opts.winid ~= nil and vim.api.nvim_win_is_valid(opts.winid) then
    vim.wo[opts.winid].wrap = false -- extmark virt text と wrap の干渉 (既知の制約)
    vim.wo[opts.winid].foldmethod = 'expr'
    vim.wo[opts.winid].foldexpr = 'v:lua.require("review.ui.diffbuffer").foldexpr(v:lnum)'
    chrome.window(opts.winid)
  end

  apply_keymaps(buf)
  set_winbar(buf, session, file)
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
  set_winbar(buf, session, { path = M.NO_DIFF_PATH })
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
