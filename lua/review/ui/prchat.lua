-- ui/prchat: PR 一般コメント (conversation) の描画 (pr-comments「一般コメント」)。
-- 行に紐づかない PR 全体のコメントを `review://pr-chat/<session-id>` バッファ
-- (filetype review-list、review_meta = { kind='prchat', session_id }) に時系列で
-- 表示する。コメント一覧と同じくレビュー tab の最下部に全幅で開き、render は
-- バッファを全面置換して buffer 側に写像を持たない (commentlist と同じ契約)。
-- 行は「[<作者>] <本文 1 行目>」+ 続き行 (indent)。操作は r (返信) / s (submit) /
-- q (閉じる)。返信は local pending の一般コメントとして session.general に追加され、
-- submit で issues/{n}/comments へ投稿される。
local chrome = require 'review.ui.chrome'
local config = require 'review.config'

local M = {}

local hl_ns = vim.api.nvim_create_namespace 'review_prchat_hl'

-- bufnr -> { rows = { [row] = comment } }
local rendered = {}

vim.api.nvim_create_autocmd('BufUnload', {
  callback = function(ev)
    rendered[ev.buf] = nil
    local meta = vim.b[ev.buf].review_meta or {}
    if meta.kind == 'prchat' then
      chrome.restore_global_if_unused()
      chrome.sync_tab()
    end
  end,
})

vim.api.nvim_create_autocmd('BufWinLeave', {
  callback = function(ev)
    local meta = vim.b[ev.buf].review_meta or {}
    if meta.kind ~= 'prchat' then
      return
    end
    for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
      if vim.api.nvim_win_is_valid(win) then
        vim.w[win].review_winbar = nil
      end
    end
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

-- render から呼ばれる buffer-local キー張込 (後方で代入)。
local paint_keymaps

-- 一般コメントの作者ラベル: gh は login、local pending は you ⚠ / pushed は自身。
local function author_label(g)
  if g.origin == 'gh' then
    return g.gh_user or 'gh'
  end
  if g.gh_id ~= nil then
    return g.gh_user or 'you'
  end
  return 'you \u{26A0}'
end

-- 1 コメントの表示行群 (1 行目 = [<author>] 本文 1 行目、以降 = 続き行 indent)。
local function comment_rows(g)
  local head = ('[%s] '):format(author_label(g))
  local pad = string.rep(' ', vim.fn.strchars(head))
  local out = {}
  local blines = vim.split(g.body or '', '\n', { plain = true })
  for i, bl in ipairs(blines) do
    if i == 1 then
      out[#out + 1] = head .. bl
    else
      out[#out + 1] = pad .. bl
    end
  end
  return out
end

--- 一覧バッファを描画する。返り値 bufnr。
function M.render(session)
  local buf = buffer(('review://pr-chat/%s'):format(session.id))
  local general = session.general or {}

  local lines, rows = {}, {}
  if #general == 0 then
    lines[1] = 'No PR comments'
  end
  for i, g in ipairs(general) do
    local grows = comment_rows(g)
    for _, r in ipairs(grows) do
      lines[#lines + 1] = r
    end
    rows[i] = g
  end

  local win = list_win(buf)
  local prev_row
  if win ~= nil then
    prev_row = vim.api.nvim_win_get_cursor(win)[1]
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'review-list'
  vim.b[buf].review_meta = { kind = 'prchat', session_id = session.id }

  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  rendered[buf] = { rows = rows }
  paint_keymaps(buf)

  if win ~= nil and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_cursor(win, {
      math.max(1, math.min(prev_row or 1, math.max(#lines, 1))),
      0,
    })
  end
  return buf
end

paint_keymaps = function(buf)
  local k = config.get().keymaps.prchat
  for _, kmap in ipairs {
    { k.reply, "require('review.handlers.pr_chat').reply_current()" },
    { k.submit, "require('review.handlers.submit').submit_review()" },
    { k.close, "require('review.handlers.pr_chat').close_current()" },
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

--- 行 -> 一般コメント (「No PR comments」行・範囲外は nil)。
function M.row_comment(bufnr, row)
  local st = rendered[bufnr]
  if st == nil then
    return nil
  end
  return st.rows[row]
end

--- pr-chat winbar: `PR #<n> · <M> comments`。
function M.winbar(session, general)
  local n = #(general or {})
  return ('PR #%s · %d %s'):format(
    tostring((session.pr or {}).number),
    n,
    n == 1 and 'comment' or 'comments'
  )
end

--- session_id の pr-chat 窓を返す (役割は内容 = review_meta から導く。無ければ nil)。
function M.find_window(session_id)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local meta = vim.b[vim.api.nvim_win_get_buf(win)].review_meta or {}
    if meta.kind == 'prchat' and meta.session_id == session_id then
      return win
    end
  end
  return nil
end

--- close / 切替経路: 表示中の pr-chat 窓を閉じる (bufhidden=wipe でバッファも消える)。
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
