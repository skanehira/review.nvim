-- マルチラインコメント入力 float (diff-review.md「操作」c / e、
-- 「float 編集中に <Esc> 以外で窓を閉じる離脱はキャンセル扱い」)。
-- 世界との契約: on_confirm(body) は確定操作でのみ呼ばれる。取り消し・空 body・
-- <Esc> 以外の離脱では一切呼ばれない。
local M = {}

--- opts = { value?, on_confirm(body) }。<C-y> 確定 / <Esc> キャンセル。
--- 空 body (空白のみ) の確定はキャンセル扱い (決定: 空コメントを作らない)。
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false

  local lines = opts.value ~= nil and vim.split(opts.value, '\n', { plain = true }) or {}
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = math.max(20, math.min(70, vim.o.columns - 4))
  local height = math.max(4, math.min(12, #lines + 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    border = 'rounded',
  })

  -- 解決済みフラグ。窓クローズ経路 (<Esc> / :q 等) と二重発火しないための境界。
  local settled = false

  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  local function confirm()
    if settled then
      return
    end
    local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if body:match '^%s*$' then
      settled = true
      close_window()
      return -- 空 body はキャンセル (on_confirm を呼ばない)
    end
    settled = true
    close_window()
    if opts.on_confirm ~= nil then
      opts.on_confirm(body)
    end
  end

  vim.keymap.set({ 'i', 'n' }, '<C-y>', confirm, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set(
    { 'i', 'n' },
    '<Esc>',
    close_window,
    { buffer = buf, nowait = true, silent = true }
  )

  -- <Esc> 以外の離脱 (:q 等) をキャンセルとして扱う確定経路。窓が閉じても
  -- settled であれば (<Esc> 押下済み・確定済み) 何も起きない。
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      settled = true
    end,
  })

  vim.cmd 'startinsert'
end

return M
