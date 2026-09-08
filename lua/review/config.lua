-- setup で受け取った opts を DESIGN.md「API 一覧」の既定値と合成し、
-- 内部 config として保持する。shallow+deep 合成:
-- スカラーは opts の値がそのまま勝ち、テーブルは再帰合成して
-- 同一階層の既定キーを保持する。
local M = {}

M.defaults = {
  git_bin = 'git',
  gh_bin = 'gh',
  -- diff_context 未指定 (nil) は git 既定 (3) に従う。既定テーブルには置かない。
  auto_notify_resume = true,
  keymaps = {
    diff = {
      add_comment = 'c',
      edit_comment = 'e',
      delete_comment = 'd',
      yank_prompt = 'y',
      open_file = 'o',
      close = 'q',
      help = '<F1>',
    },
    sidebar = {
      open_diff = '<CR>',
      open_file = 'o',
      toggle_viewed = 'x',
      close = 'q',
    },
    sessionlist = {
      open = '<CR>',
      close = 'q',
    },
  },
  highlight = {},
}

local current = vim.deepcopy(M.defaults)

local function deep_merge(base, override)
  local out = vim.deepcopy(base)
  for key, value in pairs(override) do
    if type(value) == 'table' and type(out[key]) == 'table' then
      out[key] = deep_merge(out[key], value)
    else
      out[key] = vim.deepcopy(value)
    end
  end
  return out
end

-- opts を既定値と合成して保持する。毎回 defaults から再合成するので冪等
-- (同じ opts での再呼び出しは前回結果と一致し、前回 opts は引き継がれない)。
function M.setup(opts)
  current = deep_merge(M.defaults, opts or {})
end

function M.get()
  return current
end

-- テストの独立性用。既定値へ戻す。
function M.reset()
  current = vim.deepcopy(M.defaults)
end

return M
