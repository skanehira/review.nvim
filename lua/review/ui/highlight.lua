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
  -- 全文閲覧 float (`i`) の本文背景 = 透過 (bg NONE。コメントスレッドの行下表示と
  -- 同じく背景を塗らない。colorscheme が定義していればそちらが勝つ)。
  ReviewCommentView = { bg = 'NONE' },
  -- 行下スレッドの罫線の箱 (┌─┐ │ └─┘)。既存 float の border="rounded" と揃える。
  -- 本文行の右寄せ pad は Border 色にしない (背景色の付く FloatBorder で pad 部分
  -- が塗られないため — pad は ReviewCommentBody のまま)。
  ReviewCommentBorder = { link = 'FloatBorder' },
  ReviewDiffAdd = { link = 'DiffAdd' },
  ReviewDiffDelete = { link = 'DiffDelete' },
  -- GitHub 風配色 (diffview.nvim enhanced_diff_hl と同方式)。base 窓の「この側に
  -- しか無い行 = 削除」は削除色で、filler 行は両窓で dim。link なので colorscheme
  -- の DiffDelete / Comment 定義に動的に追従する。
  ReviewDiffAddAsDelete = { link = 'DiffDelete' },
  ReviewDiffDeleteDim = { link = 'Comment' },
  ReviewDiffChange = { link = 'DiffChange' },
  ReviewDiffHunk = { link = 'diffLine' },
  -- file panel (DESIGN「命名」basename / dir 行 / git status 記号 / コメント有無 /
  -- 増減数)。basename は既定無着色 = Normal link。±は + 緑 / - 赤、コメントアイコンは
  -- Comment grey。選択行 hl は専用 group (CursorLine link) — 背景を持つ group を
  -- line_hl_group に張ると cursorline 背景が打ち消されるため分離 (issue #35)。
  ReviewPanelFile = { link = 'Normal' },
  ReviewPanelDir = { link = 'Directory' },
  ReviewPanelStatus = { link = 'Comment' },
  ReviewPanelComment = { link = 'Comment' },
  ReviewPanelAdd = { link = 'Added' },
  ReviewPanelRemove = { link = 'Removed' },
  ReviewPanelSelection = { link = 'CursorLine' },
  -- 現在 diff 窓に開いているファイルの basename (diffview FilePanelSelected = Type
  -- link と同系。行全体の選択行背景は ReviewPanelSelection が担うため別 group)。
  ReviewPanelActive = { link = 'Type' },
  -- session 一覧 (:Review list) の grey 行 (repo path 消失で <Enter> 不可)。
  -- file panel 側では未使用 (2026-09 改訂で親パスサフィックスを撤去)。
  ReviewPanelMeta = { link = 'Comment' },
}

-- 行内 span (ユーザーの diffopt inline: 設定で付く DiffText / DiffTextAdd) の
-- 既定色。GitHub の word-diff 由来の帯で「行内のどこが変わったか」を見せる。
-- background で出し分ける。default=true なのでユーザーの明示定義 / config.highlight
-- が勝つ。colorscheme が後から background を変えた場合は再 setup か
-- config.highlight での定義に委ねる (setup 時点の background で固定)。
local function word_hl_defaults()
  if vim.o.background == 'light' then
    return {
      ReviewDiffTextAdd = { bg = '#acf2bd' },
      ReviewDiffTextDelete = { bg = '#fdb8c0' },
    }
  end
  return {
    ReviewDiffTextAdd = { bg = '#266d32' },
    ReviewDiffTextDelete = { bg = '#6e2b31' },
  }
end

function M.setup()
  for group, attrs in pairs(DEFAULTS) do
    vim.api.nvim_set_hl(0, group, vim.tbl_extend('keep', attrs, { default = true }))
  end
  for group, attrs in pairs(word_hl_defaults()) do
    vim.api.nvim_set_hl(0, group, vim.tbl_extend('keep', attrs, { default = true }))
  end
  for group, attrs in pairs(config.get().highlight or {}) do
    if DEFAULTS[group] ~= nil or group:match '^ReviewDiffText' then
      vim.api.nvim_set_hl(0, group, vim.deepcopy(attrs))
    end
  end
end

return M
