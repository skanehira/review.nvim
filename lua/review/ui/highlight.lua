-- highlight グループ定義 (DESIGN.md「命名」)。default=true で定義するので
-- colorscheme の再適用で上書きされうる (既定の提供であって強制ではない)。
-- config.highlight のグループ別 override は既定の後に再定義して勝たせる。
local config = require 'review.config'

local M = {}

-- グループ -> 既定定義。ReviewCommentLine は diff の syntax より前面に出るため
-- 独立グループで下線を持つ (DESIGN.md「既知の制約」extmark と syntax の競合)。
local DEFAULTS = {
  ReviewCommentLine = { underline = true },
  ReviewDiffAdd = { link = 'DiffAdd' },
  ReviewDiffDelete = { link = 'DiffDelete' },
  ReviewDiffHunk = { link = 'diffLine' },
  ReviewSidebarFile = { link = 'Directory' },
  ReviewSidebarStatus = { link = 'Comment' },
}

function M.setup()
  for group, attrs in pairs(DEFAULTS) do
    vim.api.nvim_set_hl(0, group, vim.tbl_extend('keep', attrs, { default = true }))
  end
  for group, attrs in pairs(config.get().highlight or {}) do
    if DEFAULTS[group] ~= nil then
      vim.api.nvim_set_hl(0, group, vim.deepcopy(attrs))
    end
  end
end

return M
