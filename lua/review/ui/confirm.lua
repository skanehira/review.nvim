-- ui/confirm: [y/N] の単キー確認 float (diff-review.md「操作」/ DESIGN.md「UI」)。
-- vim.ui.input は Enter 必須のため «y だけ押して次のコマンドを打つ» と cmdline の
-- 入力欄に後続キーが混入し、y が残る (UX review F15)。float は cmdline を使わず
-- y / n / Esc の 1 キーで確定して閉じる = 残留しない。
local M = {}

-- 幅で折り返した行 (float は wrap するが、高さ計算と見た目の安定のため事前折返し)
local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text, '\n', { plain = true })) do
    local line = ''
    for _, word in ipairs(vim.split(para, '%s+', { trimempty = true })) do
      local candidate = line == '' and word or (line .. ' ' .. word)
      if vim.fn.strdisplaywidth(candidate) > width and line ~= '' then
        out[#out + 1] = line
        line = word
      else
        line = candidate
      end
    end
    out[#out + 1] = line
  end
  return out
end

--- 1 キー確認を出す。cb(true) = y / cb(false) = n・Esc・<CR> (既定 N)。
--- prompt 末尾の «[y/N]: » は float では冗長なので落とす (文言の正本は呼び出し側)。
function M.open(prompt, cb)
  local text = (prompt:gsub('%[y/N%]:%s*$', ''):gsub('%s+$', ''))
  local lines = wrap(text, 72)
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'y = はい / n・Esc = いいえ'

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = 4
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(24, math.min(76, width + 2))
  local height = math.min(vim.o.lines - 2, #lines + 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = 'rounded',
  })

  local done = false
  local function answer(yes)
    if done then
      return
    end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    cb(yes)
  end
  for _, key in ipairs { 'y', 'Y' } do
    vim.keymap.set('n', key, function()
      answer(true)
    end, { buffer = buf, nowait = true })
  end
  for _, key in ipairs { 'n', 'N', 'q', '<Esc>', '<CR>' } do
    vim.keymap.set('n', key, function()
      answer(false)
    end, { buffer = buf, nowait = true })
  end
end

return M
