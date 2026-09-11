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
      next_file = ']d',
      prev_file = '[d',
      focus_sidebar = 'S',
      view_comments = 'i',
    },
    sidebar = {
      open_diff = '<CR>',
      open_file = 'o',
      toggle_viewed = 'x',
      close = 'q',
      filter = '/',
    },
    sessionlist = {
      open = '<CR>',
      close = 'q',
      delete = 'd',
    },
  },
  highlight = {},
  -- GitHub Files changed 風の窓装飾 (既定): winbar = review 窓に path/session 情報、
  -- number = diff/sidebar/list 窓の行番号 off (GitHub 同様に diff 行へ集中するため)。
  -- どちらも設定で戻せる (winbar はユーザーが既存設定を有する場合上書きしない)。
  winbar = true,
  number = false,
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
