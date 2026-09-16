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
  -- file panel (左窓) の幅 (DESIGN.md「API 一覧」config / diff-review「レイアウト」)
  panel_width = 35,
  keymaps = {
    -- 既定値の正本は docs/design/DESIGN.md「デフォルトキーマップ」表。
    -- 移動系は diffview 風の <Tab>/<S-Tab>/[F/]F。S / ]d / [d は廃止済みで
    -- 復活させない (issue #18)。
    diff = {
      add_comment = 'c',
      edit_comment = 'e',
      delete_comment = 'd',
      yank_prompt = 'y',
      close = 'q',
      help = '<F1>',
      next_file = '<Tab>',
      prev_file = '<S-Tab>',
      first_file = '[F',
      last_file = ']F',
      refresh = 'R',
      -- file panel へ focus (閉じていれば再建) と panel 表示トグル
      -- (閉じても tab とレビュー窓は残る)
      focus_panel = '<leader>e',
      toggle_panel = '<leader>b',
      view_comments = 'i',
    },
    sidebar = {
      open_diff = '<CR>',
      -- panel の o / l は <CR> と同じ «entry を開く» (diff 窓の o とは意味が
      -- 違う — DESIGN キー表)
      open_file = 'o',
      open_entry = 'l',
      next_file = '<Tab>',
      prev_file = '<S-Tab>',
      first_file = '[F',
      last_file = ']F',
      toggle_viewed = 'x',
      close = 'q',
      filter = '/',
      -- list 表示 (フルパス 1 行) と tree 表示の切替 (view state。DESIGN キー表)
      toggle_style = 'i',
      refresh = 'R',
      -- help float は <F1> (config) に加え固定の別名 g? でも開く (keygate/
      -- filepanel の張込側。DESIGN キー表「g? は <F1> と同じ機能呼び出し」)。
      help = '<F1>',
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
