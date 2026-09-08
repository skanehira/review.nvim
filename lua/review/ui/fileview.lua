-- ui/fileview: `o` の実ファイル参照 (diff-review / pr-worktree「実ファイル参照」)。
-- 本 issue の分岐は worktree なし = `git show <head>:<path>` の read-only scratch のみ。
-- worktree ありの編集可バッファ分岐は #6 の拡張。
local cli = require 'review.git.cli'
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

-- 同名バッファを再利用する (head 差分の再取得時に window を増やさない)。
local function buffer_for(opts)
  local name = ('review://file/%s/%s'):format(opts.id, opts.path)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing, true
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, name)
  return buf, false
end

--- opts = { repo, head, id, path }。git show <head>:<path> を read-only な
--- scratch バッファに右 split で開く。失敗は cb(err)->false 相当で WARN を返し、
--- cb(nil, ok) は開いた bufnr を返す。
function M.open(opts, cb)
  local cfg = config.get()
  cli.run(cfg.git_bin, { 'show', opts.head .. ':' .. opts.path }, {
    cwd = opts.repo,
    err_code = result.codes.E_GIT,
  }, function(res)
    if not res.ok then
      if cb ~= nil then
        cb(res)
      end
      return
    end
    local buf, reused = buffer_for(opts)
    local lines = vim.split(res.data.stdout, '\n', { plain = true })
    -- 末尾改行の都合で空の最終行が来るので落とす (git show は \n 終端)。
    if #lines > 1 and lines[#lines] == '' then
      table.remove(lines)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    local detected = vim.filetype.match { filename = opts.path }
    if detected ~= nil then
      vim.bo[buf].filetype = detected
    end
    vim.b[buf].review_meta = {
      kind = 'fileview',
      session_id = opts.id,
      path = opts.path,
      head = opts.head,
    }
    if not reused then
      vim.cmd 'vsplit'
      vim.api.nvim_win_set_buf(0, buf)
    end
    if cb ~= nil then
      cb(nil, buf)
    end
  end)
end

return M
