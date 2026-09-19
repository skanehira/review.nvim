-- ui/commentlist: コメント一覧 (横断) の描画 (docs/design/features/comment-list.md
-- 「表示」/ docs/design/DESIGN.md 決定表「コメント一覧 (横断)」)。
-- 1 行 = 1 コメントの一覧バッファ (`review://comments/<session-id>`、filetype
-- review-list、review_meta = { kind='commentlist', session_id }) の組み立てを担う。
-- 表示 file 集合と並びの起点 (order) は handlers/session の visible_order が
-- 解決し、ここは order に対する並び (line 昇順・作成順)・行整形・span・winbar・
-- カーソル追従・buffer-local キーだけを持つ。折畳・絞り込みの適用は order を
-- 作る側の責務 (呼び出し側が { collapsed = {}, mode = 'tree' } を明示する)。
-- 真実は常に session.comments: render はバッファを全面置換し、buffer 側に写像を
-- 持たない (filepanel と同じ契約)。
local chrome = require 'review.ui.chrome'
local config = require 'review.config'

local M = {}

local hl_ns = vim.api.nvim_create_namespace 'review_commentlist_hl'

-- bufnr -> { rows = { [row] = comment }, shown = comment[] }
local rendered = {}

vim.api.nvim_create_autocmd('BufUnload', {
  callback = function(ev)
    rendered[ev.buf] = nil
  end,
})

-- 一覧 buffer が窓から外れる (:buffer 差し替え) とき、その窓の表示文字列を残さない。
-- 残すと review セッション開中に stale バーがそのまま見える。
vim.api.nvim_create_autocmd('BufWinLeave', {
  callback = function(ev)
    local meta = vim.b[ev.buf].review_meta or {}
    if meta.kind ~= 'commentlist' then
      return
    end
    for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
      if vim.api.nvim_win_is_valid(win) then
        vim.w[win].review_winbar = nil
      end
    end
    -- 表示文字列を消した窓が現在 tab の最後のバーだったなら式も戻す
    chrome.sync_tab()
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

local function list_win(buf)
  return vim.fn.win_findbuf(buf)[1]
end

-- body の 1 行目のみ。60 文字を超えるときだけ 60 文字 + … (UTF-8 を分断しない)。
local BODY_MAX = 60

local function body_head(body)
  local first = vim.split(body or '', '\n', { plain = true })[1] or ''
  if vim.fn.strchars(first) > BODY_MAX then
    return vim.fn.strcharpart(first, 0, BODY_MAX) .. '…'
  end
  return first
end

local function loc_text(c)
  local line = c.line or 0
  local end_line = c.end_line or line
  if end_line > line then
    return ('%s:%d-%d'):format(c.file, line, end_line)
  end
  return ('%s:%d'):format(c.file, line)
end

-- 行フォーマット: `<path>:<line>[-<end>]  [<id>]  <body 1 行目>[ ⚠ outdated]`。
local function line_for(c)
  local text = ('%s  [%s]  %s'):format(loc_text(c), c.id, body_head(c.body))
  if c.state == 'outdated' then
    text = text .. ' ⚠ outdated'
  end
  return text
end

--- 一覧の行となるコメントの並び (純ロジック)。
--- session.comments と order / session.files (直近 parse の files map) から解決する。
--- order = file panel と同一 tree 表示順の file path 配列 (絞り込み適用済み)。
--- 対象: order の file + 直近 parse の files map に無い (= 差分から消えた) file。
---   絞り込み外 (order に無く files にある) file は末尾にも出さない。
--- 並び: order の file 順 -> 同一 file 内 line 昇順 -> 同一 line はセッション配列順。
---   順序リスト外は末尾へ path 昇順 (以降の規則は同じ)。
function M.visible_comments(session, order)
  local rank = {}
  for i, path in ipairs(order or {}) do
    rank[path] = i
  end
  local files = session.files or {}
  local scoped = {}
  for seq, c in ipairs(session.comments or {}) do
    local r = rank[c.file]
    if r ~= nil then
      scoped[#scoped + 1] = { rank = r, seq = seq, c = c }
    elseif files[c.file] == nil then
      scoped[#scoped + 1] = { rank = nil, seq = seq, c = c }
    end
  end
  table.sort(scoped, function(a, b)
    if a.rank ~= nil and b.rank ~= nil then
      if a.rank ~= b.rank then
        return a.rank < b.rank
      end
    elseif a.rank ~= nil then
      return true
    elseif b.rank ~= nil then
      return false
    elseif a.c.file ~= b.c.file then
      return a.c.file < b.c.file
    end
    if a.c.line ~= b.c.line then
      return a.c.line < b.c.line
    end
    return a.seq < b.seq
  end)
  local out = {}
  for i, s in ipairs(scoped) do
    out[i] = s.c
  end
  return out
end

local function paint_keymaps(buf)
  local k = config.get().keymaps.commentlist
  -- 押下時点の窓 gate は不要 (一覧 buffer を表示し得る窓はこの一覧だけ)。rhs は
  -- 発火時に解決する (ui -> handlers の module-load 循環回避)。
  for _, kmap in ipairs {
    { k.jump, "require('review.handlers.comments_list').jump_current()" },
    { k.delete, "require('review.handlers.comments_list').delete_current()" },
    { k.edit, "require('review.handlers.comments_list').edit_current()" },
    { k.yank, "require('review.handlers.comments_list').yank_current()" },
    { k.close, "require('review.handlers.comments_list').close_current()" },
  } do
    if kmap[1] ~= nil then
      vim.api.nvim_buf_set_keymap(buf, 'n', kmap[1], (':lua %s<CR>'):format(kmap[2]), {
        noremap = true,
        silent = true,
        nowait = true,
      })
    end
  end
end

--- 一覧バッファを描画する (同名 buffer を再構成し、内容は常に最新)。
--- opts = { order = {path,...}, head_display = string }。
--- 表示中の窓があればカーソルを comment id で追従し、選択行が消えた場合は同じ行
--- 位置 (末尾なら最終行 / 0 件は 1 行目) へ寄せる。
--- 返り値 bufnr。
function M.render(session, opts)
  opts = opts or {}
  local buf = buffer(('review://comments/%s'):format(session.id))
  local shown = M.visible_comments(session, opts.order or {})

  local lines, rows, spans = {}, {}, {}
  if #shown == 0 then
    lines[1] = 'コメントはありません'
  end
  for i, c in ipairs(shown) do
    local text = line_for(c)
    lines[#lines + 1] = text
    rows[i] = c
    spans[#spans + 1] = { row = i - 1, from = 0, to = #c.file, group = 'ReviewPanelFile' }
    if c.state == 'outdated' then
      spans[#spans + 1] = {
        row = i - 1,
        from = #text - #'⚠ outdated',
        to = #text,
        group = 'ReviewCommentOutdated',
      }
    end
  end

  local win = list_win(buf)
  local prev_row, prev_id
  if win ~= nil and rendered[buf] ~= nil then
    prev_row = vim.api.nvim_win_get_cursor(win)[1]
    local prev = rendered[buf].rows[prev_row]
    prev_id = prev ~= nil and prev.id or nil
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'review-list'
  vim.b[buf].review_meta = { kind = 'commentlist', session_id = session.id }

  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for _, s in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, hl_ns, s.row, s.from, {
      end_col = s.to,
      hl_group = s.group,
    })
  end
  rendered[buf] = { rows = rows, shown = shown }
  paint_keymaps(buf)

  if win ~= nil and vim.api.nvim_win_is_valid(win) then
    local target
    if prev_id ~= nil then
      for i, c in ipairs(shown) do
        if c.id == prev_id then
          target = i
          break
        end
      end
    end
    if target == nil then
      target = math.max(1, math.min(prev_row or 1, math.max(#lines, 1)))
    end
    vim.api.nvim_win_set_cursor(win, { target, 0 })
  end
  return buf
end

--- 行 -> comment («コメントはありません» 行・範囲外は nil)。
function M.row_comment(bufnr, row)
  local st = rendered[bufnr]
  if st == nil then
    return nil
  end
  return st.rows[row]
end

--- 直近 render の表示コメント一覧 (winbar の N / ⚠M の源)。
function M.shown(bufnr)
  local st = rendered[bufnr]
  return st ~= nil and st.shown or {}
end

--- 張られた span extmark を { row(0-based), from, to, group } で返す。
function M.hl_spans(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, hl_ns, 0, -1, { details = true })) do
    out[#out + 1] = {
      row = m[2],
      from = m[3],
      to = (m[4].end_col or m[3]),
      group = m[4].hl_group,
    }
  end
  return out
end

--- 一覧 winbar 文字列: `<base>..<head 表示名> · <N> comments[ · ⚠M]`。
--- N = 表示行数 (絞り込み適用後のコメント件数)、M = 表示中の outdated 総数
--- (0 件なら ⚠ は出さない)。panel winbar の ⚠N (集約先の無い outdated) とは別の数。
--- opts = { head_display = string }。
function M.winbar(session, shown, opts)
  opts = opts or {}
  local n = #(shown or {})
  local outdated = 0
  for _, c in ipairs(shown or {}) do
    if c.state == 'outdated' then
      outdated = outdated + 1
    end
  end
  local bar = ('%s..%s · %d %s'):format(
    session.base or '',
    opts.head_display or session.head or '',
    n,
    n == 1 and 'comment' or 'comments'
  )
  if outdated > 0 then
    bar = bar .. (' · ⚠%d'):format(outdated)
  end
  return bar
end

--- session_id の一覧窓を返す (役割は内容 = review_meta から導く。無ければ nil)。
--- ユーザーが :edit 等で中身を差し替えた窓は meta が一致しないので触らない
--- (その場合 buffer は bufhidden=wipe で消えており、次回は新規 vsplit になる)。
function M.find_window(session_id)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local meta = vim.b[vim.api.nvim_win_get_buf(win)].review_meta or {}
    if meta.kind == 'commentlist' and meta.session_id == session_id then
      return win
    end
  end
  return nil
end

--- close / 切替経路: 表示中の一覧窓を閉じる (bufhidden=wipe でバッファも消え、
--- BufUnload が state を掃除する — 残骸の窓・バッファを残さない)。
function M.close_all()
  for buf in pairs(rendered) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
end

return M
