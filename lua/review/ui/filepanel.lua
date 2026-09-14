-- ui/filepanel: file panel (review://sidebar/<session>、filetype review-list) の
-- バッファ描画・行写像・カーソル追従 (docs/design/features/diff-review.md
-- 「file panel」/ DESIGN.md「file panel 表示」「UI」)。
-- 行の組み立て (ツリー連結・集約・fold 集合・list 形式) は ui/treelist の純ロジック。
-- ここは «同一 buffer への再構成・span extmark・選択行 hl・panel 窓のカーソル・
-- buffer-local キー» だけを持つ。挙動分岐は buffer の review_meta (FileType
-- autocmd 分岐は使わない — DESIGN「UI」)。winbar 文字列もここ (b: 変数は実ファイル
-- 窓経由でユーザー窓へ漏れるため w: 側 only — chrome 決定)。
local config = require 'review.config'
local treelist = require 'review.ui.treelist'

local M = {}

local hl_ns = vim.api.nvim_create_namespace 'review_panel_hl'
local sel_ns = vim.api.nvim_create_namespace 'review_panel_sel'

-- bufnr -> { rows = { [row] = {kind, path} | nil (header) } }
local rendered = {}
-- bufnr -> 選択行 extmark id (line hl、カーソル移動で張り替え)
local sel_mark = {}

vim.api.nvim_create_autocmd('BufUnload', {
  callback = function(ev)
    rendered[ev.buf] = nil
    sel_mark[ev.buf] = nil
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

-- devicons は任意検出のみ (runtime 依存ゼロを割らない — DESIGN「既知の制約」)。
-- テスト/stub 用の注入点 (git/cli._set_system と同型の DI)。
local icon_resolver_override = nil

local function devicons_resolver(path)
  local ok, devicons = pcall(require, 'nvim-web-devicons')
  if not ok or devicons == nil or devicons.get_icon == nil then
    return nil
  end
  local name = vim.fn.fnamemodify(path, ':t')
  local ext = vim.fn.fnamemodify(name, ':e')
  -- default=true を使わない: 未知拡張に汎用アイコンを積むと noise になる
  local icon, hl = devicons.get_icon(name, ext)
  return icon, hl
end

function M._set_icon_resolver(fn)
  icon_resolver_override = fn
end

local function panel_win(buf)
  local wins = vim.fn.win_findbuf(buf)
  return wins[1]
end

local function set_selection(buf, row)
  if sel_mark[buf] ~= nil then
    pcall(vim.api.nvim_buf_del_extmark, buf, sel_ns, sel_mark[buf])
    sel_mark[buf] = nil
  end
  if rendered[buf] == nil or row == nil then
    return
  end
  sel_mark[buf] = vim.api.nvim_buf_set_extmark(buf, sel_ns, row - 1, 0, {
    line_hl_group = 'ReviewPanelFile',
  })
end

-- 相互ハイライト (panel 側): キャレットが panel の行に来たら選択行 hl を追いかける。
-- 窓 role gate は buffer 内容 (review_meta.kind) で代用する (DESIGN「UI」: 決定を
-- 決めつけず内容から導く)。expr gate ではないので built-in 副作用は無い。
vim.api.nvim_create_autocmd('CursorMoved', {
  callback = function(ev)
    local buf = ev.buf
    local st = rendered[buf]
    if st == nil then
      return
    end
    local meta = vim.b[buf].review_meta or {}
    if meta.kind ~= 'sidebar' then
      return
    end
    local win = panel_win(buf)
    if win == nil then
      return
    end
    set_selection(buf, vim.api.nvim_win_get_cursor(win)[1])
  end,
})

local function paint_keymaps(buf)
  local k = config.get().keymaps.sidebar
  -- 押下時点の窓 gate は不要 (sidebar バッファを表示し得る窓は panel のみ)。
  -- rhs は発火時に解決 (ui -> handlers の module-load 循環回避)。keygate は
  -- ユーザー既存と扱って上書きスキップするため、panel の `i` はここが勝つ
  -- (head 窓の view_comments `i` は panel では発火しない)。
  -- <CR> / o / l は同一 «entry を開く» (DESIGN キー表 «file panel 上の o = 開く。
  -- diff 窓の o とは意味が違う»)。移動系と R はレビュー窓と同じ handlers。
  for _, kmap in ipairs {
    { k.open_diff, "require('review.handlers.session').open_selected_file()" },
    { k.open_file, "require('review.handlers.session').open_selected_file()" },
    { k.open_entry, "require('review.handlers.session').open_selected_file()" },
    { k.next_file, "require('review.handlers.session').next_file()" },
    { k.prev_file, "require('review.handlers.session').prev_file()" },
    { k.first_file, "require('review.handlers.session').first_file()" },
    { k.last_file, "require('review.handlers.session').last_file()" },
    { k.refresh, "require('review.handlers.session').refresh()" },
    { k.toggle_viewed, "require('review.handlers.session').toggle_viewed_current()" },
    { k.filter, "require('review.handlers.session').filter_sidebar()" },
    { k.toggle_style, "require('review.handlers.session').toggle_listing_style()" },
    { k.close, "require('review.handlers.session').close_by_key()" },
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

--- panel を再描画する (同一 buffer を再構成)。
--- session: viewed 解決と winbar 用の id/base があるセッションテーブル。
--- files: 可視 File 一覧 (filter 済み・呼び出し側の責任 — 進行順と同じ集合を向く)。
--- opts = { mode?, collapsed?, base?, head_display?, cursor? = {kind,path} }。
---   cursor = head 窓で開いたファイルへの panel カーソル逆追従 (diff-review「選択追従」)。
---   cursor 省略時は前回選択 entry を同じ行番号で维持し、隠れていれば clamp する
---     (view state の再構成で行単位で状態を持たない契約)。
function M.render(session, files, opts)
  opts = opts or {}
  local buf = buffer(('review://sidebar/%s'):format(session.id))

  -- 再構成の前に現在表示中の entry を記憶 (行番号でなく entry で追踪する)
  local win = panel_win(buf)
  local prev_cursor_row
  local prev_entry
  if win ~= nil and rendered[buf] ~= nil then
    prev_cursor_row = vim.api.nvim_win_get_cursor(win)[1]
    prev_entry = rendered[buf].rows[prev_cursor_row]
  end

  local entries = {}
  for _, file in ipairs(files) do
    local state = session.files[file.path]
    entries[#entries + 1] = {
      path = file.path,
      status = file.status,
      added = file.added,
      deleted = file.deleted,
      viewed = state ~= nil and state.viewed == true,
    }
  end

  local rows = treelist.build(entries, {
    mode = opts.mode,
    collapsed = opts.collapsed or {},
    icon = icon_resolver_override or devicons_resolver,
    base = opts.base or session.base,
    head_display = opts.head_display,
  })

  local texts = {}
  local row_map = {}
  for i, row in ipairs(rows) do
    texts[i] = row.text
    if row.kind ~= 'header' then
      row_map[i] = { kind = row.kind, path = row.path }
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'review-list'
  vim.b[buf].review_meta = { kind = 'sidebar', session_id = session.id }

  -- span hl: 常に捨てて再構成 (バッファ側に真実を置かない現行契約)
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for i, row in ipairs(rows) do
    for _, s in ipairs(row.spans) do
      vim.api.nvim_buf_set_extmark(buf, hl_ns, i - 1, s.from, {
        end_col = s.to,
        hl_group = s.group,
      })
    end
  end

  rendered[buf] = { rows = row_map }
  paint_keymaps(buf)

  if win ~= nil and vim.api.nvim_win_is_valid(win) then
    local target
    local want = opts.cursor or prev_entry
    if want ~= nil then
      for i, entry in pairs(row_map) do
        if entry.kind == want.kind and entry.path == want.path then
          target = i
          break
        end
      end
    end
    if target == nil then
      -- entry が見つからない (folded / 差分から消滅) = 見ていた行番号を clamp
      target = math.max(1, math.min(prev_cursor_row or 1, math.max(#texts, 1)))
    end
    vim.api.nvim_win_set_cursor(win, { target, 0 })
    vim.wo[win].cursorline = true
    set_selection(buf, target)
  end
  return buf
end

--- 行 -> entry ({kind='file'|'dir', path}。header・範囲外は nil)。
--- dir の path は連結表示後の deepest dir (canonical、スラッシュ無し)。
function M.row_entry(bufnr, row)
  local st = rendered[bufnr]
  if st == nil then
    return nil
  end
  return st.rows[row]
end

--- 絞り込みの可視集合 (render 側と ]d/[d の進行順が同じ集合を向くための単一源)。
function M.visible(files, needle)
  return treelist.visible(files, needle)
end

--- panel の winbar 文字列。handlers が窓に chrome.winbar で当てる (b: に持たない)。
--- `base..head · N files · M comments [· filter=…] [· ⚠N]` — `⚠N` は
--- opts.hidden_outdated (集約先 head 窓の無い outdated 件数。告知窓ファイルと
--- 差分消失ファイルの分で、呼び出し側 handlers が算出)。0 / 省略なら非表示
--- (diff-review「窓装飾」)。
function M.winbar(session, files, opts)
  opts = opts or {}
  local bar = ('%s..%s · %d %s · %d %s'):format(
    session.base or '',
    session.head or '',
    #files,
    #files == 1 and 'file' or 'files',
    #(session.comments or {}),
    #(session.comments or {}) == 1 and 'comment' or 'comments'
  )
  if opts.filter ~= nil and opts.filter ~= '' then
    -- 一致 0 なら「閉じた?」と誤解されないよう解除手順をその場に出す
    bar = bar
      .. (' · filter=%s%s'):format(opts.filter, #files == 0 and ' (空入力で解除)' or '')
  end
  if opts.hidden_outdated ~= nil and opts.hidden_outdated > 0 then
    bar = bar .. (' · ⚠%d'):format(opts.hidden_outdated)
  end
  return bar
end

-- ============================================================================
-- spec 観察用アクセサ (実装の裏口ではなく「バッファ側の真実」の検査面)
-- ============================================================================

--- 張られた span extmark を { row(0-based), from, to, group } の一覧で返す。
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

--- 選択行 hl extmark = { row(0-based), group } (未設定なら nil)。
function M.selection_mark(bufnr)
  local id = sel_mark[bufnr]
  if id == nil then
    return nil
  end
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, sel_ns, id, { details = true })
  if m == nil or #m == 0 then
    return nil
  end
  return { row = m[1], group = (m[3] or {}).line_hl_group }
end

return M
