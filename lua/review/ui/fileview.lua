-- ui/fileview: `o` の実ファイル参照 (diff-review / pr-worktree「実ファイル参照」)。
-- worktree あり = `<worktree>/<path>` の実ファイルを :e のように開く (編集可。
-- 編集内容はレビューの diff には反映されない — pr-worktree.md)。
-- worktree なし = `git show <head>:<path>` の read-only scratch。
local cli = require 'review.git.cli'
local config = require 'review.config'
local result = require 'review.core.result'

local M = {}

-- worktree 実ファイル経路: git を呼ばず <worktree>/<path> を開く (pr-worktree.md)。
-- 存在しないパス (head に無いファイル) は倒し込みせず err で返す (WARN はcaller)。
local function open_worktree(opts, cb)
  local full = vim.fs.joinpath(opts.worktree, opts.path)
  if vim.uv.fs_stat(full) == nil then
    if cb ~= nil then
      cb(
        result.err(
          ('review.nvim: worktree 内のファイルが見つかりません: %s'):format(full),
          result.codes.E_WORKTREE
        )
      )
    end
    return
  end
  -- :e と同じ挙動 (既存バッファがあれば vim 側で再利用) を新規 split に載せる。
  vim.cmd(('vsplit | edit %s'):format(vim.fn.fnameescape(full)))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].review_meta = {
    kind = 'fileview',
    session_id = opts.id,
    path = opts.path,
    head = opts.head,
    worktree = opts.worktree,
  }
  if cb ~= nil then
    cb(nil, buf)
  end
end

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

--- opts = { repo, head, id, path, worktree? }。worktree 指定ならその実ファイルを
--- 編集可で、無ければ git show <head>:<path> を read-only scratch で開く。
--- 失敗は cb(err)->false 相当で WARN を返し、cb(nil, ok) は開いた bufnr を返す。
function M.open(opts, cb)
  if opts.worktree ~= nil and opts.worktree ~= vim.NIL then
    open_worktree(opts, cb)
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
