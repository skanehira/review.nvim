-- spec 共有: データ fixture (セッション / コメント / one..six 差分)。
local M = {}

local function with_overrides(base, overrides)
  for k, v in pairs(overrides or {}) do
    base[k] = v
  end
  return base
end

--- DESIGN.md「データスキーマ」の全フィールドを持つセッション (branch / open / 空)。
function M.session_stub(overrides)
  return with_overrides({
    version = 1,
    id = 'main--feature',
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
  }, overrides)
end

--- a.lua 1 行目の active コメント (anchor なし)。
function M.comment(overrides)
  return with_overrides({
    id = 'c1',
    file = 'a.lua',
    line = 1,
    end_line = 1,
    body = 'body',
    anchor = vim.NIL,
    state = 'active',
    created_at = 1,
  }, overrides)
end

-- head (作業ツリー) の a.lua = new 側 5 行 (one / two / three / four / six)。
M.HEAD_TEXT_ONE_SIX = table.concat({ 'one', 'two', 'three', 'four', 'six' }, '\n') .. '\n'

-- base の a.lua (one / four / five / six) から HEAD_TEXT_ONE_SIX への 1 hunk 差分。
M.RAW_DIFF_ONE_SIX = table.concat({
  'diff --git a/a.lua b/a.lua',
  'index 1111111..2222222 100644',
  '--- a/a.lua',
  '+++ b/a.lua',
  '@@ -1,3 +1,5 @@',
  ' one',
  '+two',
  '+three',
  ' four',
  '-five',
  ' six',
  '',
}, '\n')

return M
