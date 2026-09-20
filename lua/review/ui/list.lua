-- :Review list (セッション一覧) の描画 (file panel は issue-17 で ui/filepanel へ
-- 移動済み。ここは sessionlist のみ)。filetype は file panel と共通の
-- `review-list` を使う (DESIGN.md「横断規約」UI)。挙動の分岐は buffer に付けた
-- review_meta で行う (FileType autocmd 分岐は使わない)。
-- 行 -> データの引き渡しは行番号写像 (render ごとに再構築、バッファ側に値を持たない)。
local chrome = require 'review.ui.chrome'
local config = require 'review.config'

local M = {}

local grey_ns = vim.api.nvim_create_namespace 'review_list_grey'

-- bufnr -> { rows = { [row] = payload } }
local rendered = {}

-- `:Review list` は review tab 外 (current tab の vsplit) に開くため、一覧窓の閉鎖は
-- tab 消滅経路 (windows.close / TabClosed) に乗らない。バッファが閉じた時点で
-- review セッションが無ければ chrome の global winbar 式と窓変数を戻す
-- (diff-review「窓装飾 (chrome)」)。
vim.api.nvim_create_autocmd('BufUnload', {
  callback = function(ev)
    rendered[ev.buf] = nil
    local meta = vim.b[ev.buf].review_meta or {}
    if meta.kind == 'sessionlist' then
      chrome.restore_global_if_unused()
      -- セッション開中でも、現在 tab にバーの窓が無くなれば式を戻す (式が非空だと
      -- 空評価でも 1 行確保される。review tab へ戻れば TabEnter が再適用する)。
      chrome.sync_tab()
    end
  end,
})

-- 一覧 buffer が窓から外れる (:buffer 差し替え) とき、その窓の表示文字列を残さない。
-- 残すと review セッション開中に stale バーがそのまま見え、閉じた後に別セッションを
-- 開くと stale バーが再表示される。
vim.api.nvim_create_autocmd('BufWinLeave', {
  callback = function(ev)
    local meta = vim.b[ev.buf].review_meta or {}
    if meta.kind ~= 'sessionlist' then
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

--- セッション一覧の winbar 文字列 (handlers が窓に chrome.winbar で当てる)。
function M.sessionlist_winbar(sessions)
  local n = #(sessions or {})
  return ('review.nvim · %d %s'):format(n, n == 1 and 'session' or 'sessions')
end

--- 保存済みセッション一覧を描画する。opts = {} | { is_grey(sess)->bool? }。
--- 1 行 `<slug>  <status>  <mode>  <base>..<head>  <N> comments  <ローカル時刻 + %Z tz>`、
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

  local function timestamp(updated_at)
    -- ローカル時刻 + tz 短縮表記 (UX review F17: UTC 固定だと JST ユーザーが
    -- 9 時間誤読した)。%Z 非対応プラットフォームでは時刻だけで耐える。
    local tz = os.date('%Z', updated_at)
    if tz == nil or tz:find('%', 1, true) then
      -- strftime が %Z を解釈できないプラットフォーム (リテラル "%Z" が返る) 対策
      tz = ''
    else
      tz = ' ' .. tz
    end
    return os.date('%Y-%m-%d %H:%M', updated_at) .. tz
  end

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
      timestamp(s.updated_at)
    )
    local grey = opts.is_grey ~= nil and opts.is_grey(s)
    if not grey then
      rows[#lines] = s
    end
  end
  local k = config.get().keymaps.sessionlist
  -- meta.repo は追随 (sessions_list.refresh) が「開いたときの repo の一覧か」を
  -- 判定するために使う (別 repo の一覧を開いたまま状態変化しても壊さない)。
  local drawn = paint(buf, lines, { kind = 'sessionlist', repo = opts.repo }, rows, {
    { k.open, "require('review.handlers.sessions_list').open_current()" },
    { k.close, "require('review.ui.list').close_current()" },
    { k.delete, "require('review.handlers.sessions_list').delete_current()" },
  })
  -- grey (repo path 消失) 行は hl を被せて <Enter> 不可を示す (行データ自体は rows から除外済み)
  vim.api.nvim_buf_clear_namespace(buf, grey_ns, 0, -1)
  for i, sess in ipairs(sorted) do
    if opts.is_grey ~= nil and opts.is_grey(sess) then
      vim.api.nvim_buf_set_extmark(drawn, grey_ns, i - 1, 0, {
        end_row = i - 1,
        end_col = #lines[i],
        hl_group = 'ReviewPanelMeta',
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
