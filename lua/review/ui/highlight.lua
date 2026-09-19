-- highlight グループ定義 (DESIGN.md「命名」)。default=true で定義するので
-- colorscheme の再適用で上書きされうる (既定の提供であって強制ではない)。
-- config.highlight のグループ別 override は既定の後に再定義して勝たせる。
local config = require 'review.config'

local M = {}

-- グループ -> 既定定義。ReviewCommentLine は diff の syntax より前面に出るため
-- 独立グループで下線を持つ (DESIGN.md「既知の制約」extmark と syntax の競合)。
local DEFAULTS = {
  ReviewCommentLine = { underline = true },
  -- eol の件数表示の下に出すスレッド本文行 (行下 virt_lines)。colorscheme 追従。
  ReviewCommentBody = { link = 'Normal' },
  ReviewCommentOutdated = { link = 'DiagnosticWarn' },
  ReviewDiffAdd = { link = 'DiffAdd' },
  ReviewDiffDelete = { link = 'DiffDelete' },
  ReviewDiffHunk = { link = 'diffLine' },
  -- file panel (DESIGN「命名」basename / dir 行 / git status 記号 / コメント有無 /
  -- 増減数)。basename は既定無着色 = Normal link。選択行 hl も ReviewPanelFile
  -- (diff-review「file panel」相互ハイライト)。±は + 緑 / - 赤、コメントアイコンは Comment grey。
  ReviewPanelFile = { link = 'Normal' },
  ReviewPanelDir = { link = 'Directory' },
  ReviewPanelStatus = { link = 'Comment' },
  ReviewPanelComment = { link = 'Comment' },
  ReviewPanelAdd = { link = 'Added' },
  ReviewPanelRemove = { link = 'Removed' },
  -- session 一覧 (:Review list) の grey 行 (repo path 消失で <Enter> 不可)。
  -- file panel 側では未使用 (2026-09 改訂で親パスサフィックスを撤去)。
  ReviewPanelMeta = { link = 'Comment' },
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
