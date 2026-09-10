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

-- 起動時の worktree scan + 継続通知を **plugin 側**で登録する (rtp source 時点で
-- setup 呼び出しの有無に依らず走る — README「setup() は省略可能」の実体。
-- UX review F3 で setup なり install の既定が音もなく黙っていた)。
-- 通知可否 (auto_notify_resume) は startup_scan が実行時に config を読むため、
-- setup が後から走っても設定が効く。group 名前と clear でハンドル重複を防ぐ。
local group = vim.api.nvim_create_augroup('review_nvim', { clear = true })
vim.api.nvim_create_autocmd('VimEnter', {
  group = group,
  desc = 'review.nvim: worktree 残骸 scan + open セッションの継続通知 (窓は開かない)',
  callback = function()
    require('review.handlers.restore').startup_scan()
  end,
})

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
