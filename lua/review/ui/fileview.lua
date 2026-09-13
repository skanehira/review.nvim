-- ui/fileview: `o` = そのファイルの実ファイルを**レビュー tab の外に出して前行儀 tab**
-- で開く経路 (docs/design/features/diff-review.md「操作」o 行)。diff ペアを壊さず
-- 通常編集文脈へ出るための入口なので、レビュー窓 (vsplit) ではなく新規 tabpage を
-- 前行儀 (`tabnew` + `tabmove -1`) に作る。
--   * 通常 / 縮退を問わず <review_dir>/<path> がディスクに実在すれば :edit と同じ
--     編集可バッファで開く (LSP 付随・filetype detect は vim 標準)。既にユーザーが
--     開いていれば同一バッファを vim が再利用する (tabname 一致)。
--   * 実在しない場合のみ `git show <head>:<path>` read-only scratch に倒す
--     (縮退 o の INFO 表示は handlers/session、削除ファイルの WARN も same)。
-- b:/w: chrome は fallback read-only 窓のみ (実ファイル窓はユーザー文脈なので触らない)。
local chrome = require 'review.ui.chrome'
local cli = require 'review.git.cli'
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

--- 現 tab の直左 (前行儀) に新 tab を作って fn を走らせる。
local function in_prev_tab(fn)
  vim.cmd 'tabnew'
  vim.cmd 'tabmove -1'
  fn()
end

-- 同名レビュー scratch バッファを再利用する (o 連打で窓を増やさない)。
local function scratch_buffer(opts)
  local name = ('review://file/%s/%s'):format(opts.id, opts.path)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    return existing, true
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = true
  vim.api.nvim_buf_set_name(buf, name)
  return buf, false
end

--- opts = { repo, head, id, path, worktree?, winbar? }
--- 成否は cb(err, bufnr):
---   * disk 実在経路 (同期): err=nil、bufnr=開いた実ファイルバッファ
---   * fallback (git 完了後): err=nil、bufnr=review://file scratch
---   * fallback の git 失敗: 結果型 err (buf は開かない)。
function M.open(opts, cb)
  local dir = opts.worktree
  if dir == nil or dir == vim.NIL then
    dir = opts.repo
  end
  local full = vim.fs.joinpath(dir, opts.path)
  if vim.uv.fs_stat(full) ~= nil then
    in_prev_tab(function()
      vim.cmd(('edit %s'):format(vim.fn.fnameescape(full)))
    end)
    local buf = vim.api.nvim_get_current_buf()
    if cb ~= nil then
      cb(nil, buf)
    end
    return
  end
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
    local buf, reused = scratch_buffer(opts)
    local lines = vim.split(res.data.stdout, '\n', { plain = true })
    -- 末尾改行の都合で空の最終行が来るので落とす (git show は \n 終端)。
    if #lines > 1 and lines[#lines] == '' then
      table.remove(lines)
    end
    vim.bo[buf].readonly = false
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
    if reused and vim.fn.win_findbuf(buf)[1] ~= nil then
      -- 同名窓が既にあればそこへ載せ替える (tab を増やさない)
      vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    else
      in_prev_tab(function()
        vim.cmd(('buffer %d'):format(buf))
      end)
    end
    local fwin = vim.api.nvim_get_current_win()
    if opts.winbar ~= nil then
      chrome.winbar(fwin, opts.winbar)
    else
      chrome.winbar(fwin, ('%s · read-only (git show)'):format(opts.path))
    end
    if cb ~= nil then
      cb(nil, buf)
    end
  end)
end

return M
