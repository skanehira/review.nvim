-- 行コメント一覧の read-only float (diff `i` / diff-review.md「操作」)。
-- 編集用 float (ui/input) は入力を伴うため閲覧に使いにくい (本文は 40 字で
-- 切り詰められ、編集中に誤って確定/破棄の操作経路に入ってしまう)。ここでは
-- 全文・状態・位置をそのまま見せるだけを見せる (編集は `e`)。
local M = {}

--- lines = 整形済み表示行 (呼び出し側 = handlers/comments)。opts = { title? }。
--- 窓は `q` / `<Esc>` / `<CR>` 等の単打で閉じる (modifiable=false、操作は閉じるのみ)。
function M.open(lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  -- 先に内容を入れる (modifiable を切った後だと set_lines が error)。
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.max(30, math.min(72, vim.o.columns - 4))
  local height = math.max(3, math.min(16, #lines + 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    border = 'rounded',
    title = (opts.title or ' Comments') .. '  q 閉じる ',
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  -- 閉じる操作のみ受け付ける (x/d など diff 側の意味を持つキーは閉じ方も含め
  -- どこにも効かせない = 誤操作の入口を作らない)
  for _, key in ipairs { 'q', '<Esc>', '<CR>' } do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, silent = true })
  end
end

return M
