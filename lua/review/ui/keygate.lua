-- ui/keygate: review キーの buffer-local 張込 + 押下時点 window role gate
-- (docs/design/DESIGN.md 決定表「review キーの実装」/ docs/design/features/
-- diff-review.md「操作」「head / base 窓の中身」)。
-- 実ファイルバッファはユーザー窓でも開かれるため window-local keymap の代替として
-- buffer-local + expr rhs gate を使う (Neovim に window-local keymap API は無い —
-- DESIGN「既知の制約」キー)。押下時点の窓 role (ui/windows の内容+窓変数導出) が
-- 不成立の窓では元キーを built-in として返す。help に明記済みの副作用。
-- 張込前に nvim_buf_get_keymap でユーザー既存の buffer-local マップを検出し、
-- 衝突キーはスキップする (失効させない)。uninstall で自前マップ残骸 0。
-- dispatch 先の handlers は発火時 require (ui → handlers の load 循環回避)。
local config = require 'review.config'
local windows = require 'review.ui.windows'

local M = {}

-- コメント作成系キー (head 窓のみ発火。base/告知窓は WARN)。視覚選択の c も同じ。
-- 確定文言の正本は DESIGN.md「デフォルトキーマップ」表 «この窓にはコメントを
-- 付けられません»。
local COMMENT_OPS = {
  add_comment = { mode = 'n', fn = 'add_normal' },
  add_comment_visual = { mode = 'v', fn = 'add_visual_marks' },
  edit_comment = { mode = 'n', fn = 'edit_current' },
  delete_comment = { mode = 'n', fn = 'delete_current' },
  yank_prompt = { mode = 'n', fn = 'yank_current' },
  view_comments = { mode = 'n', fn = 'view_current' },
}

-- op -> (handler module, 関数名)。focus_panel (<leader>e) は panel への focus
-- (閉じていれば再建)。旧 S / ]d / [d は issue #18 で廃止 (DESIGN キー表)。
local DISPATCH = {
  close = { 'review.handlers.session', 'close_by_key' },
  help = { 'review.ui.help', 'open' },
  next_file = { 'review.handlers.session', 'next_file' },
  prev_file = { 'review.handlers.session', 'prev_file' },
  first_file = { 'review.handlers.session', 'first_file' },
  last_file = { 'review.handlers.session', 'last_file' },
  refresh = { 'review.handlers.session', 'refresh' },
  focus_panel = { 'review.handlers.session', 'focus_sidebar' },
  toggle_panel = { 'review.handlers.session', 'toggle_panel' },
  -- comment ops は handlers.comments へ comment_dispatch で寄る
}

local function comment_dispatch(op)
  local target = COMMENT_OPS[op]
  require('review.handlers.comments')[target.fn]()
end

--- 押下時点 gate。返り値:
---   true  ... 発火可
---   false ... gate 不成立 = built-in へ返す
---   'warn-comment' ... レビュー窓だがコメント系キーは WARN で消費
--- 役割は ui.windows の内容+窓変数導出に一本化し、ここでは再発明しない。
--- 告知 scratch (deleted/binary) は窓枠が head でもコメント不可 (diff-review の
--- 「head / base 窓の中身」表と操作表 «削除告知・binary 注釈…では WARN»)。
local function notify_buf(win)
  local meta = vim.b[vim.api.nvim_win_get_buf(win)].review_meta or {}
  return meta.kind == 'scratch' and (meta.scratch == 'deleted' or meta.scratch == 'binary')
end

local function gate_state(op)
  local win = vim.api.nvim_get_current_win()
  local role = windows.role_of(win)
  if role == nil or role == 'panel' then
    return false
  end
  if COMMENT_OPS[op] ~= nil then
    if role ~= 'head' or notify_buf(win) then
      return 'warn-comment'
    end
    return true
  end
  return true
end

--- expr keymap の rhs から呼ばれる本体。fallback は張込時(lhs 文字列)を渡す。
--- gate 不成立時は nvim_replace_termcodes 済みの元キー列を返し、その窓では
--- built-in 動作になる (map expr の返り値は再マップされない)。
function M.fire(op, fallback)
  local gate = gate_state(op)
  if gate == false then
    return vim.api.nvim_replace_termcodes(fallback or '', true, false, true)
  end
  if gate == 'warn-comment' then
    vim.notify(
      'review.nvim: この窓にはコメントを付けられません',
      vim.log.levels.WARN
    )
    return '' -- キーストロークを消費 (built-in 化すると誤発火する)
  end
  -- NOTE (e2e 実測): expr キーマップの rhs は textlock 下で評価されるため、その場
  -- での窓作成 / バッファ変更が E565 になる (0.10 / 0.13Nightly 実測。textlock を
  -- 問う API は無い)。UI 副作用を持つ dispatch は vim.schedule でロック解除直後の
  -- イベントループへ回す (体感は同一打鍵。expr 返り値でキーストロークは確定消費 =
  -- built-in 化しない)。
  vim.schedule(function()
    if COMMENT_OPS[op] ~= nil then
      comment_dispatch(op)
      return
    end
    local target = DISPATCH[op]
    if target ~= nil then
      require(target[1])[target[2]]()
    end
  end)
  return ''
end

-- bufnr -> { [mode] = { lhs, ... } } 自前マップ台帳 (uninstall と残骸検証の源)。
local installed = {}

vim.api.nvim_create_autocmd('BufUnload', {
  callback = function(ev)
    installed[ev.buf] = nil
  end,
})

local function user_keytaken(buf, mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if m.lhs == lhs then
      -- vim.keymap.set の関数形は get_keymap で rhs フィールドが無く callback に
      -- 関数が載る (rhs を無検証に index するとクラッシュ = 衝突検出が例外で
      -- 壊れる)。自前マップは nvim_buf_set_keymap の文字列 rhs のみなので、
      -- 非文字列 rhs はユーザー既存とみなし衝突スキップ (黙って消さない)。
      if type(m.rhs) ~= 'string' then
        return true
      end
      -- 自前マップ (再 install) は衝突じゃない
      if m.rhs:find('review.ui.keygate', 1, true) == nil then
        return true
      end
      return false
    end
  end
  return false
end

local function install_one(buf, mode, lhs, op)
  if user_keytaken(buf, mode, lhs) then
    return false
  end
  local rhs = ('v:lua.require("review.ui.keygate").fire("%s", "%s")'):format(
    op,
    (lhs:gsub('"', '\\"'))
  )
  vim.api.nvim_buf_set_keymap(buf, mode, lhs, rhs, {
    noremap = true,
    silent = true,
    nowait = true,
    expr = true,
  })
  local t = installed[buf] or {}
  installed[buf] = t
  local by_mode = t[mode] or {}
  t[mode] = by_mode
  by_mode[#by_mode + 1] = lhs
  return true
end

--- head/base どちらの窓にも張れるよう、config.keymaps.diff の全キーを張る。
--- 役割 gate は発火時点 (上の fire) で判定するため、この張込阶段では窓を必要と
--- しない。session_id は将来の拡張 (複数セッション共存時の衝突検出) 用に残す。
function M.install(buf, session_id)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local k = config.get().keymaps.diff
  install_one(buf, 'n', k.add_comment, 'add_comment')
  install_one(buf, 'v', k.add_comment, 'add_comment_visual')
  install_one(buf, 'n', k.edit_comment, 'edit_comment')
  install_one(buf, 'n', k.delete_comment, 'delete_comment')
  install_one(buf, 'n', k.yank_prompt, 'yank_prompt')
  install_one(buf, 'n', k.view_comments, 'view_comments')
  install_one(buf, 'n', k.close, 'close')
  install_one(buf, 'n', k.help, 'help')
  -- g? は config を持たない固定の別名 (<F1> が terminal に奪われる環境向け。
  -- DESIGN キー表。衝突時は install_one がスキップする)。
  install_one(buf, 'n', 'g?', 'help')
  install_one(buf, 'n', k.next_file, 'next_file')
  install_one(buf, 'n', k.prev_file, 'prev_file')
  install_one(buf, 'n', k.first_file, 'first_file')
  install_one(buf, 'n', k.last_file, 'last_file')
  install_one(buf, 'n', k.refresh, 'refresh')
  if k.focus_panel ~= nil then
    install_one(buf, 'n', k.focus_panel, 'focus_panel')
  end
  if k.toggle_panel ~= nil then
    install_one(buf, 'n', k.toggle_panel, 'toggle_panel')
  end
  return session_id
end

--- 張ったキーだけを削除 (ユーザー既存マップは元から張っていないので残る)。
function M.uninstall(buf)
  local t = installed[buf]
  if t == nil then
    return
  end
  for mode, lhs_list in pairs(t) do
    for _, lhs in ipairs(lhs_list) do
      pcall(vim.api.nvim_buf_del_keymap, buf, mode, lhs)
    end
  end
  installed[buf] = nil
end

return M
