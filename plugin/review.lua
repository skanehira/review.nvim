-- plugin/review.lua — :Review コマンド登録のみを行う薄い entry layer
-- (docs/design/features/foundation.md「実装の配置」)。本体は require("review") に委譲する。
if vim.g.loaded_review_nvim then
  return
end
vim.g.loaded_review_nvim = true

local function run(opts)
  require('review').command(opts.fargs)
end

local function completion(arglead, cmdline, cursorpos)
  return require('review').complete(arglead, cmdline, cursorpos)
end

local desc = 'GitHub Files changed 風のブランチ / PR 差分レビュー'

-- customlist 補完の API が Neovim の間で異なる:
--   0.10 系: complete = "customlist" + completion = fn
--   0.13 系: complete = fn (completion key は invalid key)
-- 宣言的な版本分岐より実呼び出しの試行で両立させる (既知の制約に記録)。
local ok = pcall(vim.api.nvim_create_user_command, 'Review', run, {
  nargs = '*',
  complete = 'customlist',
  completion = completion,
  desc = desc,
})
if not ok then
  vim.api.nvim_create_user_command('Review', run, {
    nargs = '*',
    complete = completion,
    desc = desc,
  })
end
