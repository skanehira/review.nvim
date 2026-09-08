-- sidebar (変更ファイル一覧) と :Review list (セッション一覧) の描画。
-- 両者は filetype `review-list` を共有する (DESIGN.md「横断規約」UI)。挙動の分岐は
-- buffer に付けた review_meta で行う (FileType autocmd 分岐は使わない)。
-- 行 -> データの引き渡しは行番号写像 (render ごとに再構築、バッファ側に値を持たない)。
local config = require 'review.config'

local M = {}

local grey_ns = vim.api.nvim_create_namespace 'review_list_grey'

-- bufnr -> { rows = { [row] = payload } }
local rendered = {}

vim.api.nvim_create_autocmd('BufUnload', {
  callback = function(ev)
    rendered[ev.buf] = nil
  end,
})

local function buffer(name)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

local function paint(buf, lines, meta, rows, keymap)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'review-list'
  vim.b[buf].review_meta = meta
  for _, k in ipairs(keymap) do
    vim.api.nvim_buf_set_keymap(buf, 'n', k[1], (':lua %s<CR>'):format(k[2]), {
      noremap = true,
      silent = true,
      nowait = true,
    })
  end
  rendered[buf] = { rows = rows }
  return buf
end

--- session と parse 済み File 一覧を sidebar に描画する。
--- 1 行 `<status> <path> +<a> -<d>`、パス昇順、viewed は行頭に `[✓]`。
function M.render_sidebar(session, files)
  local sorted = {}
  for _, file in ipairs(files) do
    sorted[#sorted + 1] = file
  end
  table.sort(sorted, function(a, b)
    return a.path < b.path
  end)

  local buf = buffer(('review://sidebar/%s'):format(session.id))
  local lines, rows = {}, {}
  for _, file in ipairs(sorted) do
    local viewed = session.files[file.path] ~= nil and session.files[file.path].viewed
    lines[#lines + 1] = ('%s%s %s +%d -%d'):format(
      viewed and '[✓] ' or '',
      file.status,
      file.path,
      file.added,
      file.deleted
    )
    rows[#lines] = file.path
  end
  local k = config.get().keymaps.sidebar
  return paint(buf, lines, { kind = 'sidebar', session_id = session.id }, rows, {
    { k.open_diff, "require('review.handlers.session').open_selected_file()" },
    -- diff の `o` と同じ入口 (handlers.session が sidebar meta 分岐で開く)。
    -- fileview直呼びではなく handlers 経由に統一し、削除ファイル不可通知を共有する。
    { k.open_file, "require('review.handlers.session').open_file_current()" },
    { k.toggle_viewed, "require('review.handlers.session').toggle_viewed_current()" },
    { k.close, "require('review.handlers.session').close_by_key()" },
  })
end

--- sidebar の行 -> ファイルパス (範囲外は nil)。
function M.row_file(bufnr, row)
  local st = rendered[bufnr]
  if st == nil then
    return nil
  end
  return st.rows[row]
end

--- 保存済みセッション一覧を描画する。opts = { is_grey(sess)->bool? }。
--- 1 行 `<slug>  <status>  <mode>  <base>..<head>  <N> comments  <UTC 更新時刻>`、
--- slug 昇順。grey 行 (repo 消失) は row_session が nil = <Enter> 不可。
function M.render_sessionlist(sessions, opts)
  opts = opts or {}
  local sorted = {}
  for _, s in ipairs(sessions) do
    sorted[#sorted + 1] = s
  end
  table.sort(sorted, function(a, b)
    return a.id < b.id
  end)

  local buf = buffer 'review://sessions'
  local lines, rows = {}, {}
  for _, s in ipairs(sorted) do
    local comment_count = #(s.comments or {})
    lines[#lines + 1] = ('%s  %s  %s  %s..%s  %d comments  %s'):format(
      s.id,
      s.status,
      s.mode,
      s.base,
      s.head,
      comment_count,
      os.date('!%Y-%m-%d %H:%M', s.updated_at)
    )
    local grey = opts.is_grey ~= nil and opts.is_grey(s)
    if not grey then
      rows[#lines] = s
    end
  end
  local k = config.get().keymaps.sessionlist
  local drawn = paint(buf, lines, { kind = 'sessionlist' }, rows, {
    { k.open, "require('review.handlers.sessions_list').open_current()" },
    { k.close, "require('review.ui.list').close_current()" },
  })
  -- grey (repo path 消失) 行は hl を被せて <Enter> 不可を示す (行データ自体は rows から除外済み)
  vim.api.nvim_buf_clear_namespace(buf, grey_ns, 0, -1)
  for i, sess in ipairs(sorted) do
    if opts.is_grey ~= nil and opts.is_grey(sess) then
      vim.api.nvim_buf_set_extmark(drawn, grey_ns, i - 1, 0, {
        end_row = i - 1,
        end_col = #lines[i],
        hl_group = 'ReviewSidebarStatus',
      })
    end
  end
  return drawn
end

--- セッション一覧の行 -> session (grey 行・範囲外は nil)。
function M.row_session(bufnr, row)
  local st = rendered[bufnr]
  if st == nil then
    return nil
  end
  return st.rows[row]
end

--- 一覧バッファの q: バッファを閉じるだけ (セッション状態は変えない)。
function M.close_current()
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].review_meta or {}
  if meta.kind == 'sessionlist' then
    vim.cmd 'close'
  end
end

return M
